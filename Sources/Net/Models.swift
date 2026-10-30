import Foundation

// ============================================================================
//  Models.swift — DTO, выведенные 1:1 из PHP-кода бэкенда (routes/*.php).
//  Имена полей — через CodingKeys, точно как кладёт Response::json.
//  Деньги/DECIMAL — только @LenientDecimal (сервер отдаёт строки "0.00").
//  Счётчики/id — @LenientInt, флаги 0/1 — @LenientBool.
// ============================================================================

// ── Auth (routes/auth_seller.php: $issuePanelSession) ────────────────────────
struct LoginResponse: Decodable {
    let user: SellerUser?
    let token: String
    let redirect: String?
    /// permissions == nil означает «владелец, можно всё».
    let permissions: [String: Bool]?
    /// Сервер отдаёт признак владельца ОТДЕЛЬНЫМ полем (routes/auth_seller.php).
    ///
    /// Читать его обязательно. Раньше «владелец» выводился из
    /// `permissions == nil`, а у сотрудника без роли или с ролью без единой
    /// галочки сервер шлёт пустой массив — в Swift это тот же nil. Сотрудник
    /// получал меню владельца: Кошелёк, Сотрудники, Настройки. И если ответ
    /// /api/seller/me не доходил, состояние «владелец» переживало перезапуск.
    let isOwner: Bool?
    let role: SellerRoleBrief?
    /// Сервер кладёт `employee`, если вход — сотрудника магазина (даже без роли).
    let hasEmployee: Bool

    enum CodingKeys: String, CodingKey { case user, token, redirect, permissions, isOwner = "is_owner", role, employee }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try? c.decodeIfPresent(SellerUser.self, forKey: .user)
        token = try c.decode(String.self, forKey: .token)
        redirect = try? c.decodeIfPresent(String.self, forKey: .redirect)
        // PHP json_encode пустого массива даёт [] — не роняем весь логин.
        if let map = try? c.decodeIfPresent([String: Bool].self, forKey: .permissions) {
            permissions = map
        } else if let map = try? c.decodeIfPresent([String: Int].self, forKey: .permissions) {
            permissions = map.mapValues { $0 != 0 }
        } else {
            permissions = nil
        }
        isOwner = try? c.decodeIfPresent(Bool.self, forKey: .isOwner)
        role = try? c.decodeIfPresent(SellerRoleBrief.self, forKey: .role)
        hasEmployee = c.contains(.employee)
    }
}

/// Роль сотрудника из ответа логина — нужна только для подписи в интерфейсе.
struct SellerRoleBrief: Decodable {
    let code: String?
    let name: String?
}

/// GET /api/shop/registration-status (auth_seller.php, Auth::checkRegistrationStatus):
/// status — pending | approved | rejected | none.
struct ShopRegistrationStatus: Decodable {
    let status: String?
    let adminNote: String?
    let shopName: String?
    /// Волна А75: организация создана сразу при регистрации, и есть ли она
    /// с панелью (её могли удалить или заблокировать). Старый сервер полей
    /// не шлёт — nil, вход как раньше. Разбор мягкий: чужой тип поля не роняет ответ.
    let autoApproved: Bool?
    let shopExists: Bool?
    let shopStatus: String?

    enum CodingKeys: String, CodingKey {
        case status
        case adminNote = "admin_note"
        case shopName = "shop_name"
        case autoApproved = "auto_approved"
        case shopExists = "shop_exists"
        case shopStatus = "shop_status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        adminNote = (try? c.decodeIfPresent(String.self, forKey: .adminNote)) ?? nil
        shopName = (try? c.decodeIfPresent(String.self, forKey: .shopName)) ?? nil
        autoApproved = (try? c.decodeIfPresent(Bool.self, forKey: .autoApproved)) ?? nil
        shopExists = (try? c.decodeIfPresent(Bool.self, forKey: .shopExists)) ?? nil
        shopStatus = (try? c.decodeIfPresent(String.self, forKey: .shopStatus)) ?? nil
    }
}

/// users.* без password_hash — берём только нужные приложению поля.
/// Ответ GET /api/seller/me — минимум для навигации плюс права роли.
/// permissions == nil означает «владелец, можно всё» (так же, как в логине).
struct MeResponse: Decodable {
    let user: SellerUser?
    let isOwner: Bool
    let permissions: [String: Bool]?
    let role: MeRole?
    let position: String?
    let shop: MeShop?
    let shopsCount: Int?
    /// Выключатели площадки. Поле аддитивное: старый сервер его не шлёт — тогда
    /// всё считается включённым и приложение ведёт себя как раньше.
    let features: MeFeatures?

    enum CodingKeys: String, CodingKey {
        case user, permissions, role, position, shop, features
        case isOwner = "is_owner"
        case shopsCount = "shops_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try? c.decodeIfPresent(SellerUser.self, forKey: .user)
        isOwner = (try? c.decodeIfPresent(Bool.self, forKey: .isOwner)) as? Bool ?? true
        // PHP отдаёт объект прав, но пустой массив кодируется как [] —
        // не роняем весь ответ из-за этого, как и в LoginResponse.
        if let map = try? c.decodeIfPresent([String: Bool].self, forKey: .permissions) {
            permissions = map
        } else if let map = try? c.decodeIfPresent([String: Int].self, forKey: .permissions) {
            permissions = map.mapValues { $0 != 0 }
        } else {
            permissions = nil
        }
        role = try? c.decodeIfPresent(MeRole.self, forKey: .role)
        position = try? c.decodeIfPresent(String.self, forKey: .position)
        shop = try? c.decodeIfPresent(MeShop.self, forKey: .shop)
        shopsCount = try? c.decodeIfPresent(Int.self, forKey: .shopsCount)
        features = try? c.decodeIfPresent(MeFeatures.self, forKey: .features)
    }
}

/// GET /api/seller/me → features. Что включено на маркетплейсе.
struct MeFeatures: Decodable {
    /// Тарифы (подписки) для продавцов. Выключены — раздела «Тариф» нет вовсе.
    let plans: Bool

    enum CodingKeys: String, CodingKey { case plans }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Толерантно: PHP отдаёт true/false, но может прийти 1/0 или "1"/"0".
        // Ключа может не быть вовсе (сервер старее приложения) — тогда включено.
        let asBool = (try? c.decodeIfPresent(Bool.self, forKey: .plans)) ?? nil
        let asInt = (try? c.decodeIfPresent(Int.self, forKey: .plans)) ?? nil
        let asStr = (try? c.decodeIfPresent(String.self, forKey: .plans)) ?? nil
        if let b = asBool { plans = b }
        else if let i = asInt { plans = i != 0 }
        else if let t = asStr { plans = (t != "0" && t != "") }
        else { plans = true }
    }
}

/// Роль в ответе /me. Отдельно от StaffRole (Models+Phase2) — там модель
/// экрана «Роли и права», с обязательной матрицей permissions.
struct MeRole: Decodable {
    @LenientInt var id: Int?
    let name: String?
    let code: String?
    let color: String?
}

struct MeShop: Decodable {
    @LenientInt var id: Int?
    let name: String?
    let slug: String?
    let logo: String?
    let type: String?      // shop | cafe | service — по нему строятся вкладки
    let mode: String?
    let status: String?
}

