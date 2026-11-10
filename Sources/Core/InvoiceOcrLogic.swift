import Foundation

// ============================================================================
//  Чистая логика новых разделов продавца (приход по фото накладной, план
//  закупок): разбор кода отказа, «прятать ли раздел», статусы, подсказки.
//  Без UI и сети — чтобы правила были в одном месте и читались отдельно.
// ============================================================================

/// Отказы сервера новых ручек: код может лежать в code верхнего уровня
/// (idempotency_*, no_route) или в errors.code (daily_limit, busy, heic…).
enum SellerNewErrors {
    /// Машинный код отказа. nil — кода нет (или это не отказ сервера).
    static func code(_ error: Error) -> String? {
        if let e = error as? APIDetailedError {
            if let c = e.code, !c.isEmpty { return c }
            if let c = e.extras["code"], !c.isEmpty { return c }
            return nil
        }
        if let e = error as? IdempotencyError { return e.code }
        return nil
    }

    static func status(_ error: Error) -> Int? {
        (error as? APIDetailedError)?.status
    }

    /// Раздела нет на сервере (404/405 — сайт ещё не залит), нет права или склада
    /// у формата магазина (403), таблицы не созданы (503): пункт не показываем.
    static func isHiddenStatus(_ status: Int) -> Bool {
        status == 403 || status == 404 || status == 405 || status == 503
    }

    static func isHidden(_ error: Error) -> Bool {
        if let s = status(error) { return isHiddenStatus(s) }
        return false
    }

    /// Текст для человека: сервер говорит сам (message), без своих выдумок.
    /// Исключение — 429 лимита частоты (без кода): сервер пишет общим текстом.
    static func text(_ error: Error) -> String {
        if let e = error as? APIDetailedError {
            if e.status == 429 && code(e) == nil { return "Слишком часто, попробуйте через минуту" }
            return e.message
        }
        return error.localizedDescription
    }
}

/// Результат «пробной» загрузки раздела: показывать или прятать.
enum FeatureProbe {
    case available
    case hidden
    /// Сеть мигнула — состояние не меняем, спросим в следующий раз.
    case unknown

    static func from(_ error: Error) -> FeatureProbe {
        if error is CancellationError { return .unknown }
        return SellerNewErrors.isHidden(error) ? .hidden : .unknown
    }
}

/// Есть ли на сервере «Приход по фото накладной» и включён ли он.
/// Класс без @MainActor (как RevalFeature): берётся через @ObservedObject … = .shared.
final class InvoiceOcrFeature: ObservableObject {
    static let shared = InvoiceOcrFeature()
    @Published private(set) var available = false
    @Published private(set) var state: OcrState?

    private var checkedShop: Int?
    private var checkedAt = Date.distantPast
    private var checkingShop: Int?

    private init() {}

    @MainActor
    func refresh(shopId: Int?) async {
        guard let sid = shopId, Session.shared.can("warehouse") else {
            // Нет магазина или права (в т.ч. вышли из аккаунта): забываем пробу и лимиты прежнего
            // пользователя — иначе пункт скрыт ещё 10 минут, а canPost остаётся от прошлого.
            available = false; state = nil; checkedShop = nil; checkedAt = Date.distantPast
            return
        }
        if checkedShop != sid { available = false; state = nil }
        if checkedShop == sid && Date().timeIntervalSince(checkedAt) < 600 { return }
        guard checkingShop != sid else { return }
        checkingShop = sid
        defer { if checkingShop == sid { checkingShop = nil } }
        do {
            let s = try await API.shared.ocrState()
            guard Session.shared.activeShopId == sid else { return }
            state = s
            // Выключено (нет ключа ИИ, отключено админом, лимит 0) — кнопку не показываем.
            available = s.enabled ?? false
            checkedShop = sid; checkedAt = Date()
        } catch {
            guard Session.shared.activeShopId == sid else { return }
            switch FeatureProbe.from(error) {
            case .hidden:
                available = false; state = nil; checkedShop = sid; checkedAt = Date()
            default:
                break
            }
        }
    }
}

enum OcrLogic {
    static let pollNanos: UInt64 = 2_500_000_000
    /// Через 10 минут опроса экран останавливается и подсказывает вернуться позже (как на Android).
    static let pollGiveUpSeconds: TimeInterval = 600
    static let slowText = "Распознавание идёт дольше обычного. Загляните в список «Распознанные накладные» позже."
    static let checkAgain = "Проверить ещё раз"

    /// Единицу можно подтвердить теми же kind / id / factor (PUT …/map): как Android Ocr.confirmBody —
    /// не при удалённом товаре и не при пустых kind / id.
    static func canConfirmUnit(_ m: OcrMap?) -> Bool {
        guard let m else { return false }
        if m.missing ?? false { return false }
        guard let id = m.itemId, id > 0 else { return false }
        return !(m.kind ?? "").isEmpty
    }

    static func isFinal(_ status: String?) -> Bool {
        let s = status ?? ""
        return s == "done" || s == "failed" || s == "cancelled"
    }

    static func statusTitle(_ job: OcrJob) -> String {
        switch job.status ?? "" {
        case "queued": return "В очереди"
        case "processing": return "Распознаётся"
        case "done": return "Готово"
        case "failed": return "Ошибка"
        case "cancelled": return "Отменено"
        default: return job.statusLabel ?? ""
        }
    }

