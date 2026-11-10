import Foundation

// ============================================================================
//  Импорт заданиями: чистая логика и ВСЕ тексты (без UI и сети).
//  Слова и правила те же, что на Android (core/ImportLogic.kt) — менять только парой.
//  Сервер: routes/seller_import.php, core/ImportJob.php, core/ImportPlanner.php.
// ============================================================================

/// Есть ли «Импорт заданиями» на сервере. Проба — GET /import/jobs (1 запись).
/// 403 / 404 / 405 / 503 — режима нет, старый импорт работает как раньше; обрыв связи — «не знаем» (старый импорт).
/// probing — пока идёт первая проба: экран ждёт ответ, чтобы не показать сначала старый вид, а потом новый.
/// Класс без @MainActor, как ExportFeature.
final class ImportJobsFeature: ObservableObject {
    static let shared = ImportJobsFeature()
    @Published private(set) var available = false
    @Published private(set) var probing = false

    private var checkedShop: Int?
    private var checkedAt = Date.distantPast
    private var checkingShop: Int?

    private init() {}

    @MainActor
    func refresh(shopId: Int?) async {
        guard let sid = shopId, Session.shared.can("products") else {
            available = false; probing = false; checkedShop = nil; checkedAt = Date.distantPast
            return
        }
        if checkedShop != sid { available = false }
        if checkedShop == sid && Date().timeIntervalSince(checkedAt) < 600 { return }
        guard checkingShop != sid else { return }
        checkingShop = sid
        if !available { probing = true }
        defer {
            if checkingShop == sid { checkingShop = nil }
            probing = false
        }
        do {
            _ = try await API.shared.impJobs(page: 1, perPage: 1, retries: 0)
            guard Session.shared.activeShopId == sid else { return }
            available = true; checkedShop = sid; checkedAt = Date()
        } catch {
            guard Session.shared.activeShopId == sid else { return }
            switch FeatureProbe.from(error) {
            case .hidden:
                available = false; checkedShop = sid; checkedAt = Date()
            default:
                break
            }
        }
    }
}

enum ImpLogic {
    // ── Тексты ───────────────────────────────────────────────────────────

    static let pickWhat = "Что импортируем"
    static let pickFile = "Выбрать файл"
    static let pickHint = "CSV или XLSX до 10 МБ, до 19 999 строк. Проще всего скачать шаблон в разделе «Выгрузки и обмен», заполнить его и загрузить обратно."
    static let fileBadExt = "Нужен файл .csv или .xlsx — например, шаблон из «Выгрузки и обмен»"
    static let fileTooBig = "Файл больше 10 МБ — сервер такой не примет"
    static let fileReadFail = "Не удалось прочитать файл"
    static let uploading = "Загружаем…"
    static let columns = "Колонки файла"
    static let notFill = "— не заполнять —"
    static let columnN = "Колонка"
    static let sheet = "Лист таблицы"
    static let mode = "Режим"
    static let skipErrors = "Пропускать строки с ошибками"
    static let blankClears = "Пустая ячейка очищает поле"
    static let blankWarning = "Пустая ячейка очистит поле: если в колонке файла ячейка пуста, значение в каталоге будет стёрто."
    static let hideMissing = "Скрыть товары, которых нет в файле"
    static let anotherFile = "Выбрать другой файл"
    static let check = "Проверить файл"
    static let checking = "Проверяем…"
    static let checkAgain = "Проверить ещё раз"
    static let checkRestart = "Проверить заново"
    static let checkRunning = "Идёт проверка файла…"
    static let networkWait = "Нет связи — проверим позже"
    static let slow = "Ждём дольше обычного. Вернитесь позже: задание останется в списке «История импортов»."
    static let stalled = "Идёт медленно — сервер ещё работает. Можно подождать или вернуться позже."
    static let summary = "Что получится"
    static let summaryNote = "Это только расчёт — в каталоге пока ничего не изменилось."
    static let nothingToChange = "Нечего менять — в файле нет новых или изменённых товаров."
    static let rowsTitle = "Строки проверки"
    static let rowsLoading = "Загружаем строки…"
    static let rowsEmpty = "Нет строк для показа"
    static let rowsMore = "Показать ещё"
    static let was = "было"
    static let willBe = "станет"
    static let emptyValue = "пусто"
    static let errorsFile = "Скачать файл ошибок и поделиться"
    static let errorsFileLoading = "Скачиваем…"
    static let run = "Запустить импорт"
    static let runStarting = "Запускаем…"
    static let runNote = "Изменения сразу попадут в каталог. Отменить их можно будет кнопкой «Откатить импорт» в течение 30 дней."
    static let runYes = "Изменить"
    static let keep = "Не надо"
    static let confirmHide = "Подтверждаю: скрыть эти товары"
    static let runUnsure = "Не удалось узнать, запустился ли импорт, — проверьте состояние задания и повторите."
    static let runUnsureFail = "Нет связи — не удалось узнать, запустился ли импорт. Не запускайте его второй раз, пока не откроете «История импортов» и не убедитесь, что он не идёт."
    static let pause = "Пауза"
    static let resume = "Продолжить"
    static let cancel = "Отменить импорт"
    static let cancelTitle = "Отменить импорт?"
    static let cancelNote = "Уже внесённые изменения останутся — их можно откатить."
    static let cancelYes = "Отменить"
    static let rollback = "Откатить импорт"
    static let rollbackTitle = "Откатить импорт?"
    static let rollbackNote = "Цены и поля вернутся к значениям до импорта, если их не правили после него. Товары, созданные импортом, будут скрыты. Откат возможен в течение 30 дней."
    static let rollbackYes = "Откатить"
    static let rollbackResult = "Итоги отката"
    static let result = "Итоги"
    static let history = "История импортов"
    static let historyOpen = "Открыть"
    static let activeFound = "Есть незавершённый импорт"
    static let newImport = "Импортировать ещё файл"
    static let close = "Закрыть"
    static let permsChangedHint = "Проверьте файл заново — после этого запуск снова станет доступен."
    static let noRightRun = "Запускать импорт может владелец или сотрудник с правом «Создавать товары» — файл можно только проверить."