struct SellerUser: Decodable {
    @LenientInt var id: Int?
    var name: String?
    var email: String?
    var phone: String?
    var accountType: String?   // seller | kafe | service
    var status: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, phone, status
        case accountType = "account_type"
    }
}

// ── Мульти-магазин (GET /api/seller/shops) ───────────────────────────────────
struct ShopsResponse: Decodable {
    @LenientInt var activeId: Int?
    var shops: [ShopSummary]
    enum CodingKeys: String, CodingKey {
        case shops
        case activeId = "active_id"
    }
}

struct ShopSummary: Decodable, Identifiable, Hashable {
    @LenientInt var id: Int?
    var name: String?
    var logo: String?
    var mode: String?      // storefront | shop | restaurant
    var status: String?    // active | paused
    @LenientInt var cityId: Int?
    var city: String?
    @LenientInt var newOrders: Int?
    @LenientInt var pendingReturns: Int?
    /// П-27.13: тип точки (shop | cafe | service | lodging) и slug витрины.
    /// Старый сервер их не шлёт — nil, тип и адрес берутся из /me, как раньше.
    @LenientString var type: String?
    @LenientString var slug: String?

    enum CodingKeys: String, CodingKey {
        case id, name, logo, mode, status, city, type, slug
        case cityId = "city_id"
        case newOrders = "new_orders"
        case pendingReturns = "pending_returns"
    }
    var shopId: Int { id ?? 0 }
}

// ── Дашборд (GET /api/seller/dashboard) ──────────────────────────────────────
struct DashboardData: Decodable {
    var period: String?
    @LenientInt var orders: Int?
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var avgCheck: Decimal?
    var chart: [ChartPoint]?
    var active: [OrderSummary]?
    @LenientDecimal var wallet: Decimal?
    @LenientDecimal var pendingCommission: Decimal?
    @LenientInt var newReviews: Int?
    @LenientInt var newApplications: Int?
    @LenientInt var pendingReturns: Int?
    /// Какие блоки сотруднику ВИДНЫ. Закрытые правами блоки сервер отдаёт
    /// нулями (форма ответа одна для всех), и раньше кассир видел «Выручка 0 ₽»
    /// и КРАСНЫЙ «Кошелёк 0 ₽» как настоящие цифры — а нулевой кошелёк означает
    /// остановку приёма заказов. Старый сервер поля не шлёт → nil = показываем всё.
    /// Толерантно: если сервер отдаст не объект булей (пустой PHP-массив,
    /// 1/0 вместо true/false), дашборд не должен падать целиком.
    var blocks: [String: Bool]? {
        get { blocksRaw?.compactMapValues { $0.wrappedValue } }
    }
    var blocksRaw: [String: LenientBool]?
    /// АY (сайт А616): тот же отрезок прошлого периода; null — нет права «Аналитика»
    /// или старый сервер. Битый объект — nil, остальной дашборд живёт.
    @SRObject var prev: DashboardPrev?
    /// АY: «Требует внимания»; поле null — нет права на раздел (строку не показываем).
    @SRObject var attention: DashboardAttention?

    enum CodingKeys: String, CodingKey {
        case period, orders, revenue, chart, active, wallet, prev, attention
        case blocksRaw = "blocks"
        case avgCheck = "avg_check"
        case pendingCommission = "pending_commission"
        case newReviews = "new_reviews"
        case newApplications = "new_applications"
        case pendingReturns = "pending_returns"
    }
}

/// GET /api/seller/dashboard → prev (сайт А616).
struct DashboardPrev: Decodable {
    @LenientInt var orders: Int?
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var avgCheck: Decimal?
    var from: String?
    var to: String?
    enum CodingKeys: String, CodingKey {
        case orders, revenue, from, to
        case avgCheck = "avg_check"
    }
}

/// GET /api/seller/dashboard → attention (сайт А616). wallet_low — 1/0.
struct DashboardAttention: Decodable {
    @LenientInt var lateNew: Int?
    @LenientInt var stuck: Int?
    @LenientInt var preordersSoon: Int?
    @LenientInt var reviewsNoReply: Int?
    @LenientInt var walletLow: Int?
    enum CodingKeys: String, CodingKey {
        case stuck
        case lateNew = "late_new"
        case preordersSoon = "preorders_soon"
        case reviewsNoReply = "reviews_no_reply"
        case walletLow = "wallet_low"
    }
}

struct ChartPoint: Decodable, Identifiable {
    var d: String?
    @LenientInt var cnt: Int?
    @LenientDecimal var rev: Decimal?
    var id: String { d ?? UUID().uuidString }
}

// ── Заказы ───────────────────────────────────────────────────────────────────
struct OrdersPage: Decodable {
    var items: [OrderSummary]
    @LenientInt var page: Int?
    @LenientBool var hasMore: Bool?
    enum CodingKeys: String, CodingKey {
        case items, page
        case hasMore = "has_more"
    }
}

/**
 Блок брони жилья в заказе — аддитивное поле `lodging` в ответах
 /api/seller/orders и /api/seller/orders/{id}. nil (или отсутствует на старом
 сервере) = обычный заказ.

 Зачем в приложении: у заказа-брони статусы ведёт раздел «Брони» на сайте
 (Lodging::driveOrder), и сервер переходы отсюда отклоняет. Поэтому кнопки
 «Принять» и «Готовить» у такого заказа не показываем — вместо них подпись,
 что происходит с бронью.

 Декодер здесь без convertFromSnakeCase (см. API.swift), поэтому ключи
 перечислены в CodingKeys явно.
 */
struct LodgingOrderBlock: Decodable {
    @LenientInt var bookingId: Int?
    var status: String?
    var statusLabel: String?
    var dateFrom: String?
    var dateTo: String?
    @LenientInt var nights: Int?
    @LenientInt var rooms: Int?
    var unitTitle: String?

    enum CodingKeys: String, CodingKey {
        case status, nights, rooms
        case bookingId = "booking_id"
        case statusLabel = "status_label"
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case unitTitle = "unit_title"
    }

    var nightsValue: Int { max(0, nights ?? 0) }
    var roomsValue: Int { max(1, rooms ?? 1) }
    var statusText: String { (statusLabel?.isEmpty == false ? statusLabel! : (status ?? "")) }

    /// «10.11.2026 → 13.11.2026, 3 ночи» — как в разделе «Брони» на сайте.
    var datesText: String {
        let f = ruDate(dateFrom), t = ruDate(dateTo)
        let range: String
        if !f.isEmpty && !t.isEmpty { range = f + " → " + t }
        else if !f.isEmpty { range = f }
        else { range = t }
        let n = nightsValue
        let word: String
        if (11...14).contains(n % 100) { word = "ночей" }
        else if n % 10 == 1 { word = "ночь" }
        else if (2...4).contains(n % 10) { word = "ночи" }
        else { word = "ночей" }
        return range.isEmpty ? "\(n) \(word)" : "\(range), \(n) \(word)"
    }

    private func ruDate(_ iso: String?) -> String {
        guard let iso = iso, !iso.isEmpty else { return "" }
        let p = iso.split(separator: "-")
        return p.count == 3 ? "\(p[2]).\(p[1]).\(p[0])" : iso
    }
}

