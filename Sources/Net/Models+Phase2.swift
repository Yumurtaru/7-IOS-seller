import Foundation

// ============================================================================
//  Models+Phase2.swift — DTO Фазы 2, выведены 1:1 из PHP-роутов:
//   • отзывы/клиенты/аналитика/отчёты — routes/seller_analytics.php
//   • акции/буст/каталог типов        — routes/seller_promotions.php
//   • промокоды/лояльность/настройки  — routes/seller_settings.php
//   • сотрудники/роли/смены (RBAC)    — routes/seller_staff.php + core/StaffRBAC.php
//  Правила прежние: деньги/DECIMAL — @LenientDecimal, флаги 0/1 — @LenientBool,
//  счётчики — @LenientInt, имена полей через CodingKeys 1:1.
// ============================================================================

// ── Права: PHP json_encode пустого массива даёт [], непустого — {"orders":true}.
//    Обёртка принимает оба варианта и не роняет объект. ─────────────────────
@propertyWrapper
struct LenientPermissionMap: Decodable {
    var wrappedValue: [String: Bool]
    init(wrappedValue: [String: Bool] = [:]) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let map = try? c.decode([String: Bool].self) { wrappedValue = map }
        else if let map = try? c.decode([String: Int].self) { wrappedValue = map.mapValues { $0 != 0 } }
        else { wrappedValue = [:] }   // [] или null
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: LenientPermissionMap.Type, forKey key: Key) throws -> LenientPermissionMap {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientPermissionMap(wrappedValue: [:])
    }
}

// ── Отзывы (GET /api/seller/reviews?status=) — bare array до 200 ────────────
struct SellerReview: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var ratingOverall: Int?
    @LenientInt var ratingFood: Int?
    @LenientInt var ratingDelivery: Int?
    @LenientInt var ratingService: Int?
    var text: String?
    var photosJson: String?
    @LenientBool var isVerified: Bool?
    var status: String?             // pending | approved | rejected
    var createdAt: String?
    @LenientInt var orderId: Int?
    var author: String?
    var reply: String?              // подзапрос review_replies.text

    enum CodingKeys: String, CodingKey {
        case id, text, status, author, reply
        case ratingOverall = "rating_overall"
        case ratingFood = "rating_food"
        case ratingDelivery = "rating_delivery"
        case ratingService = "rating_service"
        case photosJson = "photos_json"
        case isVerified = "is_verified"
        case createdAt = "created_at"
        case orderId = "order_id"
    }
    var reviewId: Int { id ?? 0 }
    /// photos_json — JSON-массив путей (колонка json, приходит строкой).
    var photos: [String] {
        guard let raw = photosJson, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return arr
    }
}

// ── Клиенты (RFM) — GET /api/seller/clients?search=&segment= ────────────────
struct ClientSummary: Decodable, Identifiable {
    @LenientInt var id: Int?
    var name: String?
    var phone: String?
    var email: String?
    @LenientDecimal var bonusBalance: Decimal?
    @LenientInt var ordersCount: Int?
    @LenientDecimal var totalSpent: Decimal?
    @LenientDecimal var avgCheck: Decimal?
    var lastOrder: String?
    var firstOrder: String?
    @LenientInt var recency: Int?
    var segment: String?            // loyal | at_risk | churned
    @LenientBool var blacklisted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, phone, email, segment, blacklisted, recency
        case bonusBalance = "bonus_balance"
        case ordersCount = "orders_count"
        case totalSpent = "total_spent"
        case avgCheck = "avg_check"
        case lastOrder = "last_order"
        case firstOrder = "first_order"
    }
    var clientId: Int { id ?? 0 }
}

/// GET /api/seller/clients/{id} — карточка клиента с историей и RFM.
struct ClientDetail: Decodable {
    @LenientInt var id: Int?
    var name: String?
    var phone: String?
    var email: String?
    @LenientDecimal var bonusBalance: Decimal?
    var createdAt: String?
    var orders: [ClientOrder]?
    var bonusHistory: [BonusTransaction]?
    var rfm: ClientRFM?
    var firstOrder: String?
    @LenientInt var frequencyDays: Int?
    var topItems: [ClientTopItem]?
    var note: String?
    @LenientBool var blacklisted: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, phone, email, orders, rfm, note, blacklisted
        case bonusBalance = "bonus_balance"
        case createdAt = "created_at"
        case bonusHistory = "bonus_history"
        case firstOrder = "first_order"
        case frequencyDays = "frequency_days"
        case topItems = "top_items"
    }
}

