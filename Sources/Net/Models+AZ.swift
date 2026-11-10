import Foundation

// ============================================================================
//  АZ (сайт А617): модели ответов. Продавец декодирует БЕЗ convertFromSnakeCase —
//  имена полей только через CodingKeys. Всё необязательное: старый сервер этих
//  полей не шлёт, а «есть ключ / нет ключа» отличаем через container.contains.
// ============================================================================

// ── 1. Пауза приёма ─────────────────────────────────────────────────────────
/// GET /api/seller/settings → pause: {until, reason}. Сам факт ключа pause в
/// ответе = сервер умеет паузу на время (SettingsResponse.pause != nil).
struct ShopPauseInfo: Decodable {
    var until: String?
    var reason: String?
    /// ВВ (сайт А819): true — паузу поставил администратор площадки, продавец её не снимает.
    /// Ключа нет (старый сервер) — false.
    var admin = false
    /// П-68: тот же момент unix-секундами; nil — бессрочно / поля нет (старый сервер).
    var untilTs: Int?

    enum CodingKeys: String, CodingKey {
        case until, reason, admin
        case untilTs = "until_ts"
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        until = ((try? c.decodeIfPresent(LenientString.self, forKey: .until)) ?? nil)?.wrappedValue
        reason = ((try? c.decodeIfPresent(LenientString.self, forKey: .reason)) ?? nil)?.wrappedValue
        admin = ((try? c.decodeIfPresent(LenientBool.self, forKey: .admin)) ?? nil)?.wrappedValue ?? false
        untilTs = ((try? c.decodeIfPresent(LenientInt.self, forKey: .untilTs)) ?? nil)?.wrappedValue.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// POST /api/seller/settings/status → {status, pause_until, pause_reason}.
/// hasPauseUntil — ключ pause_until есть в ответе (даже null): старый сервер
/// его не шлёт, и тогда срок паузы не принят.
struct ShopStatusAck: Decodable {
    var status: String?
    var hasPauseUntil = false
    var pauseUntil: String?
    var pauseReason: String?
    /// П-68: pause_until_ts — тот же момент unix-секундами; nil — бессрочно / поля нет.
    var pauseUntilTs: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case pauseUntil = "pause_until"
        case pauseReason = "pause_reason"
        case pauseUntilTs = "pause_until_ts"
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        status = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil)
        hasPauseUntil = c.contains(.pauseUntil)
        pauseUntil = ((try? c.decodeIfPresent(LenientString.self, forKey: .pauseUntil)) ?? nil)?.wrappedValue
        pauseReason = ((try? c.decodeIfPresent(LenientString.self, forKey: .pauseReason)) ?? nil)?.wrappedValue
        pauseUntilTs = ((try? c.decodeIfPresent(LenientInt.self, forKey: .pauseUntilTs)) ?? nil)?.wrappedValue.flatMap { $0 > 0 ? $0 : nil }
    }
}

// ── 2. Разбор операций «Контроля потерь» ────────────────────────────────────
/// Отметка продавца у операции: status "ok" | "violation".
struct LossReview: Decodable {
    @LenientString var status: String?
    @LenientString var note: String?
    @LenientString var by: String?
    @LenientString var at: String?
}

/// POST /api/seller/loss-control/review → {key, count, review|null}.
struct LossReviewAck: Decodable {
    @LenientString var key: String?
    @LenientInt var count: Int?
}

// ── 3. Журнал записи на день ────────────────────────────────────────────────
/// GET /api/seller/slots/day?date=ГГГГ-ММ-ДД.
struct SlotDay: Decodable {
    var date: String?
    var columns: [SlotDayColumn] = []
    var slots: [SlotDaySlot] = []
    /// false — имена и телефоны клиентов скрыты (нет права «Заказы»). Нет ключа — true.
    var clientsVisible = true
    /// В ответе есть ключ columns (признак нового сервера для пробного запроса).
    var hasColumns = false