struct OrderSummary: Decodable, Identifiable {
    @LenientInt var id: Int?
    var status: String?
    @LenientDecimal var total: Decimal?
    var deliveryType: String?      // delivery | pickup
    var paymentType: String?       // cash | card_courier | sbp | online_card
    var paymentStatus: String?     // pending | paid
    var createdAt: String?
    @LenientInt var dailyNumber: Int?
    var comment: String?
    var client: String?
    var clientPhone: String?
    /// Предзаказ «к времени» (есть в ответе списка). Без него в ленте предзаказ
    /// на завтра выглядел как обычный заказ, и кухня начинала готовить сразу.
    var preorderAt: String?
    /// Аддитивно: заказ-бронь жилья. На старом сервере поля нет → nil.
    var lodging: LodgingOrderBlock?
    /// Текст клиента к записи (client_comment в списке заказов, seller.php).
    /// Старый сервер поля не шлёт → nil.
    @LenientString var clientComment: String?
    /// П-26.3: «сдача с …» (payment_note) — есть в строках dashboard.active и списка.
    /// П-26.7: подпись статуса словами от сервера (status_title).
    /// Старый сервер полей не шлёт → nil, подписи — как раньше.
    @LenientString var paymentNote: String?
    @LenientString var statusTitle: String?

    enum CodingKeys: String, CodingKey {
        case id, status, total, comment, client, lodging
        case clientComment = "client_comment"
        case paymentNote = "payment_note"
        case statusTitle = "status_title"
        case preorderAt = "preorder_at"
        case deliveryType = "delivery_type"
        case paymentType = "payment_type"
        case paymentStatus = "payment_status"
        case createdAt = "created_at"
        case dailyNumber = "daily_number"
        case clientPhone = "client_phone"
    }
    var orderId: Int { id ?? 0 }

    /// П-26.7: подпись статуса — сначала status_title сервера (он знает тип
    /// организации и способ получения), иначе прежний словарь приложения.
    /// Сервер для незнакомого кода отдаёт сам код — тогда тоже словарь приложения.
    var statusText: String {
        if let t = statusTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != status { return t }
        return OrderStatuses.label(status)
    }
}

/// GET /api/seller/orders/{id} — orders.* + client + items + log + address.
struct OrderDetail: Decodable {
    @LenientInt var id: Int?
    var status: String?
    var deliveryType: String?
    var paymentType: String?
    var paymentStatus: String?
    var paymentNote: String?
    @LenientDecimal var subtotal: Decimal?
    @LenientDecimal var deliveryPrice: Decimal?
    @LenientDecimal var serviceFee: Decimal?
    @LenientDecimal var discount: Decimal?
    /// Баллы и чаевые входят в формулу итога на сервере
    /// (total = товары + доставка + сбор + чаевые − скидка − баллы), но в
    /// карточке их не показывали: заказ на 1000 ₽, из которых 500 оплачены
    /// баллами, выглядел как «Товары 1000 · Итого 500» — продавец видел
    /// расхождение в 500 ₽ и считал, что площадка недоплатила.
    @LenientDecimal var pointsSpent: Decimal?
    @LenientDecimal var tip: Decimal?
    @LenientDecimal var total: Decimal?
    var promoCode: String?
    var comment: String?
    /// А63: только текст клиента к записи на услугу (в comment он идёт хвостом
    /// « · Комментарий: …»). Старый сервер поля не шлёт → nil.
    @LenientString var clientComment: String?
    var cancelReason: String?
    var createdAt: String?
    var preorderAt: String?
    var tableNumber: String?
    @LenientInt var dailyNumber: Int?
    var client: String?
    var clientPhone: String?
    var address: OrderAddress?
    var items: [OrderItem]?
    var log: [StatusLogEntry]?
    /// Правка состава (аддитивно): ревизия, разрешение сервера и история правок.
    @LenientInt var rev: Int?
    @LenientBool var canEdit: Bool?
    var changes: [OrderChangeEntry]?
    /// Аддитивно: заказ-бронь жилья. На старом сервере поля нет → nil.
    var lodging: LodgingOrderBlock?
    /// А60/П-23.8: адрес одной строкой ("" — адреса нет) и детали
    /// {apartment, flat, intercom, entrance, floor} (строка или null).
    /// На старом сервере полей нет → nil, адрес — из address, как раньше.
    @LenientString var addressText: String?
    var addressDetails: OrderAddress?
    /// Назначенный курьер (orders.courier_id из SELECT o.*); 0/null — не назначен.
    @LenientInt var courierId: Int?
    /// П-26.7: подпись статуса и весь словарь статусов этого заказа от сервера
    /// (с учётом типа организации, самовывоза/зала и брони). Нет полей — пусто.
    @LenientString var statusTitle: String?
    @LenientStringMap var statusTitles: [String: String]
    /// А78 «Курьеры Yumurta» (аддитивно): последний вызов курьера площадки по
    /// заказу (null — не вызывали) и можно ли вызвать сейчас. Старый сервер
    /// полей не шлёт — nil/false, блока в карточке нет. Чужой тип pool_call
    /// карточку не роняет (PoolCallBox разбирает мягко).
    var poolCall: PoolCallBox?
    @LenientBool var poolCallAvailable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, status, subtotal, discount, total, comment, client, address, items, log, rev, changes, lodging, tip
        case poolCall = "pool_call"
        case poolCallAvailable = "pool_call_available"
        case statusTitle = "status_title"
        case statusTitles = "status_titles"
        case courierId = "courier_id"
        case addressText = "address_text"
        case addressDetails = "address_details"
        case clientComment = "client_comment"
        case pointsSpent = "points_spent"
        case canEdit = "can_edit"
        case deliveryType = "delivery_type"
        case paymentType = "payment_type"
        case paymentStatus = "payment_status"
        case paymentNote = "payment_note"
        case deliveryPrice = "delivery_price"
        case serviceFee = "service_fee"
        case promoCode = "promo_code"
        case cancelReason = "cancel_reason"
        case createdAt = "created_at"
        case preorderAt = "preorder_at"
        case tableNumber = "table_number"
        case dailyNumber = "daily_number"
        case clientPhone = "client_phone"
    }

    /// П-26.7: подпись любого статуса этого заказа — словарь сервера, иначе
    /// прежний словарь приложения. Сервер для незнакомого кода отдаёт сам код.
    func statusText(_ code: String?) -> String {
        let fromServer = code == status ? (statusTitle ?? statusTitles[code ?? ""]) : statusTitles[code ?? ""]
        if let t = fromServer?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != code { return t }
        return OrderStatuses.label(code)
    }

    /// А60/П-23.8: строка «Адрес» — address_text сервера, иначе прежний разбор address.
    var addressLine: String {
        if let t = addressText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return address?.display ?? ""
    }

    /// А60/П-23.8: квартира, подъезд, этаж, домофон — из address_details, а без
    /// него из address. Раньше подъезд/этаж/домофон в карточке не показывались вовсе.
    var addressExtras: String {
        func pick(_ a: String?, _ b: String?) -> String? {
            for v in [a, b] {
                if let s = v?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
            }
            return nil
        }
        let d = addressDetails, a = address
        let line = addressLine.lowercased()
        var parts: [String] = []
        // Квартира уже есть в строке адреса — не повторяем.
        if let f = pick(d?.flat, a?.flat),
           !line.contains("кв. \(f.lowercased())"), !line.contains("кв \(f.lowercased())") {
            parts.append("кв. \(f)")
        }
        if let e = pick(d?.entrance, a?.entrance) { parts.append("подъезд \(e)") }
        if let fl = pick(d?.floor, a?.floor) { parts.append("этаж \(fl)") }
        if let i = pick(d?.intercom, a?.intercom) { parts.append("домофон \(i)") }
        return parts.joined(separator: ", ")
    }
}