struct ClientOrder: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientDecimal var total: Decimal?
    var status: String?
    var createdAt: String?
    enum CodingKeys: String, CodingKey {
        case id, total, status
        case createdAt = "created_at"
    }
    var orderId: Int { id ?? 0 }
}

struct BonusTransaction: Decodable, Identifiable {
    var type: String?               // earn | spend
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var balanceAfter: Decimal?
    var createdAt: String?
    enum CodingKeys: String, CodingKey {
        case type, amount
        case balanceAfter = "balance_after"
        case createdAt = "created_at"
    }
    var id: String { (createdAt ?? "") + (type ?? "") + "\(amount ?? 0)" + "\(balanceAfter ?? 0)" }
}

struct ClientRFM: Decodable {
    @LenientInt var recency: Int?
    @LenientInt var frequency: Int?
    @LenientDecimal var monetary: Decimal?
    var segment: String?
}

struct ClientTopItem: Decodable, Identifiable {
    var name: String?
    @LenientDecimal var qty: Decimal?
    @LenientInt var times: Int?
    var id: String { name ?? UUID().uuidString }
}

/// Список строк, который не роняет весь объект: не массив — nil, нестроковые
/// элементы пропускаются.
@propertyWrapper
struct LenientStringArray: Decodable {
    var wrappedValue: [String]?
    init(wrappedValue: [String]?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        guard var c = try? decoder.unkeyedContainer() else { wrappedValue = nil; return }
        var out: [String] = []
        while !c.isAtEnd {
            if let s = try? c.decode(String.self) { out.append(s) }
            else if (try? c.decode(LenientString.self)) == nil { break }   // не сдвинулись — выходим
        }
        wrappedValue = out
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: LenientStringArray.Type, forKey key: Key) throws -> LenientStringArray {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientStringArray(wrappedValue: nil)
    }
}

// ── Акции (routes/seller_promotions.php: promotions.* + метрики) ────────────
struct Promotion: Decodable, Identifiable {
    @LenientInt var id: Int?
    var name: String?
    var description: String?
    @LenientBool var isActive: Bool?
    @LenientBool var archived: Bool?
    var startsAt: String?
    var endsAt: String?
    @LenientInt var priority: Int?
    @LenientBool var stackable: Bool?
    var audience: String?           // all | new | segment | birthday | loyalty_tier | referral
    var audienceValue: String?
    var conditionLogic: String?     // and | or
    var modeScope: String?
    @LenientInt var usageLimit: Int?
    @LenientInt var perClientLimit: Int?
    @LenientInt var perDayLimit: Int?
    @LenientDecimal var budgetAmount: Decimal?
    @LenientDecimal var budgetSpent: Decimal?
    @LenientInt var usedCount: Int?
    var createdAt: String?
    // метрики списка
    @LenientInt var redemptions: Int?
    @LenientDecimal var totalDiscount: Decimal?
    @LenientDecimal var totalPoints: Decimal?
    // только в детали GET /promotions/{id}
    var conditions: [PromoPart]?
    var rewards: [PromoPart]?
    /// Предупреждения сервера по акции («бюджет 0 ₽ — не сработает» и т.п.,
    /// seller_promotions.php: issues). Нет поля или не список — nil, список не падает.
    @LenientStringArray var issues: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, archived, priority, stackable, audience, redemptions, conditions, rewards, issues
        case isActive = "is_active"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case audienceValue = "audience_value"
        case conditionLogic = "condition_logic"
        case modeScope = "mode_scope"
        case usageLimit = "usage_limit"
        case perClientLimit = "per_client_limit"
        case perDayLimit = "per_day_limit"
        case budgetAmount = "budget_amount"
        case budgetSpent = "budget_spent"
        case usedCount = "used_count"
        case createdAt = "created_at"
        case totalDiscount = "total_discount"
        case totalPoints = "total_points"
    }
    var promotionId: Int { id ?? 0 }
}

/// Условие/награда акции: {id, type, config_json}.
struct PromoPart: Decodable, Identifiable {
    @LenientInt var id: Int?
    var type: String?
    var configJson: String?
    enum CodingKeys: String, CodingKey {
        case id, type
        case configJson = "config_json"
    }
    var partId: Int { id ?? 0 }
    var config: [String: Any] {
        guard let raw = configJson, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }
}