    /// Строка требует внимания: не сопоставлена, единица не подтверждена, товар удалён
    /// или у сервера есть замечание. Пропущенные строки не считаем.
    static func needsCheck(_ line: OcrLine) -> Bool {
        if line.skipped ?? false { return false }
        guard let m = line.map else { return true }
        if m.check ?? false { return true }
        if m.missing ?? false { return true }
        return !line.flags.isEmpty
    }

    static func checkCount(_ lines: [OcrLine]) -> Int {
        lines.filter { needsCheck($0) }.count
    }

    /// «Нужно проверить: N» — по строкам; сервер считает to_check без несопоставленных,
    /// поэтому берём большее из двух (так же на Android).
    static func checkCount(_ doc: OcrDocument) -> Int {
        max(checkCount(doc.lines), doc.toCheck ?? 0)
    }

    /// Подсказка, что поправить, к отказу прихода (после текста сервера).
    static func receiptHint(code: String?) -> String? {
        switch code ?? "" {
        case "receipt_diff":
            return "Включите «Подтвердить разницу сумм» или поправьте коэффициент единиц."
        case "negative_lines":
            return "Поправьте числа в этих строках или отметьте их «Пропустить»."
        case "units_unconfirmed":
            return "Нажмите «Подтвердить единицу» у строк с пометкой «Проверьте единицу»."
        default:
            return nil
        }
    }

    /// Текст отказа прихода: сообщение сервера + подсказка.
    static func receiptErrorText(_ error: Error) -> String {
        let base = SellerNewErrors.text(error)
        if let hint = receiptHint(code: SellerNewErrors.code(error)) { return base + "\n" + hint }
        return base
    }

    /// Строки для «Положено в приход»: «Приход уже проведён» при already.
    static func receiptDoneText(_ ack: OcrReceiptAck) -> String {
        if ack.already ?? false {
            return (ack.posted ?? false) ? "Приход уже проведён" : "Приход уже создан и сохранён черновиком"
        }
        if ack.posted ?? false { return "Приход проведён" }
        return "Приход сохранён черновиком"
    }

    // ── Тексты, общие с Android (core/OcrLogic.kt) ──────────────────────────
    static let canCloseNote = "Можно закрыть экран: накладная будет в списке «Распознанные накладные»."
    static let sending = "Отправляем…"
    static let deleteTitle = "Удалить накладную?"
    static let deleteNote = "Накладная и её снимки будут удалены. Уже оформленный приход останется."
    static let deleteButton = "Удалить накладную"
    static let cancelTitle = "Отменить распознавание?"
    static let cancelNote = "Распознавание остановится. Накладная останется в списке со статусом «Отменено»."
    static let cancelRecognition = "Отменить распознавание"
    static let cancelYes = "Отменить"
    static let keep = "Не надо"
    static let noData = "Накладная распознана, но данных нет. Попробуйте распознать заново."
    static let refresh = "Обновить"
    static let automap = "Сопоставить сами"
    static let allChecked = "Все строки проверены"

    static func needCheckText(_ n: Int) -> String { "Нужно проверить: \(n)" }
    static func sendText(_ n: Int) -> String { "Распознать (\(n))" }
    static func pageTitle(_ index: Int, isPdf: Bool) -> String { "Страница \(index + 1)" + (isPdf ? " (PDF)" : "") }
    static func tooManyPages(_ max: Int) -> String { "Не больше \(max) страниц за раз — разбейте накладную на части." }
    static func partAdded(_ added: Int, of total: Int, max: Int) -> String {
        "Добавлено \(added) из \(total): не больше \(max) страниц за раз."
    }
    static func megabytes(_ bytes: Int) -> Int { bytes / (1024 * 1024) }
    static func fileTooBig(_ bytes: Int) -> String {
        "Файл больше \(megabytes(bytes)) МБ — уменьшите его или разбейте накладную на части."
    }
    static func totalTooBig(_ bytes: Int) -> String {
        "Общий размер файлов больше \(megabytes(bytes)) МБ — уберите часть страниц или снимите по 1–2 страницы."
    }
    static func limitsHint(maxFiles: Int, maxBytes: Int) -> String {
        "Можно снять несколько страниц подряд — до \(maxFiles). Фото уходят в JPEG, общий размер — не больше \(megabytes(maxBytes)) МБ."
    }

    /// Заголовок строки накладной: «3. Молоко» (номер помогает найти позицию из текста отказа сервера).
    static func lineTitle(_ line: OcrLine) -> String {
        let name = (line.name ?? "").isEmpty ? "Без названия" : (line.name ?? "")
        if let n = line.lineNo, n > 0 { return "\(n). " + name }
        return name
    }

    /// Имя файла страницы: invoice_1.jpg
    static func pageName(_ index: Int) -> String { "invoice_\(index + 1).jpg" }

    /// Сумма размеров не больше лимита сервера (0 или нет лимита — не проверяем).
    static func fitsLimit(_ sizes: [Int], maxBytes: Int?) -> Bool {
        guard let m = maxBytes, m > 0 else { return true }
        return sizes.reduce(0, +) <= m
    }

    /// Строка нужна как строка-значение для JSON: 10.5 -> "10.5" (точка, без локали).
    static func plain(_ v: Decimal) -> String { NSDecimalNumber(decimal: v).stringValue }

    /// То же для поля ввода: запятая вместо точки, без округления до копеек (количество — 3 знака).
    static func input(_ v: Decimal) -> String { plain(v).replacingOccurrences(of: ".", with: ",") }
}