    /// Максимальный размер файла: больше сервер не примет.
    static let maxBytes = 10 * 1024 * 1024

    /// «Изменить 5 товаров?» — число товаров, которые создадутся или изменятся.
    static func confirmTitle(_ n: Int) -> String {
        "Изменить \(n) \(plural(n, "товар", "товара", "товаров"))?"
    }

    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m100 = n % 100
        let m10 = n % 10
        if (11...14).contains(m100) { return many }
        if m10 == 1 { return one }
        if (2...4).contains(m10) { return few }
        return many
    }

    static func hideText(hide: Int, catalog: Int, pct: Int) -> String {
        "Будет скрыто \(hide) из \(catalog) товаров (\(pct)%)"
    }

    // ── Статусы, фазы ────────────────────────────────────────────────────

    static let uploaded = "uploaded"
    static let previewing = "previewing"
    static let previewReady = "preview_ready"
    static let running = "running"
    static let paused = "paused"
    static let done = "done"
    static let cancelled = "cancelled"
    static let failed = "failed"
    static let rolledBack = "rolled_back"

    static func isRollbackPhase(_ job: ImpJob?) -> Bool {
        job?.status == running && job?.phase == "rollback"
    }

    /// Конечный статус: опрос не нужен. Неизвестный статус — не конечный.
    static func isFinal(_ status: String?) -> Bool {
        let s = status ?? ""
        return s == done || s == cancelled || s == failed || s == rolledBack
    }

    /// Опрашиваем, пока сервер что-то делает сам: проверка или импорт (откат тоже running). Пауза и ожидание — не опрашиваем.
    static func isPolling(_ status: String?) -> Bool {
        let s = status ?? ""
        return s == previewing || s == running
    }

    static func statusText(_ status: String?) -> String {
        switch status ?? "" {
        case uploaded: return "Файл загружен"
        case previewing: return "Проверяется"
        case previewReady: return "Проверен"
        case running: return "Идёт"
        case paused: return "На паузе"
        case done: return "Готово"
        case cancelled: return "Отменён"
        case failed: return "Ошибка"
        case rolledBack: return "Откатан"
        default: return ""
        }
    }

    static func title(_ job: ImpJob?) -> String {
        guard let job else { return "" }
        if isRollbackPhase(job) { return "Идёт откат…" }
        switch job.status ?? "" {
        case uploaded: return "Файл загружен"
        case previewing: return checkRunning
        case previewReady: return "Проверка готова"
        case running: return "Идёт импорт…"
        case paused: return "Импорт на паузе"
        case done: return "Импорт завершён"
        case cancelled: return "Импорт отменён"
        case failed: return "Импорт не удался"
        case rolledBack: return "Импорт откатан"
        default: return ""
        }
    }

    /// Прогресс 0–100; нет данных — nil (неопределённая полоса).
    static func progress(_ job: ImpJob?) -> Int? {
        guard let p = job?.progress else { return nil }
        return min(100, max(0, p))
    }

    static func progressText(_ job: ImpJob?) -> String {
        let t = title(job)
        guard let p = progress(job), p > 0 else { return t }
        return "\(t) \(p)%"
    }

    static func rowsText(_ job: ImpJob?) -> String? {
        guard let total = job?.totalRows, total > 0 else { return nil }
        guard let done = job?.cursor else { return "Строк: \(total)" }
        return "Строк: \(min(max(done, 0), total)) из \(total)"
    }

    /// Кнопки — по флагам can_* сервера; флага нет (старый ответ) — по статусу. Откат без флага не показываем.
    static func canRun(_ job: ImpJob?, hasRight: Bool) -> Bool {
        guard let job, hasRight else { return false }
        return job.canRun ?? (job.status == previewReady)
    }

    static func canPause(_ job: ImpJob?) -> Bool {
        guard let job else { return false }
        if isRollbackPhase(job) { return false }
        return job.canPause ?? (job.status == running)
    }

    static func canResume(_ job: ImpJob?, hasRight: Bool) -> Bool {
        guard let job, hasRight else { return false }
        if job.phase == "rollback" { return false }
        return job.canResume ?? (job.status == paused)
    }

    static func canCancel(_ job: ImpJob?) -> Bool {
        guard let job else { return false }
        return job.canCancel ?? (job.status != nil && !isFinal(job.status))
    }

    static func canRollback(_ job: ImpJob?, hasRight: Bool) -> Bool {
        guard let job, hasRight else { return false }
        return job.canRollback ?? false
    }

    // ── plan, counts, options ────────────────────────────────────────────

    struct Plan {
        var add = 0, update = 0, unchanged = 0, skip = 0, error = 0, warn = 0
        var hide = 0, catalog = 0, hidePct = 0
        var hideNeedsConfirm = false
        /// Сколько товаров создастся или изменится.
        var changes: Int { add + update }
    }

    struct Counts {
        var add = 0, update = 0, unchanged = 0, skip = 0, error = 0
        var stockSkipped = 0, priceNoRight = 0, stockNoRight = 0
        var moderationHidden = 0, photoFailed = 0, hidden = 0
    }

    struct RollbackInfo {
        var restored = 0, conflicts = 0, hidden = 0
    }

    /// Число из значения сервера: 12, "12", "12.0"; нечитаемое — 0.
    private static func int(_ o: [String: ImpJSON]?, _ key: String) -> Int {
        guard let t = o?[key]?.text else { return 0 }
        if let i = Int(t) { return i }
        if let d = Double(t), d.isFinite, abs(d) < 9e18 { return Int(d) }
        return 0
    }

    private static func bool(_ o: [String: ImpJSON]?, _ key: String) -> Bool? {
        guard let v = o?[key] else { return nil }
        switch v {
        case .bool(let b): return b
        case .number(let n): return (Double(n) ?? 0) != 0
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            return t == "1" || t == "true"
        default: return nil
        }
    }

    /// Проверка файла (plan). Блока нет или это [] — nil.
    static func plan(_ job: ImpJob?) -> Plan? {
        guard let o = job?.plan?.object else { return nil }
        return Plan(add: int(o, "add"), update: int(o, "update"), unchanged: int(o, "unchanged"),
                    skip: int(o, "skip"), error: int(o, "error"), warn: int(o, "warn"),
                    hide: int(o, "hide"), catalog: int(o, "catalog"), hidePct: int(o, "hide_pct"),
                    hideNeedsConfirm: bool(o, "hide_needs_confirm") ?? false)
    }

    /// Итоги выполнения: counts.apply; если вложенного блока нет — сам counts.
    static func counts(_ job: ImpJob?) -> Counts? {
        guard let root = job?.counts?.object else { return nil }
        let o = root["apply"]?.object ?? root
        return Counts(add: int(o, "add"), update: int(o, "update"), unchanged: int(o, "unchanged"),
                      skip: int(o, "skip"), error: int(o, "error"),
                      stockSkipped: int(o, "stock_skipped"), priceNoRight: int(o, "price_no_right"),
                      stockNoRight: int(o, "stock_no_right"), moderationHidden: int(o, "moderation_hidden"),
                      photoFailed: int(o, "photo_failed"), hidden: int(o, "hidden"))
    }

    static func rollbackInfo(_ job: ImpJob?) -> RollbackInfo? {
        guard let o = job?.rollback?.object else { return nil }
        return RollbackInfo(restored: int(o, "restored"), conflicts: int(o, "conflicts"), hidden: int(o, "hidden"))
    }

    /// Настройка задания (options): blank_clears, hide_missing, skip_errors… Нет значения — nil.
    static func option(_ job: ImpJob?, _ key: String) -> Bool? {
        bool(job?.options?.object, key)
    }

    /// Предупреждение «Пустая ячейка очистит поле» показываем, когда так настроено задание.
    static func blankClears(_ job: ImpJob?) -> Bool {
        option(job, "blank_clears") == true
    }

    /// Строки итогов выполнения: подпись и число (дополнительные нулевые не показываем).
    static func resultLines(_ c: Counts) -> [(String, Int)] {
        let main: [(String, Int)] = [
            ("Создано", c.add), ("Изменено", c.update), ("Без изменений", c.unchanged),
            ("Пропущено", c.skip), ("Ошибки", c.error),
        ]
        let extra: [(String, Int)] = [
            ("Скрыто товаров, которых нет в файле", c.hidden),
            ("Остаток не изменён", c.stockSkipped),
            ("Нет права на цену, строк", c.priceNoRight),
            ("Нет права на остатки, строк", c.stockNoRight),
            ("Скрыто до проверки модератором", c.moderationHidden),
            ("Фото не загрузились", c.photoFailed),
        ].filter { $0.1 > 0 }
        return main + extra
    }

    static func rollbackLines(_ r: RollbackInfo) -> [(String, Int)] {
        let all: [(String, Int)] = [
            ("Возвращено полей", r.restored),
            ("Не возвращено — поле правили после импорта", r.conflicts),
            ("Скрыто созданных товаров", r.hidden),
        ]
        return all.filter { $0.1 > 0 }
    }

    // ── Строки ───────────────────────────────────────────────────────────

    static let filters: [(String, String)] = [
        ("changed", "Изменения"), ("error", "Ошибки"), ("warn", "Предупреждения"), ("all", "Все"),
    ]

    static let rowsPerPage = 50

    static func actionText(_ action: String?) -> String {
        switch action ?? "" {
        case "add": return "Создастся"
        case "update": return "Изменится"
        case "unchanged": return "Без изменений"
        case "skip": return "Пропущено"
        case "error": return "Ошибка"
        default: return ""
        }
    }

    /// Значение diff.from / diff.to: строка, число, null — всё показываем строкой. Длинное обрезаем.
    static func valueText(_ v: ImpJSON?) -> String {
        var raw = ""
        if let v {
            switch v {
            case .null: raw = ""
            case .string(let s): raw = s
            case .number(let n): raw = n
            case .bool(let b): raw = b ? "да" : "нет"
            case .array, .object: raw = "…"
            }
        }
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return emptyValue }
        return raw.count > 120 ? String(raw.prefix(120)) + "…" : raw
    }

    static func diffLabel(_ d: ImpDiff) -> String {
        let l = (d.label ?? "").trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? (d.field ?? "") : l
    }

    static func rowTitle(_ r: ImpRow) -> String {
        let n = (r.name ?? "").trimmingCharacters(in: .whitespaces)
        let line = r.line ?? 0
        return n.isEmpty ? "Строка \(line)" : "Строка \(line) · \(n)"
    }

    /// «Цена: текст сервера» или просто текст.
    static func rowErrorText(_ e: ImpRowError) -> String {
        let m = (e.message ?? "").trimmingCharacters(in: .whitespaces)
        let l = (e.label ?? "").trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? m : "\(l): \(m)"
    }

    static func isWarning(_ e: ImpRowError) -> Bool {
        e.level == "warning" || e.level == "info"
    }

    static func hasMore(page: Int?, pages: Int?) -> Bool {
        guard let page, let pages else { return false }
        return page < pages
    }

    // ── Настройки ────────────────────────────────────────────────────────

    /// Режимы для вида импорта: «только цены и остатки» — только для товаров.
    static func modes(target: String) -> [(String, String)] {
        var out: [(String, String)] = [
            ("both", "Добавлять и обновлять"), ("add", "Только добавлять"), ("update", "Только обновлять"),
        ]
        if target == "products" { out.append(("prices_stock", "Только цены и остатки")) }
        return out
    }

    /// «Скрыть товары, которых нет в файле» — только товары и режимы «добавить и обновить» / «только обновлять».
    static func hideAllowed(target: String, mode: String) -> Bool {
        target == "products" && (mode == "both" || mode == "update")
    }

    /// Тело POST …/preview. Права (can_price, can_wh) не шлём — сервер берёт их у нажавшего.
    static func previewBody(mapping: [String: Int], mode: String, skipErrors: Bool,
                            blankClears: Bool, hideMissing: Bool) -> [String: Any?] {
        var m: [String: Int] = [:]
        for (k, v) in mapping where v >= 0 { m[k] = v }
        return [
            "mapping": m,
            "mode": mode,
            "match_by": ["article", "barcode", "id", "name"],
            "skip_errors": skipErrors,
            // Выключенные флаги шлём явно false: поле, которого нет в теле, сервер заполняет своим умолчанием.
            "blank_clears": blankClears,
            "hide_missing": hideMissing,
            "strict": true,
        ]
    }

    /// Сопоставление задания (mapping): поле → номер колонки. Не объект ([]) и мусор — пустая карта.
    static func mappingOf(_ job: ImpJob?) -> [String: Int] {
        guard let o = job?.mapping?.object else { return [:] }
        var out: [String: Int] = [:]
        for (k, v) in o {
            guard let t = v.text else { continue }
            let n = Int(t) ?? Double(t).flatMap { $0.isFinite && abs($0) < 9e18 ? Int($0) : nil }
            if let n, n >= 0 { out[k] = n }
        }
        return out
    }

    /// Повторная проверка с теми же настройками, что у задания («Проверить заново»).
    static func previewBodyFromJob(_ job: ImpJob) -> [String: Any?] {
        let m = (job.mode ?? "").isEmpty ? "both" : (job.mode ?? "both")
        return previewBody(mapping: mappingOf(job), mode: m,
                           skipErrors: option(job, "skip_errors") ?? true,
                           blankClears: option(job, "blank_clears") ?? false,
                           hideMissing: option(job, "hide_missing") ?? false)
    }

    static func isAllowedFileName(_ name: String?) -> Bool {
        let ext = ((name ?? "") as NSString).pathExtension.lowercased()
        return ext == "csv" || ext == "xlsx"
    }

    static func mime(for name: String) -> String {
        name.lowercased().hasSuffix(".csv") ? "text/csv" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    }

    static func errorsFileName(_ job: ImpJob) -> String { "import_errors_\(job.id).xlsx" }

    static func errorsFilePath(_ job: ImpJob) -> String {
        "api/seller/import/jobs/\(job.id)/errors-file?scope=errors&format=xlsx"
    }

    /// Подпись строки истории: «price.xlsx · Готово · 2026-11-05 10:15:00».
    static func jobLine(_ job: ImpJob) -> String {
        var parts: [String] = []
        if let f = job.fileName?.trimmingCharacters(in: .whitespaces), !f.isEmpty { parts.append(f) }
        let s = statusText(job.status)
        if !s.isEmpty { parts.append(s) }
        if let c = job.createdAt?.trimmingCharacters(in: .whitespaces), !c.isEmpty { parts.append(c) }
        return parts.joined(separator: " · ")
    }

    // ── Ошибки ───────────────────────────────────────────────────────────

    /// Текст отказа: сервер дословно; 429 лимита частоты — свой запасной.
    static func errorText(_ error: Error) -> String { SellerNewErrors.text(error) }

    /// 409 perms_changed: у нажавшего прав стало меньше, чем при проверке — нужна новая проверка.
    static func isPermsChanged(_ error: Error) -> Bool { SellerNewErrors.code(error) == "perms_changed" }

    /// Временный сбой при опросе: обрыв, таймаут, 5xx и 429 (лимит частоты) — ждём и повторяем.
    static func isTransient(_ error: Error) -> Bool { ExpLogic.isTransient(error) }

    /// Исход запроса неизвестен (обрыв, таймаут, 5xx).
    static func isUnknownOutcome(_ error: Error) -> Bool { ExpLogic.isUnknownOutcome(error) }

    /// Пауза до следующего опроса: 2,5 с; после сбоев подряд растёт (5, 8, 10 с). Как на Android.
    static func pollNanos(failures: Int) -> UInt64 {
        let ms: UInt64
        switch failures {
        case ...0: ms = 2_500
        case 1: ms = 5_000
        case 2: ms = 8_000
        default: ms = 10_000
        }
        return ms * 1_000_000
    }

    /// Через 10 минут опроса экран останавливается и даёт «Проверить ещё раз».
    static let pollGiveUpSeconds: TimeInterval = 600
}