/// GET /api/seller/promotions/catalog — доступные типы условий/наград/аудиторий.
struct PromoCatalog: Decodable {
    var conditions: [PromoCatalogType]?
    var rewards: [PromoCatalogType]?
    var audiences: [PromoCatalogType]?
}

struct PromoCatalogType: Decodable, Identifiable, Hashable {
    var type: String?
    var label: String?
    var fields: [String]?
    /// А57/П-22.13: описание полей от сервера (тот же порядок, что fields):
    /// подпись, вид ввода и варианты. Старый сервер поля не шлёт → nil,
    /// тогда подписи — свои (PromoFieldLabels).
    var fieldDefs: [PromoFieldDef]?
    var id: String { type ?? UUID().uuidString }

    enum CodingKeys: String, CodingKey {
        case type, label, fields
        case fieldDefs = "field_defs"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        fields = try c.decodeIfPresent([String].self, forKey: .fields)
        // Новое поле не должно ронять весь каталог акций.
        fieldDefs = (try? c.decodeIfPresent([PromoFieldDef].self, forKey: .fieldDefs)) ?? nil
    }

    func def(for key: String) -> PromoFieldDef? { fieldDefs?.first { $0.key == key } }
}

/// А57/П-22.13: field_defs[] — {key, label, input, options?}.
/// input: number|time|text|product|category|product_ids|select|weekdays.
struct PromoFieldDef: Decodable, Hashable {
    var key: String
    var label: String?
    var input: String?
    var options: [PromoFieldOption]?

    enum CodingKeys: String, CodingKey { case key, label, input, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = (try? c.decode(String.self, forKey: .key)) ?? ""
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        input = try? c.decodeIfPresent(String.self, forKey: .input)
        options = (try? c.decodeIfPresent([PromoFieldOption].self, forKey: .options)) ?? nil
    }
}

/// Вариант select/weekdays: value приходит числом (дни 1…7) или строкой.
struct PromoFieldOption: Decodable, Hashable {
    var value: String
    var label: String

    enum CodingKeys: String, CodingKey { case value, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try? c.decode(String.self, forKey: .value) { value = s }
        else if let i = try? c.decode(Int.self, forKey: .value) { value = String(i) }
        else if let d = try? c.decode(Double.self, forKey: .value) { value = String(d) }
        else { value = "" }
        label = (try? c.decode(String.self, forKey: .label)) ?? value
    }
}

// ── Промокоды (GET /api/seller/promos — promo_codes.*) ──────────────────────
struct PromoCode: Decodable, Identifiable {
    @LenientInt var id: Int?
    var code: String?
    var type: String?               // percent | fixed | free_delivery
    @LenientDecimal var value: Decimal?
    @LenientDecimal var minOrder: Decimal?
    @LenientInt var maxUses: Int?
    @LenientInt var usedCount: Int?
    var expiresAt: String?
    @LenientBool var isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case id, code, type, value
        case minOrder = "min_order"
        case maxUses = "max_uses"
        case usedCount = "used_count"
        case expiresAt = "expires_at"
        case isActive = "is_active"
    }
    var promoId: Int { id ?? 0 }
}

// ── Буст-продвижение (GET/POST /api/seller/boost) ───────────────────────────
struct BoostInfo: Decodable {
    var shopBoostUntil: String?
    @LenientBool var shopBoostActive: Bool?
    @LenientDecimal var priceDayShop: Decimal?
    @LenientDecimal var priceDayProduct: Decimal?
    @LenientDecimal var balance: Decimal?

    enum CodingKeys: String, CodingKey {
        case balance
        case shopBoostUntil = "shop_boost_until"
        case shopBoostActive = "shop_boost_active"
        case priceDayShop = "price_day_shop"
        case priceDayProduct = "price_day_product"
    }
}

struct BoostAck: Decodable {
    var boostUntil: String?
    @LenientDecimal var charged: Decimal?
    @LenientDecimal var balance: Decimal?
    enum CodingKeys: String, CodingKey {
        case charged, balance
        case boostUntil = "boost_until"
    }
}