/// address_json заказа — состав зависит от чекаута, парсим толерантно.
struct OrderAddress: Decodable {
    var address: String?
    var city: String?
    var street: String?
    var house: String?
    var flat: String?
    var entrance: String?
    var floor: String?
    var intercom: String?
    var comment: String?
    @LenientDecimal var lat: Decimal?
    @LenientDecimal var lng: Decimal?

    enum CodingKeys: String, CodingKey {
        case address, city, street, house, flat, entrance, floor, intercom, comment, lat, lng
        case apartment   // А60/П-23.8: в address_details квартира — apartment (= flat)
    }

    /// address_json заполняет клиентское приложение — типы полей не гарантированы
    /// (номер дома может прийти числом). Парсим каждое поле толерантно, не роняя заказ.
    init(from decoder: Decoder) throws {
        _lat = LenientDecimal(wrappedValue: nil)
        _lng = LenientDecimal(wrappedValue: nil)
        // Справка: address — «строка или null». Готовая строка адреса раньше
        // давала пустой объект, и в карточке заказа строки «Адрес» не было.
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            if let one = try? decoder.singleValueContainer(), let s = try? one.decode(String.self) {
                address = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return
        }
        func str(_ key: CodingKeys) -> String? {
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
            if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return String(i) }
            if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return String(d) }
            return nil
        }
        address = str(.address); city = str(.city); street = str(.street)
        house = str(.house); flat = str(.flat) ?? str(.apartment); entrance = str(.entrance)
        floor = str(.floor); intercom = str(.intercom); comment = str(.comment)
        if let l = try? c.decode(LenientDecimal.self, forKey: .lat) { _lat = l }
        if let l = try? c.decode(LenientDecimal.self, forKey: .lng) { _lng = l }
    }

    var display: String {
        if let a = address, !a.isEmpty { return a }
        let parts = [city, street, house.map { "д. \($0)" }, flat.map { "кв. \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }
}

// ── Правки состава заказа (аддитивно) ───────────────────────────────────────
// Клиент заказал 1 кг помидоров, в магазине оказалось 700 г. Сервер хранит
// историю правок; продавец видит её здесь, а клиент — у себя в заказе.
struct OrderChangeLine: Decodable, Identifiable {
    var op: String?                 // qty | remove
    @LenientInt var itemId: Int?
    var name: String?
    var unit: String?
    @LenientDecimal var qtyBefore: Decimal?
    @LenientDecimal var qtyAfter: Decimal?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var sumBefore: Decimal?
    @LenientDecimal var sumAfter: Decimal?

    enum CodingKeys: String, CodingKey {
        case op, name, unit, price
        case itemId = "item_id"
        case qtyBefore = "qty_before"
        case qtyAfter = "qty_after"
        case sumBefore = "sum_before"
        case sumAfter = "sum_after"
    }
    var id: String { "\(itemId ?? 0)|\(name ?? "")|\(qtyAfter ?? 0)" }
}

struct OrderChangeEntry: Decodable, Identifiable {
    @LenientInt var rev: Int?
    var at: String?
    var actorType: String?          // pos | seller | system
    var actor: String?
    var reason: String?
    @LenientDecimal var totalBefore: Decimal?
    @LenientDecimal var totalAfter: Decimal?
    var lines: [OrderChangeLine]?
    var text: String?

    enum CodingKeys: String, CodingKey {
        case rev, at, actor, reason, lines, text
        case actorType = "actor_type"
        case totalBefore = "total_before"
        case totalAfter = "total_after"
    }
    var id: Int { rev ?? 0 }
}

/// Ответ POST api/seller/orders/{id}/items — актуальные суммы и состав.
struct OrderEditResult: Decodable {
    @LenientInt var id: Int?
    @LenientInt var rev: Int?
    @LenientDecimal var subtotal: Decimal?
    @LenientDecimal var discount: Decimal?
    @LenientDecimal var deliveryPrice: Decimal?
    @LenientDecimal var serviceFee: Decimal?
    @LenientDecimal var total: Decimal?
    var items: [OrderItem]?
    var change: OrderChangeEntry?
    @LenientBool var paidWarning: Bool?

    enum CodingKeys: String, CodingKey {
        case id, rev, subtotal, discount, total, items, change
        case deliveryPrice = "delivery_price"
        case serviceFee = "service_fee"
        case paidWarning = "paid_warning"
    }
}

struct OrderItem: Decodable, Identifiable {
    /// order_items.id — настоящий ключ строки. Появился вместе с правкой состава
    /// заказа (миграция 2026_09_order_edit.sql). До него id приходилось собирать
    /// из имени и количества, из-за чего смена количества выглядела для SwiftUI
    /// как удаление строки и вставка новой (в поле ввода терялся фокус).
    @LenientInt var lineId: Int?
    @LenientInt var productId: Int?
    var name: String?
    var unit: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var qty: Decimal?
    /// Сколько заказывал КЛИЕНТ. Отличается от qty, если состав правили.
    @LenientDecimal var qtyOrdered: Decimal?
    var modifiersJson: String?

    enum CodingKeys: String, CodingKey {
        case name, price, qty, unit
        case lineId = "id"
        case productId = "product_id"
        case qtyOrdered = "qty_ordered"
        case modifiersJson = "modifiers_json"
    }
    var id: String { lineId.map(String.init) ?? ((name ?? "") + (modifiersJson ?? "") + "\(qty ?? 0)") }

    /// Количество отличается от заказанного — позицию правили.
    var quantityChanged: Bool {
        guard let was = qtyOrdered, let now = qty, was > 0 else { return false }
        return was != now
    }

    /// modifiers_json: JSON-массив объектов минимум с "name" (+опц. "price"). Парсим толерантно.
    var modifiers: [(name: String, price: Decimal?)] {
        guard let raw = modifiersJson, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let n = obj["name"] as? String else { return nil }
            var p: Decimal?
            if let s = obj["price"] as? String { p = Decimal(string: s) }
            else if let d = obj["price"] as? Double { p = Decimal(d) }
            else if let i = obj["price"] as? Int { p = Decimal(i) }
            return (n, p)
        }
    }
}

struct StatusLogEntry: Decodable, Identifiable {
    var status: String?
    var comment: String?
    var createdAt: String?
    enum CodingKeys: String, CodingKey {
        case status, comment
        case createdAt = "created_at"
    }
    var id: String { (status ?? "") + (createdAt ?? "") }
}

// ── Чат заказа (GET/POST /api/seller/orders/{id}/chat) ───────────────────────
struct ChatMessage: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var senderId: Int?
    var message: String?
    /// Фото клиента в чате (относительный путь). Клиентские приложения шлют
    /// фото без подписи — раньше продавец видел пустой пузырь с одним временем.
    var attachment: String?
    var createdAt: String?
    @LenientBool var mine: Bool?
    enum CodingKeys: String, CodingKey {
        case id, message, mine, attachment
        case senderId = "sender_id"
        case createdAt = "created_at"
    }
    var messageId: Int { id ?? 0 }
}