    enum CodingKeys: String, CodingKey {
        case date, columns, slots
        case clientsVisible = "clients_visible"
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        date = ((try? c.decodeIfPresent(LenientString.self, forKey: .date)) ?? nil)?.wrappedValue
        hasColumns = c.contains(.columns) && ((try? c.decodeNil(forKey: .columns)) ?? true) == false
        columns = (try? c.decode(SRList<SlotDayColumn>.self, forKey: .columns))?.wrappedValue ?? []
        slots = (try? c.decode(SRList<SlotDaySlot>.self, forKey: .slots))?.wrappedValue ?? []
        if let v = (try? c.decodeIfPresent(LenientBool.self, forKey: .clientsVisible)) ?? nil,
           let b = v.wrappedValue {
            clientsVisible = b
        }
    }
}

struct SlotDayColumn: Decodable, Identifiable {
    @LenientString var key: String?
    @LenientString var label: String?
    /// master | service
    @LenientString var kind: String?
    var id: String { key ?? "" }
}

struct SlotDaySlot: Decodable, Identifiable {
    @LenientInt var slotId: Int?
    @LenientString var col: String?
    @LenientInt var serviceId: Int?
    @LenientString var service: String?
    @LenientString var master: String?
    @LenientString var timeStart: String?
    @LenientString var timeEnd: String?
    @LenientInt var capacity: Int?
    @LenientInt var booked: Int?
    @LenientInt var free: Int?
    @LenientBool var isAvailable: Bool?
    @LenientBool var closedBySeller: Bool?
    @SRList var bookings: [SlotDayBooking]

    enum CodingKeys: String, CodingKey {
        case col, service, master, capacity, booked, free, bookings
        case slotId = "id"
        case serviceId = "service_id"
        case timeStart = "time_start"
        case timeEnd = "time_end"
        case isAvailable = "is_available"
        case closedBySeller = "closed_by_seller"
    }

    var id: Int { slotId ?? 0 }
}

struct SlotDayBooking: Decodable {
    @LenientInt var orderId: Int?
    @LenientInt var dailyNumber: Int?
    @LenientString var status: String?
    @LenientInt var guests: Int?
    @LenientString var client: String?
    @LenientString var phone: String?
    @LenientString var master: String?

    enum CodingKeys: String, CodingKey {
        case status, guests, client, phone, master
        case orderId = "order_id"
        case dailyNumber = "daily_number"
    }
}

// ── 4. Telegram одной кнопкой ───────────────────────────────────────────────
/// GET /api/seller/settings/telegram.
struct TelegramState: Decodable {
    /// В ответе есть ключ enabled — сервер знает «одну кнопку». Нет — нового блока нет.
    var known = false
    var enabled = false
    var bot: String?
    var connected = false
    var chatId: String?
    /// private | group | nil
    var chatKind: String?
    var canLink = false

    enum CodingKeys: String, CodingKey {
        case enabled, bot, connected
        case chatId = "chat_id"
        case chatKind = "chat_kind"
        case canLink = "can_link"
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        known = c.contains(.enabled)
        enabled = (((try? c.decodeIfPresent(LenientBool.self, forKey: .enabled)) ?? nil)?.wrappedValue) ?? false
        bot = ((try? c.decodeIfPresent(LenientString.self, forKey: .bot)) ?? nil)?.wrappedValue
        connected = (((try? c.decodeIfPresent(LenientBool.self, forKey: .connected)) ?? nil)?.wrappedValue) ?? false
        chatId = ((try? c.decodeIfPresent(LenientString.self, forKey: .chatId)) ?? nil)?.wrappedValue
        chatKind = ((try? c.decodeIfPresent(LenientString.self, forKey: .chatKind)) ?? nil)?.wrappedValue
        canLink = (((try? c.decodeIfPresent(LenientBool.self, forKey: .canLink)) ?? nil)?.wrappedValue) ?? false
    }
}

/// POST /api/seller/settings/telegram/link → {code, bot, url, group_url, ttl}.
struct TelegramLink: Decodable {
    @LenientString var code: String?
    @LenientString var bot: String?
    @LenientString var url: String?
    @LenientString var groupUrl: String?
    @LenientInt var ttl: Int?

    enum CodingKeys: String, CodingKey {
        case code, bot, url, ttl
        case groupUrl = "group_url"
    }
}