// ── Лояльность (GET/POST /api/seller/loyalty — loyalty_programs) ────────────
struct LoyaltyProgram: Decodable {
    @LenientDecimal var cashbackPercent: Decimal?
    @LenientDecimal var minOrderForCashback: Decimal?
    @LenientInt var pointsExpireDays: Int?
    @LenientBool var isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case cashbackPercent = "cashback_percent"
        case minOrderForCashback = "min_order_for_cashback"
        case pointsExpireDays = "points_expire_days"
        case isActive = "is_active"
    }
}

// ── Сотрудники / роли / смены (routes/seller_staff.php) ─────────────────────
/// GET /api/seller/staff/permissions — каталог прав {группа:[[code,label,desc]]} + пресеты.
struct StaffPermissionsInfo: Decodable {
    var catalog: [String: [[String]]]?
    var presets: [StaffPreset]?
}

struct StaffPreset: Decodable, Identifiable {
    var code: String?
    var name: String?
    var color: String?
    @LenientPermissionMap var permissions: [String: Bool]
    var id: String { code ?? UUID().uuidString }
}

struct StaffRole: Decodable, Identifiable {
    @LenientInt var id: Int?
    var code: String?               // admin|manager|cashier|storekeeper|courier|null
    var name: String?
    var color: String?
    @LenientBool var isSystem: Bool?
    @LenientPermissionMap var permissions: [String: Bool]
    @LenientInt var members: Int?

    enum CodingKeys: String, CodingKey {
        case id, code, name, color, permissions, members
        case isSystem = "is_system"
    }
    var roleId: Int { id ?? 0 }
}

/// staffEmployeeRow() в routes/seller_staff.php — все поля 1:1.
struct Employee: Decodable, Identifiable {
    @LenientInt var id: Int?
    var fullName: String?
    var phone: String?
    var email: String?
    var position: String?
    @LenientInt var roleId: Int?
    var roleName: String?
    var roleColor: String?
    var status: String?             // active | blocked | fired
    var color: String?
    var pin: String?
    @LenientBool var hasPin: Bool?
    var salaryType: String?         // fixed | percent | mixed
    @LenientDecimal var salaryValue: Decimal?
    @LenientDecimal var nightBonus: Decimal?
    var hiredAt: String?
    var note: String?
    @LenientInt var userId: Int?
    /// Есть вход в кабинет. Такую карточку удаляет только владелец
    /// (DELETE employees: panel_access → 403 остальным).
    @LenientBool var panelAccess: Bool?

    enum CodingKeys: String, CodingKey {
        case id, phone, email, position, status, color, pin, note
        case panelAccess = "panel_access"
        case fullName = "full_name"
        case roleId = "role_id"
        case roleName = "role_name"
        case roleColor = "role_color"
        case hasPin = "has_pin"
        case salaryType = "salary_type"
        case salaryValue = "salary_value"
        case nightBonus = "night_bonus"
        case hiredAt = "hired_at"
        case userId = "user_id"
    }
    var employeeId: Int { id ?? 0 }
}

/// GET /api/seller/staff/shifts — смены с учётом наличных.
struct StaffShift: Decodable, Identifiable {
    @LenientInt var id: Int?
    var startedAt: String?
    var endedAt: String?
    var status: String?             // open | closed
    @LenientDecimal var revenueDuringShift: Decimal?
    @LenientDecimal var cashOpen: Decimal?
    @LenientDecimal var cashCounted: Decimal?
    @LenientDecimal var cashExpected: Decimal?
    @LenientDecimal var cashDiff: Decimal?
    @LenientInt var ordersCount: Int?
    var note: String?
    var position: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case id, status, note, position, name
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case revenueDuringShift = "revenue_during_shift"
        case cashOpen = "cash_open"
        case cashCounted = "cash_counted"
        case cashExpected = "cash_expected"
        case cashDiff = "cash_diff"
        case ordersCount = "orders_count"
    }
    var shiftId: Int { id ?? 0 }
}

/// POST /api/seller/staff/shifts/{id}/close.
struct ShiftCloseResult: Decodable {
    @LenientDecimal var revenue: Decimal?
    @LenientInt var orders: Int?
    @LenientDecimal var cashExpected: Decimal?
    @LenientDecimal var cashCounted: Decimal?
    @LenientDecimal var cashDiff: Decimal?