// ── Товары ───────────────────────────────────────────────────────────────────
struct ProductsPage: Decodable {
    var items: [ProductSummary]
    @LenientInt var page: Int?
    @LenientBool var hasMore: Bool?
    /// АY (сайт А616): у позиций есть stop_until или category_id — сервер знает
    /// фильтры avail/stopped/nophoto/nocat/lowstock и sort/dir. Старый сервер — false.
    var knowsFilters = false
    enum CodingKeys: String, CodingKey {
        case items, page
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decode([ProductSummary].self, forKey: .items)
        _page = try c.decode(LenientInt.self, forKey: .page)
        _hasMore = try c.decode(LenientBool.self, forKey: .hasMore)
        let probe = (try? c.decode([ProductNewFieldsProbe].self, forKey: .items)) ?? []
        knowsFilters = probe.contains { $0.present }
    }
}

/// Есть ли у строки товара поля сайта А616 (ключ есть, значение может быть null).
private struct ProductNewFieldsProbe: Decodable {
    let present: Bool
    enum CodingKeys: String, CodingKey {
        case stopUntil = "stop_until"
        case categoryId = "category_id"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        present = c.contains(.stopUntil) || c.contains(.categoryId)
    }
}

struct ProductSummary: Decodable, Identifiable {
    @LenientInt var id: Int?
    var name: String?
    var article: String?
    var barcode: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var priceOld: Decimal?
    var type: String?              // product | dish | service
    @LenientBool var isAvailable: Bool?
    var status: String?            // active | hidden
    var category: String?
    var photo: String?
    @LenientBool var stopped: Bool?
    // АY (сайт А616): необязательные поля; у старого сервера их нет — nil.
    @LenientInt var categoryId: Int?
    @LenientDouble var stockQty: Double?
    @LenientDouble var stockMin: Double?
    var unit: String?
    /// Стоп до (время сервера, «Y-m-d H:i:s»); null при stopped — бессрочно.
    var stopUntil: String?

    enum CodingKeys: String, CodingKey {
        case id, name, article, barcode, price, type, status, category, photo, stopped, unit
        case priceOld = "price_old"
        case isAvailable = "is_available"
        case categoryId = "category_id"
        case stockQty = "stock_qty"
        case stockMin = "stock_min"
        case stopUntil = "stop_until"
    }
    var productId: Int { id ?? 0 }
}

/// GET /api/seller/products/{id} — products.* + photos + tags + allergens.
struct ProductDetail: Decodable {
    @LenientInt var id: Int?
    @LenientInt var categoryId: Int?
    var name: String?
    var description: String?
    var type: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var priceOld: Decimal?
    var unit: String?
    @LenientDecimal var weight: Decimal?
    var article: String?
    var barcode: String?
    @LenientDecimal var calories: Decimal?
    @LenientDecimal var proteins: Decimal?
    @LenientDecimal var fats: Decimal?
    @LenientDecimal var carbs: Decimal?
    var status: String?
    @LenientBool var isAvailable: Bool?
    /// Маркированный товар (Честный ЗНАК). Касса по этому признаку требует скан
    /// DataMatrix перед добавлением в чек и передаёт код в ОФД.
    @LenientBool var isMarked: Bool?
    @LenientInt var qtyFractional: Int?
    @LenientDecimal var qtyStep: Decimal?
    var qtyPresets: String?
    var photos: [ProductPhoto]?
    // Сервер отдаёт теги как сохранил: строка или объект вместо массива
    // роняли всю карточку товара. Разбираем без потери тегов.
    @LenientTagList var tags: [String]?
    @LenientTagList var allergens: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, type, price, unit, weight, article, barcode
        case calories, proteins, fats, carbs, status, photos, tags, allergens
        case categoryId = "category_id"
        case priceOld = "price_old"
        case isAvailable = "is_available"
        case isMarked = "is_marked"
        case qtyFractional = "qty_fractional"
        case qtyStep = "qty_step"
        case qtyPresets = "qty_presets"
    }
}

struct ProductPhoto: Decodable, Identifiable {
    @LenientInt var id: Int?
    var pathWebp: String?
    @LenientInt var sortOrder: Int?
    enum CodingKeys: String, CodingKey {
        case id
        case pathWebp = "path_webp"
        case sortOrder = "sort_order"
    }
    var photoId: Int { id ?? 0 }
}

struct SellerCategory: Decodable, Identifiable, Hashable {
    @LenientInt var id: Int?
    @LenientInt var parentId: Int?
    var name: String?
    var slug: String?
    var image: String?
    @LenientBool var isActive: Bool?
    @LenientInt var sortOrder: Int?
    var stationRoute: String?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, image
        case parentId = "parent_id"
        case isActive = "is_active"
        case sortOrder = "sort_order"
        case stationRoute = "station_route"
    }
    var categoryId: Int { id ?? 0 }
}

/// POST /api/seller/products/{id}/ai-description
struct AIDescription: Decodable {
    var description: String?
    @LenientInt var usedToday: Int?
    @LenientInt var limit: Int?
    enum CodingKeys: String, CodingKey {
        case description, limit
        case usedToday = "used_today"
    }
}

struct PhotoUploadResult: Decodable {
    @LenientInt var id: Int?
    var pathWebp: String?
    enum CodingKeys: String, CodingKey {
        case id
        case pathWebp = "path_webp"
    }
}

// ── Стоп-лист ────────────────────────────────────────────────────────────────
struct StopListItem: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var productId: Int?
    @LenientInt var modifierId: Int?
    var reason: String?
    var createdAt: String?
    var productName: String?
    var modifierName: String?
    var until: String?
    var byName: String?
    /// АY (сайт А616): сколько секунд осталось по часам СЕРВЕРА; null — без срока.
    @LenientInt var untilInSec: Int?

    enum CodingKeys: String, CodingKey {
        case id, reason, until
        case productId = "product_id"
        case modifierId = "modifier_id"
        case createdAt = "created_at"
        case productName = "product_name"
        case modifierName = "modifier_name"
        case byName = "by_name"
        case untilInSec = "until_in_sec"
    }
    var itemId: Int { id ?? 0 }
}

/// GET /api/seller/stop-list: список + признак сайта А616 (ключ until_in_sec у строк —
/// сервер знает и until_close в POST). Пустой список признака не даёт.
struct StopListPayload: Decodable {
    var items: [StopListItem]
    var knowsUntilClose = false
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        items = try c.decode([StopListItem].self)
        let probe = (try? c.decode([StopListNewFieldsProbe].self)) ?? []
        knowsUntilClose = probe.contains { $0.present }
    }
}

private struct StopListNewFieldsProbe: Decodable {
    let present: Bool
    enum CodingKeys: String, CodingKey { case untilInSec = "until_in_sec" }
    init(from decoder: Decoder) throws {
        present = try decoder.container(keyedBy: CodingKeys.self).contains(.untilInSec)
    }
}

