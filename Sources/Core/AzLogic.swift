import Foundation

// ============================================================================
//  АZ (сайт А617): чистая логика этапа — подписи и расчёты без сети и экранов.
//   1. пауза приёма на время (POST /settings/status: pause_minutes / until=close)
//   2. разбор операций «Контроля потерь» (POST /loss-control/review)
//   3. журнал записи на день (GET /slots/day)
//   4. Telegram одной кнопкой (GET /settings/telegram, POST …/link)
//  Тексты — дословно из ТЗ этапа, они же на Android (core/AzLogic.kt).
//  Время сервера — МСК, строка «ГГГГ-ММ-ДД ЧЧ:ММ:СС».
// ============================================================================

/// Срок и причина паузы, которые уходят в POST /api/seller/settings/status.
struct ShopPauseRequest {
    /// 20 / 40 / 60 → pause_minutes. nil — без минут.
    var minutes: Int?
    /// «До конца смены» → until = "close".
    var untilClose = false
    /// Причина как ввели; в тело попадает, только если после trim не пусто.
    var reason = ""

    /// Выбран ли срок (иначе пауза бессрочная).
    var hasTerm: Bool { minutes != nil || untilClose }

    /// Поля тела запроса (без "status").
    var fields: [String: Any] {
        var out: [String: Any] = [:]
        if untilClose { out["until"] = "close" }
        else if let m = minutes { out["pause_minutes"] = m }
        let r = Az.cleanReason(reason)
        if !r.isEmpty { out["reason"] = r }
        return out
    }
}

/// Варианты окна «Пауза приёма заказов» (один выбран).
enum PauseChoice: CaseIterable, Identifiable {
    case min20, min40, hour1, untilClose, indefinite

    var id: Int { index }
    private var index: Int {
        switch self {
        case .min20: return 0
        case .min40: return 1
        case .hour1: return 2
        case .untilClose: return 3
        case .indefinite: return 4
        }
    }

    var title: String {
        switch self {
        case .min20: return "20 мин"
        case .min40: return "40 мин"
        case .hour1: return "1 час"
        case .untilClose: return "До конца смены"
        case .indefinite: return "Без срока"
        }
    }

    func request(reason: String) -> ShopPauseRequest {
        switch self {
        case .min20: return ShopPauseRequest(minutes: 20, untilClose: false, reason: reason)
        case .min40: return ShopPauseRequest(minutes: 40, untilClose: false, reason: reason)
        case .hour1: return ShopPauseRequest(minutes: 60, untilClose: false, reason: reason)
        case .untilClose: return ShopPauseRequest(minutes: nil, untilClose: true, reason: reason)
        case .indefinite: return ShopPauseRequest(minutes: nil, untilClose: false, reason: reason)
        }
    }

    /// Подсказка под полем причины.
    var hint: String {
        self == .indefinite
            ? "Приём не включится сам — снимите паузу, когда будете готовы."
            : "Приём включится сам по окончании срока."
    }
}