    enum CodingKeys: String, CodingKey {
        case revenue, orders
        case cashExpected = "cash_expected"
        case cashCounted = "cash_counted"
        case cashDiff = "cash_diff"
    }
}

// ── Аналитика (GET /api/seller/analytics?period=) ───────────────────────────
struct AnalyticsData: Decodable {
    var period: String?
    var metrics: AnalyticsMetrics?
    var byDay: [AnalyticsDayPoint]?
    var heatmap: [HeatPoint]?
    var top: [AnalyticsTopItem]?
    var donut: [DonutSlice]?
    var funnel: FunnelData?
    var sources: [SourcePoint]?

    enum CodingKeys: String, CodingKey {
        case period, metrics, heatmap, top, donut, funnel, sources
        case byDay = "by_day"
    }
}

struct AnalyticsMetrics: Decodable {
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var revenueChange: Decimal?   // null, если прошлый период пуст
    @LenientInt var orders: Int?
    @LenientDecimal var avgCheck: Decimal?
    @LenientInt var clients: Int?
    @LenientDecimal var avgRating: Decimal?
    @LenientInt var avgDeliveryMin: Int?

    enum CodingKeys: String, CodingKey {
        case revenue, orders, clients
        case revenueChange = "revenue_change"
        case avgCheck = "avg_check"
        case avgRating = "avg_rating"
        case avgDeliveryMin = "avg_delivery_min"
    }
}

struct AnalyticsDayPoint: Decodable, Identifiable {
    var d: String?
    @LenientDecimal var r: Decimal?
    @LenientInt var c: Int?
    var id: String { d ?? UUID().uuidString }
}

struct HeatPoint: Decodable {
    @LenientInt var dow: Int?   // WEEKDAY(): 0=Пн … 6=Вс
    @LenientInt var h: Int?     // час 0–23
    @LenientInt var c: Int?
}

struct AnalyticsTopItem: Decodable, Identifiable {
    var name: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var rev: Decimal?
    var id: String { name ?? UUID().uuidString }
}

struct DonutSlice: Decodable, Identifiable {
    var t: String?              // delivery | pickup | dine_in
    @LenientInt var c: Int?
    var id: String { t ?? UUID().uuidString }
}

struct FunnelData: Decodable {
    @LenientInt var created: Int?
    @LenientInt var accepted: Int?
    @LenientInt var done: Int?
}

struct SourcePoint: Decodable, Identifiable {
    var d: String?
    @LenientInt var newC: Int?
    @LenientInt var repC: Int?
    enum CodingKeys: String, CodingKey {
        case d
        case newC = "new_c"
        case repC = "rep_c"
    }
    var id: String { d ?? UUID().uuidString }
}

/// GET /api/seller/analytics/top-products — таблица топ-позиций.
struct TopProductRow: Decodable, Identifiable {
    @LenientInt var productId: Int?
    var name: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var rev: Decimal?
    @LenientDecimal var ret: Decimal?
    var category: String?
    @LenientDecimal var returnPct: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, qty, rev, ret, category
        case productId = "product_id"
        case returnPct = "return_pct"
    }
    var id: String { "\(productId ?? 0)-" + (name ?? "") }
}

/// GET /api/seller/analytics/forecast — прогноз спроса на неделю.
struct ForecastRow: Decodable, Identifiable {
    @LenientInt var productId: Int?
    var name: String?
    @LenientInt var sold7: Int?
    @LenientInt var soldPrev7: Int?
    @LenientDecimal var sold28: Decimal?
    @LenientInt var forecast7: Int?
    @LenientInt var trendPct: Int?
    @LenientDecimal var avgWeekly: Decimal?

    enum CodingKeys: String, CodingKey {
        case name
        case productId = "product_id"
        case sold7 = "sold_7"
        case soldPrev7 = "sold_prev7"
        case sold28 = "sold_28"
        case forecast7 = "forecast_7"
        case trendPct = "trend_pct"
        case avgWeekly = "avg_weekly"
    }
    var id: String { "\(productId ?? 0)-" + (name ?? "") }
}

/// GET /api/seller/reports?period= — сводный отчёт.
struct ReportsData: Decodable {
    var byCategory: [CategoryReportRow]?
    var commission: CommissionReport?
    var totals: ReportTotals?
    enum CodingKeys: String, CodingKey {
        case commission, totals
        case byCategory = "by_category"
    }
}