// ── Модификаторы (GET /api/seller/products/{id}/modifiers) ───────────────────
struct ModifierGroup: Decodable, Identifiable {
    @LenientInt var id: Int?
    var name: String?
    var type: String?              // single | multiple
    @LenientBool var isRequired: Bool?
    @LenientInt var minQty: Int?
    @LenientInt var maxQty: Int?
    var options: [ModifierOption]?

    enum CodingKeys: String, CodingKey {
        case id, name, type, options
        case isRequired = "is_required"
        case minQty = "min_qty"
        case maxQty = "max_qty"
    }
    var groupId: Int { id ?? 0 }
}

struct ModifierOption: Decodable, Identifiable {
    @LenientInt var id: Int?
    var name: String?
    @LenientDecimal var price: Decimal?
    var photoWebp: String?
    @LenientBool var isAvailable: Bool?
    var article: String?
    var barcode: String?

    enum CodingKeys: String, CodingKey {
        case id, name, price, article, barcode
        case photoWebp = "photo_webp"
        case isAvailable = "is_available"
    }
    var optionId: Int { id ?? 0 }
}

// ── Услуги / мастера / слоты / записи (routes/seller_services.php) ──────────
struct Master: Decodable, Identifiable {
    @LenientInt var id: Int?
    var name: String?
    var photoWebp: String?
    var bio: String?
    @LenientDecimal var rating: Decimal?
    var specializationsJson: String?

    enum CodingKeys: String, CodingKey {
        case id, name, bio, rating
        case photoWebp = "photo_webp"
        case specializationsJson = "specializations_json"
    }
    var masterId: Int { id ?? 0 }
    var specializations: [String] {
        guard let raw = specializationsJson, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }
}

struct ServiceItem: Decodable, Identifiable {
    @LenientInt var id: Int?
    var name: String?
    var description: String?
    @LenientInt var durationMin: Int?
    @LenientInt var bufferMin: Int?
    @LenientDecimal var price: Decimal?
    @LenientBool var isActive: Bool?
    @LenientInt var masterId: Int?
    var master: String?
    // Категория услуги — та же, в которой лежат товары. Порядок категории
    // задаёт, где стоит услуга в списке у клиента и на сайте. Поля аддитивные:
    // у старого сервера их нет → nil, поведение прежнее.
    @LenientInt var categoryId: Int?
    var categoryName: String?
    @LenientInt var sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, description, price, master
        case durationMin = "duration_min"
        case bufferMin = "buffer_min"
        case isActive = "is_active"
        case masterId = "master_id"
        case categoryId = "category_id"
        case categoryName = "category_name"
        case sortOrder = "sort_order"
    }
    var serviceId: Int { id ?? 0 }
}

struct ServiceSlot: Decodable, Identifiable {
    @LenientInt var id: Int?
    var date: String?
    var timeStart: String?
    var timeEnd: String?
    @LenientBool var isAvailable: Bool?
    @LenientInt var orderId: Int?

    enum CodingKeys: String, CodingKey {
        case id, date
        case timeStart = "time_start"
        case timeEnd = "time_end"
        case isAvailable = "is_available"
        case orderId = "order_id"
    }
    var slotId: Int { id ?? 0 }
}

struct Booking: Decodable, Identifiable {
    @LenientInt var slotId: Int?
    var date: String?
    var timeStart: String?
    var timeEnd: String?
    @LenientInt var orderId: Int?
    var service: String?
    @LenientDecimal var price: Decimal?
    var master: String?
    var status: String?
    @LenientDecimal var total: Decimal?
    @LenientInt var dailyNumber: Int?
    var client: String?
    var phone: String?
    var comment: String?
    /// А63: комментарий клиента мастеру (string|null). Старый сервер не шлёт → nil.
    @LenientString var clientComment: String?
    /// Сколько ГОСТЕЙ придёт, вместимость окна и сколько окон склеено.
    /// Сервер отдаёт их специально (у окна игрового зала на 8 человек броней
    /// несколько), а приложение не показывало: бронь на 6 человек выглядела
    /// одной строкой, и продавец готовил место на одного.
    @LenientInt var guests: Int?
    @LenientInt var capacity: Int?
    @LenientInt var slots: Int?

    enum CodingKeys: String, CodingKey {
        case date, service, price, master, status, total, client, phone, comment, guests, capacity, slots
        case slotId = "slot_id"
        case timeStart = "time_start"
        case timeEnd = "time_end"
        case orderId = "order_id"
        case dailyNumber = "daily_number"
        case clientComment = "client_comment"
    }
    // Один слот могут занять несколько заказов (и у записи без слота slot_id = nil):
    // ключ только по slotId давал дубли id в ForEach — строки путались/пропадали.
    var id: String { "\(orderId ?? 0)_\(slotId ?? 0)_\(date ?? "")_\(timeStart ?? "")" }
}

// ── Кошелёк (routes/seller_settings.php) ─────────────────────────────────────
struct WalletData: Decodable {
    @LenientDecimal var balance: Decimal?
    var transactions: [WalletTransaction]?
    var pending: [PendingTopup]?
    var plan: WalletPlan?
    @LenientBool var low: Bool?
    /// Приём заказов с сайта и приложений остановлен из-за долга по кошельку.
    /// Касса и киоск продолжают работать. Порог — настройка площадки.
    @LenientBool var ordersBlocked: Bool?
    @LenientDecimal var blockBelow: Decimal?
    /// П-27.10: пределы одного пополнения из настроек площадки. min_topup нет
    /// (старый сервер) — прежние 100 ₽; max_topup null — верхней границы нет.
    @LenientDecimal var minTopup: Decimal?
    @LenientDecimal var maxTopup: Decimal?
    /// АY (сайт А616): есть ли строки выписки дальше (before_id). nil — старый сервер.
    @LenientBool var txHasMore: Bool?
    /// АY: подписи типов операций {код: подпись} — чипы фильтра ?type=. nil — старый сервер.
    var typeLabels: [String: String]?
    /// АY: средний дневной расход за 30 дней; null — списаний не было.
    @LenientDecimal var avgDailyDebit30d: Decimal?
    /// АY: сервер знает ?type=&from=&to=&before_id= (в ответе tx_has_more или type_labels).
    var knowsTxFilters = false

    enum CodingKeys: String, CodingKey {
        case balance, transactions, pending, plan, low
        case ordersBlocked = "orders_blocked"
        case blockBelow = "block_below"
        case minTopup = "min_topup"
        case maxTopup = "max_topup"
        case txHasMore = "tx_has_more"
        case typeLabels = "type_labels"
        case avgDailyDebit30d = "avg_daily_debit_30d"
    }

    /// Минимум пополнения: с сервера, иначе 100 ₽.
    var minTopupValue: Decimal {
        if let m = minTopup, m > 0 { return m }
        return 100
    }