enum Az {
    // ── Время МСК ────────────────────────────────────────────────────────────
    private static let mskCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        return c
    }()
    private static func mskFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        f.dateFormat = format
        return f
    }
    private static let mskTime = mskFormatter("HH:mm")
    private static let mskDayTime = mskFormatter("dd.MM HH:mm")

    /// Сегодня по МСК — «ЧЧ:ММ», другой день — «ДД.ММ ЧЧ:ММ». Не разобрали строку — как пришла.
    static func untilText(_ s: String, now: Date = Date()) -> String {
        guard let d = DateFmt.parse(s) else { return s }
        return mskCal.isDate(d, inSameDayAs: now) ? mskTime.string(from: d) : mskDayTime.string(from: d)
    }

    /// П-68: подпись срока по until_ts (unix-секунды) в поясе ТЕЛЕФОНА: сегодня — «ЧЧ:ММ», иначе «ДД.ММ ЧЧ:ММ».
    static func untilText(ts: Int, now: Date = Date()) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(ts))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = cal.isDate(d, inSameDayAs: now) ? "HH:mm" : "dd.MM HH:mm"
        return f.string(from: d)
    }

    /// П-68: момент окончания паузы — until_ts главнее московской строки; нет обоих — nil.
    static func untilDate(_ s: String?, ts: Int?) -> Date? {
        if let ts, ts > 0 { return Date(timeIntervalSince1970: TimeInterval(ts)) }
        guard let s, !s.isEmpty else { return nil }
        return DateFmt.parse(s)
    }

    /// Срок ещё впереди (по until_ts, а без него — по московской строке).
    static func isUntilActive(_ s: String?, ts: Int?, now: Date = Date()) -> Bool {
        guard let d = untilDate(s, ts: ts) else { return false }
        return d > now
    }

    /// Всегда «ДД.ММ ЧЧ:ММ» по МСК (метка разбора операции).
    static func dayTime(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        guard let d = DateFmt.parse(s) else { return s }
        return mskDayTime.string(from: d)
    }

    // ── 1. Пауза ─────────────────────────────────────────────────────────────
    /// Причина: trim и не больше 120 знаков (как на сервере).
    static func cleanReason(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    /// Срок паузы, который ещё не прошёл (по МСК). Прошедший или не разобранный — nil:
    /// «На паузе до 14:00» в 14:05 вводит в заблуждение, пока крон не снял паузу.
    static func activeUntil(_ s: String?, now: Date = Date()) -> String? {
        guard let s, !s.isEmpty, let d = DateFmt.parse(s), d > now else { return nil }
        return s
    }

    /// Заголовок карточки статуса: «На паузе до ЧЧ:ММ» (или «до ДД.ММ ЧЧ:ММ»); nil — срока нет
    /// (или он уже прошёл).
    static func pauseTitle(until: String?, ts: Int? = nil) -> String? {
        if let ts, ts > 0 {
            guard isUntilActive(until, ts: ts) else { return nil }
            return "На паузе до " + untilText(ts: ts)
        }
        guard let u = activeUntil(until) else { return nil }
        return "На паузе до " + untilText(u)
    }

    /// Сообщение после успешной паузы.
    static func pausedMessage(until: String?, ts: Int? = nil) -> String {
        if let ts, ts > 0 { return "Приём заказов на паузе до " + untilText(ts: ts) }
        if let u = until, !u.isEmpty { return "Приём заказов на паузе до " + untilText(u) }
        return "Приём заказов на паузе"
    }

    static let pausedWithoutTerm =
        "Пауза поставлена без срока — сервер пока не умеет паузу на время. Снимите её вручную."
    static let resumedMessage = "Приём заказов включён"
    static let reasonChips = ["Много заказов", "Нет курьеров", "Технический сбой", "Закончились продукты"]

    // ── 2. Разбор операций ───────────────────────────────────────────────────
    /// Сколько ключей уходит в один запрос «Все показанные — норма».
    static let reviewBulkLimit = 300

    /// Первые ≤300 ключей операций из списка, которые ещё не разобраны (не владелец, key не пуст,
    /// review == nil) — как на сайте: у операций владельца разбора нет.
    static func bulkKeys(_ incidents: [LossIncident]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for inc in incidents where inc.review == nil && inc.owner != true {
            guard let k = inc.key, !k.isEmpty, seen.insert(k).inserted else { continue }
            out.append(k)
            if out.count >= reviewBulkLimit { break }
        }
        return out
    }

    /// Метка отметки: «Норма» / «Нарушение»; nil — отметки нет или статус неизвестен.
    static func reviewLabel(_ status: String?) -> String? {
        switch status {
        case "ok": return "Норма"
        case "violation": return "Нарушение"
        default: return nil
        }
    }

    /// «{by}, ДД.ММ ЧЧ:ММ»; by нет — только время.
    static func reviewMeta(by: String?, at: String?) -> String {
        let t = dayTime(at)
        let who = (by ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if who.isEmpty { return t }
        return t.isEmpty ? who : who + ", " + t
    }

    /// Сообщение после успешной отметки. status: "ok" | "violation" | "" (снять).
    static func reviewDoneMessage(status: String, bulk: Bool, count: Int?) -> String {
        if bulk { return "Отмечено нормой: \(count ?? 0)" }
        switch status {
        case "ok": return "Отмечено: норма"
        case "violation": return "Отмечено: нарушение"
        default: return "Отметка снята"
        }
    }

    /// Параметр review запроса: "" — все (параметра нет).
    static let reviewFilters: [(code: String, title: String)] = [
        ("", "Все"), ("open", "Не разобраны"), ("ok", "Норма"), ("violation", "Нарушения"),
    ]

    // ── 3. Журнал записи ─────────────────────────────────────────────────────
    static func slotRange(_ start: String?, _ end: String?) -> String {
        DateFmt.time(start) + "–" + DateFmt.time(end)
    }

    /// «Закрыто» / «Свободно» / «Свободно: N из M» / «Занято».
    static func slotState(closed: Bool, free: Int, capacity: Int) -> String {
        if closed { return "Закрыто" }
        if free > 0 { return capacity <= 1 ? "Свободно" : "Свободно: \(free) из \(capacity)" }
        return "Занято"
    }

    /// «№{daily_number ?: order_id} · {client ?: "Клиент"}» + « · N чел.» при guests > 1.
    static func bookingLine(orderId: Int, dailyNumber: Int?, client: String?, guests: Int) -> String {
        let num = (dailyNumber ?? 0) > 0 ? (dailyNumber ?? 0) : orderId
        let name = (client ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var s = "№\(num) · " + (name.isEmpty ? "Клиент" : name)
        if guests > 1 { s += " · \(guests) чел." }
        return s
    }

    // ── 4. Telegram ──────────────────────────────────────────────────────────
    /// Строка статуса подключения.
    static func telegramStatus(_ t: TelegramState) -> String {
        guard t.connected else { return "Telegram не подключён" }
        switch t.chatKind {
        case "private": return "Telegram подключён (личный чат)"
        case "group": return "Telegram подключён (группа)"
        default: return "Telegram подключён"
        }
    }
}