struct CategoryReportRow: Decodable, Identifiable {
    var category: String?
    @LenientDecimal var rev: Decimal?
    @LenientDecimal var qty: Decimal?
    var id: String { category ?? UUID().uuidString }
}

struct CommissionReport: Decodable {
    @LenientDecimal var comm: Decimal?
    @LenientDecimal var fee: Decimal?
    @LenientInt var cnt: Int?
}

struct ReportTotals: Decodable {
    @LenientInt var orders: Int?
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var avgCheck: Decimal?
    enum CodingKeys: String, CodingKey {
        case orders, revenue
        case avgCheck = "avg_check"
    }
}

// ── Настройки: уведомления / оплата / часы ──────────────────────────────────
/// Блок notifications из GET /api/seller/settings.
struct NotificationSettings: Decodable {
    var telegramChatId: String?
    var events: [String]?
    /// П-27.9: какие события вообще бывают — [{key, label}] (галочки рисуем по
    /// ним). Старый сервер поля не шлёт → nil, список приложения как раньше.
    var eventsAvailable: [TgEventOption]?
    enum CodingKeys: String, CodingKey {
        case events
        case telegramChatId = "telegram_chat_id"
        case eventsAvailable = "events_available"
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        telegramChatId = try? c.decodeIfPresent(String.self, forKey: .telegramChatId)
        events = (try? c.decodeIfPresent([String].self, forKey: .events)) ?? []
        // Строки без ключа или подписи и повторы ключа отбрасываем (ключ — id
        // галочки на экране); пустой итог — как нет поля.
        var seen = Set<String>()
        let opts = ((try? c.decodeIfPresent([TgEventOption].self, forKey: .eventsAvailable)) ?? nil)?
            .filter { !$0.key.isEmpty && !$0.label.isEmpty && seen.insert($0.key).inserted }
        eventsAvailable = (opts?.isEmpty ?? true) ? nil : opts
    }
}

/// Одно событие Telegram-уведомлений из notifications.events_available.
struct TgEventOption: Decodable {
    let key: String
    let label: String
    enum CodingKeys: String, CodingKey { case key, label }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = ((try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        label = ((try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// GET /api/seller/settings/payment — shop_payment_methods.
struct PaymentMethodSetting: Decodable, Identifiable {
    var type: String?               // cash | card_courier | sbp | online_card
    @LenientBool var isEnabled: Bool?
    var comment: String?
    var availableFor: String?       // JSON-строка из БД: ["delivery","pickup","dine_in"]

    enum CodingKeys: String, CodingKey {
        case type, comment
        case isEnabled = "is_enabled"
        case availableFor = "available_for"
    }
    var id: String { type ?? UUID().uuidString }
    var availableForList: [String] {
        guard let raw = availableFor, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return ["delivery", "pickup", "dine_in"]
        }
        return arr
    }
}

/// GET /api/seller/settings/hours — shop_hours (day_of_week 1=Пн … 7=Вс).
struct ShopHour: Decodable, Identifiable {
    @LenientInt var dayOfWeek: Int?
    var openTime: String?
    var closeTime: String?
    @LenientBool var isClosed: Bool?

    enum CodingKeys: String, CodingKey {
        case dayOfWeek = "day_of_week"
        case openTime = "open_time"
        case closeTime = "close_time"
        case isClosed = "is_closed"
    }
    var id: Int { dayOfWeek ?? 0 }
}

// ── Мелкие подтверждения Фазы 2 ──────────────────────────────────────────────
struct BalanceAck: Decodable { @LenientDecimal var balance: Decimal? }
struct BlacklistAck: Decodable { @LenientBool var blacklisted: Bool? }
struct ToggleActiveAck: Decodable {
    @LenientBool var isActive: Bool?
    enum CodingKeys: String, CodingKey { case isActive = "is_active" }
}
struct LogoUploadAck: Decodable {
    var logo: String?
    var banner: String?
}
struct Phase2BoolAck: Decodable {
    @LenientBool var replied: Bool?
    @LenientBool var archived: Bool?
    @LenientBool var restored: Bool?
    @LenientBool var saved: Bool?
    @LenientBool var deleted: Bool?
}

/// Ответ на создание сущности: { "id": <int> }. Фаза 2 — createPromoCode / createStaffRole / openShift.
struct IdAck: Decodable { @LenientInt var id: Int? }