    /// Максимум пополнения (nil — без ограничения).
    var maxTopupValue: Decimal? {
        if let m = maxTopup, m > 0 { return m }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _balance = try c.decode(LenientDecimal.self, forKey: .balance)
        transactions = (try? c.decodeIfPresent([WalletTransaction].self, forKey: .transactions)) ?? []
        pending = (try? c.decodeIfPresent([PendingTopup].self, forKey: .pending)) ?? []
        // PHP DB::fetch() отдаёт false (не null), если тариф не найден — не роняем весь кошелёк.
        plan = try? c.decodeIfPresent(WalletPlan.self, forKey: .plan)
        _low = try c.decode(LenientBool.self, forKey: .low)
        // Аддитивные поля: на старом сервере их нет — блокировки нет.
        _ordersBlocked = (try? c.decode(LenientBool.self, forKey: .ordersBlocked)) ?? LenientBool(wrappedValue: false)
        _blockBelow = (try? c.decode(LenientDecimal.self, forKey: .blockBelow)) ?? LenientDecimal(wrappedValue: nil)
        _minTopup = (try? c.decode(LenientDecimal.self, forKey: .minTopup)) ?? LenientDecimal(wrappedValue: nil)
        _maxTopup = (try? c.decode(LenientDecimal.self, forKey: .maxTopup)) ?? LenientDecimal(wrappedValue: nil)
        _txHasMore = (try? c.decode(LenientBool.self, forKey: .txHasMore)) ?? LenientBool(wrappedValue: nil)
        _avgDailyDebit30d = (try? c.decode(LenientDecimal.self, forKey: .avgDailyDebit30d)) ?? LenientDecimal(wrappedValue: nil)
        let labels = (try? c.decodeIfPresent(LenientStringMap.self, forKey: .typeLabels))?.wrappedValue
        typeLabels = (labels?.isEmpty ?? true) ? nil : labels
        knowsTxFilters = c.contains(.txHasMore) || typeLabels != nil
    }
}

struct WalletTransaction: Decodable, Identifiable {
    var type: String?      // topup / commission / service_fee_* / subscription / promo
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var balanceAfter: Decimal?
    var description: String?
    var createdAt: String?
    /// АY (сайт А616): id строки (для before_id) и заказ операции. Старый сервер — nil.
    @LenientInt var txId: Int?
    @LenientInt var orderId: Int?

    enum CodingKeys: String, CodingKey {
        case type, amount, description
        case balanceAfter = "balance_after"
        case createdAt = "created_at"
        case txId = "id"
        case orderId = "order_id"
    }
    var id: String {
        if let t = txId { return "tx\(t)" }
        return (createdAt ?? "") + (type ?? "") + "\(amount ?? 0)" + (description ?? "")
    }
}

struct PendingTopup: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientDecimal var amount: Decimal?
    var method: String?
    var status: String?
    var createdAt: String?
    enum CodingKeys: String, CodingKey {
        case id, amount, method, status
        case createdAt = "created_at"
    }
    var topupId: Int { id ?? 0 }
}

struct WalletPlan: Decodable {
    var name: String?
    @LenientDecimal var priceMonthly: Decimal?
    @LenientInt var maxProducts: Int?
    enum CodingKeys: String, CodingKey {
        case name
        case priceMonthly = "price_monthly"
        case maxProducts = "max_products"
    }
}

/// POST /api/seller/wallet/topup.
///   bank_transfer     → {status:"pending",  topup_id, requisites}
///   card_online / sbp → {status:"redirect", topup_id, amount, confirmation_url}
///
/// confirmation_url — страница оплаты ЮKassa. Деньги зачисляются ТОЛЬКО после
/// подтверждения платежа провайдером, поэтому после возврата приложение
/// опрашивает walletTopupStatus.
///
/// status:"confirmed" оставлен: пока новые файлы не выложены на сервер, старая
/// сборка отвечает по-прежнему, и экран не должен из-за этого ломаться.
struct TopupResponse: Decodable {
    var status: String?
    @LenientInt var topupId: Int?
    var requisites: TopupRequisites?
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var balance: Decimal?
    var paymentUrl: String?
    var confirmationUrl: String?

    enum CodingKeys: String, CodingKey {
        case status, requisites, amount, balance
        case topupId = "topup_id"
        case paymentUrl = "payment_url"
        case confirmationUrl = "confirmation_url"
    }
    /// Ссылка на оплату, как бы сервер её ни назвал. confirmation_url — то, что
    /// присылает наш сервер; payment_url оставлен для терпимости.
    var payURL: URL? {
        if let s = confirmationUrl, !s.isEmpty, let u = URL(string: s) { return u }
        if let s = paymentUrl, !s.isEmpty, let u = URL(string: s) { return u }
        return nil
    }
}

/// GET /api/seller/wallet/topup/{id} — статус пополнения.
struct TopupStatusResponse: Decodable {
    @LenientInt var topupId: Int?
    var status: String?                 // pending | confirmed | rejected
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var balance: Decimal?

    enum CodingKeys: String, CodingKey {
        case status, amount, balance
        case topupId = "topup_id"
    }
}

struct TopupRequisites: Decodable {
    var inn: String?
    var account: String?
    var bik: String?
    var purpose: String?
}

// ── Возвраты (routes/seller.php) ─────────────────────────────────────────────
struct ReturnSummary: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var orderId: Int?
    var type: String?              // full | partial
    var reasonCode: String?
    var status: String?            // pending | approved | rejected | refunded | closed
    @LenientDecimal var refundAmount: Decimal?
    var refundMethod: String?      // bonus | manual
    var createdAt: String?
    var client: String?
    var clientPhone: String?
    /// А111: номер дня заказа (orders.daily_number), повторяется каждый день.
    /// У старого сервера поля нет — nil.
    @LenientInt var orderNumber: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, status, client
        case orderId = "order_id"
        case reasonCode = "reason_code"
        case refundAmount = "refund_amount"
        case refundMethod = "refund_method"
        case createdAt = "created_at"
        case clientPhone = "client_phone"
        case orderNumber = "order_number"
    }
    var returnId: Int { id ?? 0 }
}

/// Заказ возврата, как на сайте (А111): «№301 · #17914» — номер дня (его видит
/// покупатель) и id заказа. Без order_number (старый сервер) — как раньше, «№17914».
func returnOrderLabel(number: Int?, orderId: Int?) -> String {
    if let n = number, n > 0 { return "№\(n) · #\(orderId ?? 0)" }
    return "№\(orderId ?? 0)"
}

/// GET /api/seller/returns/{id} — returns.* + items/photos/log/order_items.
struct ReturnDetail: Decodable {
    @LenientInt var id: Int?
    @LenientInt var orderId: Int?
    var type: String?
    var reasonCode: String?
    var reasonText: String?
    var status: String?
    @LenientDecimal var refundAmount: Decimal?
    var refundMethod: String?
    var moderatorNote: String?
    var createdAt: String?
    var client: String?
    var clientPhone: String?
    // items_json бывает объектом {"unknown":true} (возврат через ЮKassa, касса):
    // строгий массив ронял весь возврат — он не открывался. Не массив — nil.
    @LenientReturnItems var items: [ReturnRequestItem]?
    @LenientStringArray var photos: [String]?
    var log: [StatusLogEntry]?
    var orderItems: [ReturnOrderItem]?
    @LenientInt var orderNumber: Int?   // А111, см. ReturnSummary

    enum CodingKeys: String, CodingKey {
        case id, type, status, client, items, photos, log
        case orderNumber = "order_number"
        case orderId = "order_id"
        case reasonCode = "reason_code"
        case reasonText = "reason_text"
        case refundAmount = "refund_amount"
        case refundMethod = "refund_method"
        case moderatorNote = "moderator_note"
        case createdAt = "created_at"
        case clientPhone = "client_phone"
        case orderItems = "order_items"
    }
}

