import Foundation

// ============================================================================
//  Выгрузка заданиями и фиды площадок: чистая логика и ВСЕ тексты (без UI и сети).
//  Слова и правила те же, что на Android (core/ExportLogic.kt) — менять только парой.
//  Сервер: routes/seller_feeds.php, core/Export.php, core/Feeds.php.
// ============================================================================

/// Есть ли «Выгрузка с фильтрами» на сервере. Проба — GET /exports/jobs.
/// 403 / 404 / 405 / 503 — режима нет, старый экспорт работает как раньше. Класс без @MainActor, как RevalFeature.
final class ExportFeature: ObservableObject {
    static let shared = ExportFeature()
    @Published private(set) var available = false

    private var checkedShop: Int?
    private var checkedAt = Date.distantPast
    private var checkingShop: Int?

    private init() {}

    @MainActor
    func refresh(shopId: Int?) async {
        let s = Session.shared
        guard let sid = shopId, s.can("products") || s.can("warehouse") || s.can("orders") || s.can("customers") else {
            available = false; checkedShop = nil; checkedAt = Date.distantPast
            return
        }
        if checkedShop != sid { available = false }
        if checkedShop == sid && Date().timeIntervalSince(checkedAt) < 600 { return }
        guard checkingShop != sid else { return }
        checkingShop = sid
        defer { if checkingShop == sid { checkingShop = nil } }
        do {
            _ = try await API.shared.expJobs(retries: 0)
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

/// Есть ли «Фиды для площадок» (право «Товары»; старый сервер — 404/405, пункта нет).
final class FeedFeature: ObservableObject {
    static let shared = FeedFeature()
    @Published private(set) var available = false

    private var checkedShop: Int?
    private var checkedAt = Date.distantPast
    private var checkingShop: Int?

    private init() {}

    @MainActor
    func refresh(shopId: Int?) async {
        guard let sid = shopId, Session.shared.can("products") else {
            available = false; checkedShop = nil; checkedAt = Date.distantPast
            return
        }
        if checkedShop != sid { available = false }
        if checkedShop == sid && Date().timeIntervalSince(checkedAt) < 600 { return }
        guard checkingShop != sid else { return }
        checkingShop = sid
        defer { if checkingShop == sid { checkingShop = nil } }
        do {
            _ = try await API.shared.feeds(retries: 0)
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

enum ExpLogic {
    // ── Тексты ───────────────────────────────────────────────────────────

    static let newTitle = "Выгрузка с фильтрами"
    static let newHint = "Сервер соберёт файл по вашим фильтрам. Большие выгрузки готовятся несколько минут — экран можно оставить открытым."
    static let configure = "Настроить"
    static let what = "Что выгрузить"
    static let preset = "Набор"
    static let presetDefault = "Стандартный"
    static let format = "Формат"
    static let filters = "Фильтры"
    static let start = "Подготовить файл"
    static let starting = "Запускаем…"
    static let preparing = "Готовим файл…"
    static let networkWait = "Нет связи — проверим позже"
    static let slow = "Подготовка идёт дольше обычного. Вернитесь позже: файл будет в списке «Последние выгрузки»."
    static let checkAgain = "Проверить ещё раз"
    static let ready = "Файл готов"
    static let download = "Скачать и поделиться"
    static let downloading = "Скачиваем…"
    static let cancel = "Отменить выгрузку"
    static let cancelTitle = "Отменить выгрузку?"
    static let cancelNote = "Подготовка файла остановится."
    static let cancelYes = "Отменить"
    static let keep = "Не надо"
    static let recent = "Последние выгрузки"
    static let failedTitle = "Не удалось подготовить файл"
    static let cancelledTitle = "Выгрузка отменена"
    static let expiredText = "Срок хранения файла (сутки) истёк — создайте выгрузку заново"
    static let ttlNote = "Готовый файл хранится сутки."
    static let vatWarning = "Не указана ставка НДС магазина — проверьте настройки"
    static let dateOrderError = "Дата «с» позже даты «по»"
    static let dateNotSet = "Не выбрана"
    static let dateClear = "Сбросить"
    static let close = "Закрыть"
    static let unknownStart = "Если выгрузка уже появилась в списке «Последние выгрузки» — второй раз запускать её не нужно."
    static let notFound = "Выгрузка не найдена"
    static let anyValue = "Любой"

    static func rowsText(done: Int?, total: Int?) -> String? {
        if let t = total, t > 0, let d = done { return "Строк: \(d) из \(t)" }
        if let t = total, t > 0 { return "Строк: \(t)" }
        return nil
    }

    static func progressPercentText(_ job: ExpJob?) -> String {
        let p = job?.progress ?? 0
        return p <= 0 ? preparing : "\(preparing) \(p)%"
    }

    static func warnings(_ job: ExpJob?) -> [String] {
        (job?.warnings ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // ── Виды ─────────────────────────────────────────────────────────────

    /// Вид выгрузки: путь (kind), подпись, подсказка и право сервера.
    struct Kind: Identifiable, Hashable {
        let key: String
        let title: String
        let hint: String
        let perm: String
        var id: String { key }
    }

    static let allKinds: [Kind] = [
        Kind(key: "products", title: "Товары", hint: "Каталог: цены, остатки, категории", perm: "products"),
        Kind(key: "orders", title: "Заказы", hint: "Заказы за период, суммы и оплата", perm: "orders"),
        Kind(key: "clients", title: "Клиенты", hint: "Контакты и суммы покупок", perm: "customers"),
        Kind(key: "stock", title: "Остатки склада", hint: "Товары и ингредиенты по складам", perm: "warehouse"),
        Kind(key: "ingredients", title: "Ингредиенты", hint: "Справочник ингредиентов", perm: "warehouse"),
    ]

    /// Виды, доступные этому магазину и сотруднику: ингредиенты — только ресторан, склада нет у услуг и жилья.
    static func kinds(shopType: String, can: (String) -> Bool) -> [Kind] {
        allKinds.filter { k in
            guard can(k.perm) else { return false }
            switch k.key {
            case "ingredients": return shopType == "cafe"
            case "stock": return shopType != "service" && shopType != "lodging"
            default: return true
            }
        }
    }

    // ── Статусы ──────────────────────────────────────────────────────────

    /// Конечный статус: опрос прекращаем. Неизвестный статус — не конечный (ждём дальше).
    static func isFinal(_ status: String?) -> Bool {
        let s = status ?? ""
        return s == "done" || s == "failed" || s == "cancelled" || s == "expired"
    }

    static func statusText(_ status: String?) -> String {
        switch status ?? "" {
        case "queued": return "В очереди"
        case "running": return "Готовится"
        case "done": return "Готово"
        case "failed": return "Ошибка"
        case "cancelled": return "Отменено"
        case "expired": return "Срок хранения истёк"
        default: return ""
        }
    }

    /// Пауза до следующего опроса: 3 с; после сбоев подряд растёт (5, 8, 10 с). Как на Android.
    static func pollNanos(failures: Int) -> UInt64 {
        let ms: UInt64
        switch failures {
        case ...0: ms = 3_000
        case 1: ms = 5_000
        case 2: ms = 8_000
        default: ms = 10_000
        }
        return ms * 1_000_000
    }

    /// Через 10 минут опроса экран останавливается и даёт «Проверить ещё раз».
    static let pollGiveUpSeconds: TimeInterval = 600

    /// «1,2 МБ» / «340 КБ» / «120 Б»; пусто или 0 — nil.
    static func sizeText(_ bytes: Int?) -> String? {
        guard let b = bytes, b > 0 else { return nil }
        if b >= 1_048_576 {
            let tenths = (b * 10 + 524_288) / 1_048_576
            return "\(tenths / 10),\(tenths % 10) МБ"
        }
        if b >= 1024 { return "\(b / 1024) КБ" }
        return "\(b) Б"
    }

    // ── Ошибки ───────────────────────────────────────────────────────────

    /// Текст отказа: сервер дословно; 429 лимита частоты — свой запасной.
    static func errorText(_ error: Error) -> String { SellerNewErrors.text(error) }

    /// Временный сбой при опросе: обрыв, таймаут, 5xx и 429 (лимит частоты) - ждём и повторяем, задание не проваливаем.
    static func isTransient(_ error: Error) -> Bool {
        if isUnknownOutcome(error) { return true }
        return SellerNewErrors.status(error) == 429
    }

    /// Исход запроса неизвестен (обрыв, таймаут, 5xx).
    static func isUnknownOutcome(_ error: Error) -> Bool {
        if let e = error as? APIError {
            switch e {
            case .network, .timeout: return true
            case .http(let code): return code >= 500
            default: return false
            }
        }
        if let s = SellerNewErrors.status(error) { return s >= 500 }
        return false
    }

    // ── Фильтры и тело ───────────────────────────────────────────────────

    /// Пресеты вида: сначала системные, потом сохранённые; без id/названия пропускаем.
    static func presets(_ meta: ExpMeta?) -> [ExpPreset] {
        let all = (meta?.presets?.system ?? []) + (meta?.presets?.saved ?? [])
        return all.filter { !($0.presetId ?? "").isEmpty && !($0.name ?? "").isEmpty }
    }

    /// Формат из списка сервера: желаемый, если он есть, иначе xlsx (если есть или список пуст), иначе первый.
    static func pickFormat(_ meta: ExpMeta?, wanted: String?) -> String {
        let values = (meta?.formats ?? []).compactMap { $0.value }.filter { !$0.isEmpty }
        if let w = wanted, values.contains(w) { return w }
        if values.isEmpty || values.contains("xlsx") { return "xlsx" }
        return values[0]
    }

    /// Ошибка заполнения до отправки (nil — можно слать). Сейчас: «с» не позже «по».
    static func validate(_ filters: [String: String]) -> String? {
        let from = (filters["from"] ?? "").trimmingCharacters(in: .whitespaces)
        let to = (filters["to"] ?? "").trimmingCharacters(in: .whitespaces)
        if !from.isEmpty && !to.isEmpty && from > to { return dateOrderError }
        return nil
    }

    /// Фильтры для запроса: пустые не шлём (иначе сервер скажет «задан неверно»).
    static func cleanFilters(_ filters: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in filters {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out[k] = t }
        }
        return out
    }

    /// Имя файла: безопасные символы, расширение из формата.
    static func fileName(for job: ExpJob?) -> String {
        let raw = (job?.fileName ?? "").trimmingCharacters(in: .whitespaces)
        var safe = ""
        for ch in raw.unicodeScalars {
            let ok = (ch.value < 128 && CharacterSet.alphanumerics.contains(ch)) || ch == "." || ch == "_" || ch == "-"
            safe.append(ok ? Character(ch) : "_")
        }
        while safe.hasPrefix(".") { safe.removeFirst() }
        if !safe.isEmpty { return safe }
        return "export_\(job?.id ?? 0)" + (job?.format == "csv" ? ".csv" : ".xlsx")
    }

    /// Подпись строки списка: «Товары · XLSX · Готово».
    static func jobLine(_ job: ExpJob) -> String {
        var parts: [String] = []
        if let t = job.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { parts.append(t) }
        if let f = job.format?.trimmingCharacters(in: .whitespaces), !f.isEmpty { parts.append(f.uppercased()) }
        let s = statusText(job.status)
        if !s.isEmpty { parts.append(s) }
        return parts.joined(separator: " · ")
    }
}

/// Черновик настроек фида: строки ввода как есть, проверка и тело — в FeedLogic.
struct FeedDraft: Equatable {
    var onlyAvailable = false
    var descFallback = false
    var markup = "0"
    var categories: Set<String> = []
    var utmSource = ""
    var utmMedium = ""
    var utmCampaign = ""
    var avitoCategory = ""
    var avitoGoodsType = ""
    var avitoAdType = ""
    var avitoAddress = ""
    var avitoPhone = ""
    var avitoManager = ""
    var googleBrand = ""
    var googleProductCategory = ""
}

/// Фиды для площадок: тексты и правила настроек.
enum FeedLogic {
    static let sectionTitle = "Фиды для площадок"
    static let hint = "Ссылка на каталог для Яндекс Маркета, VK, Авито и Google Merchant. Площадка сама забирает файл по ссылке."
    static let enabled = "Включён"
    static let link = "Ссылка на фид"
    static let copy = "Скопировать"
    static let copied = "Ссылка скопирована"
    static let share = "Поделиться"
    static let rotate = "Перевыпустить ссылку"
    static let rotateTitle = "Перевыпустить ссылку?"
    static let rotateNote = "Старая ссылка перестанет работать сразу: площадку придётся настроить заново."
    static let rotateYes = "Перевыпустить"
    static let keep = "Не надо"
    static let urlHidden = "Показать ссылку не получилось — перевыпустите её."
    static let rebuild = "Собрать сейчас"
    static let rebuilding = "Собираем…"
    static let settings = "Настройки"
    static let save = "Сохранить"
    static let saved = "Настройки сохранены"
    static let close = "Закрыть"
    static let issues = "Что исправить в товарах"
    static let howTo = "Как подключить"
    static let vatTitle = "Ставка НДС магазина"
    static let vatNotSet = "Не указана"
    static let vatWarning = "Не указана ставка НДС магазина — проверьте настройки"
    static let networkWait = "Нет связи — проверим позже"
    static let onlyAvailable = "Только товары в наличии"
    static let descFallback = "Подставлять название вместо пустого описания"
    static let markup = "Наценка, %"
    static let markupHint = "От 0 до 300, например 5 или 7,5"
    static let categories = "Категории"
    static let categoriesAll = "Все категории"
    static let utmTitle = "UTM-метки"
    static let avitoTitle = "Объявления Авито"
    static let googleTitle = "Google Merchant"
    static let markupError = "Наценка — число от 0 до 300 процентов, не больше двух знаков после точки"
    static let categoriesMaxError = "Можно выбрать не больше 300 категорий"
    static let categoriesMax = 300

    /// Пока хоть один фид собирается, список перечитываем раз в 5 с (до 10 минут).
    static let buildPollNanos: UInt64 = 5_000_000_000

    static func statusText(_ c: FeedCard) -> String {
        switch c.status ?? "" {
        case "off": return "Выключен"
        case "building": return "Собирается"
        case "ok": return "Работает"
        case "warn": return "Работает, есть замечания"
        case "error": return "Ошибка сборки"
        default: return (c.enabled ?? false) ? "Включён" : "Выключен"
        }
    }

    static func isBuilding(_ c: FeedCard) -> Bool { c.status == "building" }

    /// «Собран: только что / 5 мин назад / 3 ч назад / 2 дн. назад»; нет данных — nil.
    static func builtText(_ c: FeedCard) -> String? {
        guard let m = c.builtMinAgo else {
            if let raw = c.builtAt?.trimmingCharacters(in: .whitespaces), !raw.isEmpty { return "Собран: " + raw }
            return nil
        }
        return "Собран: " + agoText(m)
    }

    static func fetchText(_ c: FeedCard) -> String? {
        guard let m = c.lastFetchMinAgo else { return nil }
        return "Площадка забирала файл: " + agoText(m)
    }

    private static func agoText(_ minutes: Int) -> String {
        if minutes < 1 { return "только что" }
        if minutes < 60 { return "\(minutes) мин назад" }
        if minutes < 1440 { return "\(minutes / 60) ч назад" }
        return "\(minutes / 1440) дн. назад"
    }

    /// «Товаров в файле: 340, пропущено: 12»; ничего не собрано — nil.
    static func itemsText(_ c: FeedCard) -> String? {
        guard let n = c.items else { return nil }
        if (c.builtAt ?? "").trimmingCharacters(in: .whitespaces).isEmpty && n == 0 { return nil }
        let sk = c.skipped ?? 0
        return "Товаров в файле: \(n)" + (sk > 0 ? ", пропущено: \(sk)" : "")
    }

    /// Подпись ставки НДС: value сервера → слова.
    static func vatLabel(_ value: String?, labels: [String: String]) -> String {
        let v = value ?? ""
        if let l = labels[v], !l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
        return v.isEmpty ? vatNotSet : v
    }

    static func issueLine(title: String?, count: Int?) -> String {
        let t = (title ?? "").trimmingCharacters(in: .whitespaces)
        if let n = count, n > 0 { return "\(t): \(n)" }
        return t
    }

    // ── Настройки ────────────────────────────────────────────────────────

    private static func isDigits(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Наценка из ввода: "5,5" → "5.5", пусто → "0"; не число, больше 300 или больше 2 знаков — nil.
    static func markupForServer(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "")
        if t.isEmpty { return "0" }
        let norm = t.replacingOccurrences(of: ",", with: ".")
        let parts = norm.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, isDigits(parts[0]), parts[0].count <= 3 else { return nil }
        if parts.count == 2 { guard isDigits(parts[1]), parts[1].count <= 2 else { return nil } }
        guard let v = Decimal(string: norm), v <= 300 else { return nil }
        return "\(v)"
    }

    /// "5.50" → "5,5", "0.00" → "0": человеку без хвоста нулей и с запятой.
    static func markupShown(_ raw: String?) -> String {
        guard let r = raw?.trimmingCharacters(in: .whitespaces), let v = Decimal(string: r) else { return "0" }
        return "\(v)".replacingOccurrences(of: ".", with: ",")
    }

    static func draft(of c: FeedCard) -> FeedDraft {
        var d = FeedDraft()
        guard let o = c.options else { return d }
        d.onlyAvailable = o.onlyAvailable ?? false
        d.descFallback = o.descFallback ?? false
        d.markup = markupShown(o.markup)
        d.categories = Set(o.categories.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        d.utmSource = o.utm?.source ?? ""
        d.utmMedium = o.utm?.medium ?? ""
        d.utmCampaign = o.utm?.campaign ?? ""
        d.avitoCategory = o.avito?.category ?? ""
        d.avitoGoodsType = o.avito?.goodsType ?? ""
        d.avitoAdType = o.avito?.adType ?? ""
        d.avitoAddress = o.avito?.address ?? ""
        d.avitoPhone = o.avito?.phone ?? ""
        d.avitoManager = o.avito?.manager ?? ""
        d.googleBrand = o.google?.brand ?? ""
        d.googleProductCategory = o.google?.productCategory ?? ""
        return d
    }

    private static func utmOk(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.count > 60 { return false }
        return t.unicodeScalars.allSatisfy { ch in
            (ch.value < 128 && CharacterSet.alphanumerics.contains(ch)) || ch == "_" || ch == "." || ch == "-"
        }
    }

    /// Первая ошибка заполнения (тексты те же, что у сервера); nil — можно сохранять.
    static func validate(type: String, _ d: FeedDraft) -> String? {
        if markupForServer(d.markup) == nil { return markupError }
        if d.categories.count > categoriesMax { return categoriesMaxError }
        for (name, v) in [("source", d.utmSource), ("medium", d.utmMedium), ("campaign", d.utmCampaign)] {
            if !utmOk(v) { return "UTM-метка «\(name)»: латинские буквы, цифры, «_», «-», «.», до 60 знаков" }
        }
        var limits: [(String, String, Int)] = []
        if type == "avito" {
            limits = [("category", d.avitoCategory, 100), ("goods_type", d.avitoGoodsType, 100),
                      ("ad_type", d.avitoAdType, 100), ("address", d.avitoAddress, 250),
                      ("phone", d.avitoPhone, 30), ("manager", d.avitoManager, 80)]
        } else if type == "google_merchant" {
            limits = [("brand", d.googleBrand, 70), ("product_category", d.googleProductCategory, 250)]
        }
        for (name, v, max) in limits where v.trimmingCharacters(in: .whitespaces).count > max {
            return "Поле «\(name)» длиннее \(max) знаков"
        }
        return nil
    }

    /// Объект options для POST …/options. Очищенное поле шлём пустой строкой, а не nil: nil makeRequest
    /// выбросит из тела, и сервер оставил бы старое значение. Блоки avito / google — только своей площадке.
    static func optionsBody(type: String, _ d: FeedDraft) -> [String: Any] {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        var o: [String: Any] = [
            "only_available": d.onlyAvailable,
            "desc_fallback": d.descFallback,
            "markup": markupForServer(d.markup) ?? "0",
            "categories": d.categories.compactMap { Int($0) }.sorted(),
            "utm": ["source": t(d.utmSource), "medium": t(d.utmMedium), "campaign": t(d.utmCampaign)],
        ]
        if type == "avito" {
            o["avito"] = ["category": t(d.avitoCategory), "goods_type": t(d.avitoGoodsType),
                          "ad_type": t(d.avitoAdType), "address": t(d.avitoAddress),
                          "phone": t(d.avitoPhone), "manager": t(d.avitoManager)]
        }
        if type == "google_merchant" {
            o["google"] = ["brand": t(d.googleBrand), "product_category": t(d.googleProductCategory)]
        }
        return o
    }

    /// Текст для «Поделиться»: название площадки и ссылка.
    static func shareText(_ c: FeedCard) -> String? {
        guard let u = c.url?.trimmingCharacters(in: .whitespaces), !u.isEmpty else { return nil }
        let t = (c.title ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? u : "\(t): \(u)"
    }
}