struct ReturnRequestItem: Decodable, Identifiable {
    @LenientInt var itemId: Int?
    @LenientDecimal var qty: Decimal?
    var name: String?
    enum CodingKeys: String, CodingKey {
        case qty, name
        case itemId = "item_id"
    }
    var id: Int { itemId ?? 0 }
}

struct ReturnOrderItem: Decodable, Identifiable {
    @LenientInt var id: Int?
    var name: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var returnQty: Decimal?
    enum CodingKeys: String, CodingKey {
        case id, name, price, qty
        case returnQty = "return_qty"
    }
    var rowId: Int { id ?? 0 }
}

/// POST /api/seller/settings/main → {saved, cleared:[…]} (П-27.6). cleared нет
/// (старый сервер) — nil. Любой другой вид ответа не роняет сохранение.
struct SettingsMainAck: Decodable {
    let cleared: [String]?
    enum CodingKeys: String, CodingKey { case cleared }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        cleared = (try? c?.decodeIfPresent([String].self, forKey: .cleared)) ?? nil
    }
}

// ── Настройки (GET /api/seller/settings) — источник shops.type ──────────────
struct SettingsResponse: Decodable {
    var shop: ShopSettings?
    /// Блок notifications (telegram_chat_id + events) — модель в Models+Phase2.swift.
    var notifications: NotificationSettings?
}

struct ShopSettings: Decodable {
    var name: String?
    var description: String?
    var address: String?
    @LenientDecimal var lat: Decimal?
    @LenientDecimal var lng: Decimal?
    var phone: String?
    var email: String?
    var inn: String?
    var orgType: String?
    var type: String?              // shop | cafe | service — навигация приложения
    @LenientInt var cityId: Int?
    var logo: String?
    var banner: String?
    var mode: String?
    var status: String?            // active | paused
    @LenientDecimal var serviceFeePercent: Decimal?
    var serviceFeePayer: String?
    @LenientInt var returnWindowHours: Int?

    enum CodingKeys: String, CodingKey {
        case name, description, address, lat, lng, phone, email, inn, type, logo, banner, mode, status
        case orgType = "org_type"
        case cityId = "city_id"
        case serviceFeePercent = "service_fee_percent"
        case serviceFeePayer = "service_fee_payer"
        case returnWindowHours = "return_window_hours"
    }
}

// ============================================================================
//  Ack-типы Фазы 1 (мелкие ответы seller-API). Денежные/числовые поля —
//  через @Lenient* (сервер шлёт строки/0-1). Fire-and-forget ack'и (значение
//  вызывающий игнорирует) декодируются из любого payload пустым init(from:).
// ============================================================================

/// Ответ, тело которого вызывающий игнорирует (delete/cancel/reply/save-обновление).
struct BoolAck: Decodable { init(from decoder: Decoder) throws {} }

/// POST returns/{id}/approve → {approved, amount, deducted}.
/// deducted > 0 — клиент уже потратил кешбэк/баллы с этого заказа, их
/// вычли из денежного возврата (amount — сколько реально вернуть).
struct ReturnApproveAck: Decodable {
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var deducted: Decimal?
}

/// switch-shop: сервер пишет выбор в сессию; клиенту тело не нужно.
struct SwitchShopAck: Decodable { init(from decoder: Decoder) throws {} }

/// setOrderStatus / setShopStatus / setBookingStatus / setCourierBlocked → {status}.
struct StatusAck: Decodable { let status: String? }

/// toggleAvailability → новое значение is_available (0/1).
struct AvailabilityAck: Decodable {
    @LenientBool var isAvailable: Bool?
    private enum CodingKeys: String, CodingKey { case isAvailable = "is_available" }
}

/// setPrice → новая цена/старая цена (строки "0.00").
struct PriceAck: Decodable {
    @LenientDecimal var price: Decimal?
    @LenientDecimal var priceOld: Decimal?
    private enum CodingKeys: String, CodingKey { case price; case priceOld = "price_old" }
}

/// GET /orders/new-count → {new}.
struct NewCountData: Decodable { @LenientInt var new: Int? }

/// bulkProducts → число затронутых.
struct AffectedAck: Decodable {
    @LenientInt var affected: Int?
    /// Массовое удаление: товары с остатком на складе сервер пропускает и
    /// объясняет это текстом (seller_products.php: skipped_with_stock + message).
    var message: String?
}

/// generateSlots → число созданных слотов.
struct CreatedAck: Decodable {
    @LenientInt var created: Int?
    /// Сетка создана не целиком (лимит за раз) и пояснение сервера —
    /// seller_services.php: partial + note, пропущенные пересечения — note_overlap.
    @LenientBool var partial: Bool?
    var note: String?
    var noteOverlap: String?
    enum CodingKeys: String, CodingKey {
        case created, partial, note
        case noteOverlap = "note_overlap"
    }
}

/// uploadMasterPhoto → путь загруженного фото.
struct MasterPhotoAck: Decodable {
    let photo: String?
    let pathWebp: String?
    private enum CodingKeys: String, CodingKey { case photo; case pathWebp = "path_webp" }
}

// ── Терпимый разбор списков, которые сервер отдаёт «как сохранил» ────────────

/// Теги/аллергены товара: массив (не-строки пропускаем), строка «а, б»
/// (режем по запятой) или объект {"0":"а"} (берём строковые значения).
/// Иначе nil. Теги не теряются: форма товара сохраняет их обратно.
@propertyWrapper
struct LenientTagList: Decodable {
    var wrappedValue: [String]?
    init(wrappedValue: [String]?) { self.wrappedValue = wrappedValue }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        if var c = try? decoder.unkeyedContainer() {
            var out: [String] = []
            while !c.isAtEnd {
                if let s = try? c.decode(String.self) { out.append(s) }
                else if (try? c.decode(LenientString.self)) == nil { break }   // не сдвинулись — выходим
            }
            wrappedValue = out
            return
        }
        if let one = try? decoder.singleValueContainer(), let s = try? one.decode(String.self) {
            wrappedValue = s.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return
        }
        if let k = try? decoder.container(keyedBy: AnyKey.self) {
            // Порядок ключей словаря не задан — сортируем, чтобы теги не прыгали.
            let keys = k.allKeys.sorted { a, b in
                if let x = Int(a.stringValue), let y = Int(b.stringValue) { return x < y }
                return a.stringValue < b.stringValue
            }
            var out: [String] = []
            for key in keys {
                if let s = try? k.decode(String.self, forKey: key) { out.append(s) }
            }
            wrappedValue = out
            return
        }
        wrappedValue = nil
    }
}

/// Позиции заявки на возврат: массив — разбираем, всё остальное — nil.
@propertyWrapper
struct LenientReturnItems: Decodable {
    var wrappedValue: [ReturnRequestItem]?
    init(wrappedValue: [ReturnRequestItem]?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        wrappedValue = try? decoder.singleValueContainer().decode([ReturnRequestItem].self)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: LenientTagList.Type, forKey key: Key) throws -> LenientTagList {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientTagList(wrappedValue: nil)
    }
    func decode(_ type: LenientReturnItems.Type, forKey key: Key) throws -> LenientReturnItems {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientReturnItems(wrappedValue: nil)
    }
}
