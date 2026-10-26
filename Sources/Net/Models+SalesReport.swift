import Foundation

// ============================================================================
//  Волна А82: «Отчёт по продажам» и «Контроль потерь» (routes/seller_sales_report.php,
//  core/SalesReport.php, core/LossControl.php; формы — КОНТРАКТ-СПРАВКА.md).
//   GET /api/seller/sales-report?period=…|from&to&station_id=
//   GET /api/seller/loss-control?period=…|from&to&rule=&brief=1
//  Деньги — строками "1234.50" (@LenientDecimal), счётчики — @LenientInt.
//  Каждое поле необязательно: поле не того типа даёт nil/пусто, а не ошибку
//  всего ответа (экран и блоки дашборда рисуют то, что пришло).
// ============================================================================

// ── Мягкие обёртки (только для этих ответов) ────────────────────────────────

/// Вложенный объект: не объект или битый — nil, остальной ответ живёт.
@propertyWrapper
struct SRObject<T: Decodable>: Decodable {
    var wrappedValue: T?
    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try? T(from: decoder) }
}

/// Массив объектов: битый элемент пропускаем, не массив — пустой список.
@propertyWrapper
struct SRList<E: Decodable>: Decodable {
    var wrappedValue: [E]
    init(wrappedValue: [E]) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        var out: [E] = []
        if var c = try? decoder.unkeyedContainer() {
            while !c.isAtEnd {
                // SRObject сам не падает — индекс контейнера сдвигается всегда.
                guard let item = try? c.decode(SRObject<E>.self) else { break }
                if let v = item.wrappedValue { out.append(v) }
            }
        }
        wrappedValue = out
    }
}

private struct SRAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}

/// {код: число}. PHP отдаёт пустой объект как [] — тогда пустой словарь.
/// Нет ключа — nil (нужно, чтобы отличить by_rule_all старого ответа).
@propertyWrapper
struct SRIntMap: Decodable {
    var wrappedValue: [String: Int]?
    init(wrappedValue: [String: Int]?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        var out: [String: Int] = [:]
        if let c = try? decoder.container(keyedBy: SRAnyKey.self) {
            for key in c.allKeys {
                if let v = (try? c.decode(LenientInt.self, forKey: key))?.wrappedValue { out[key.stringValue] = v }
            }
        }
        wrappedValue = out
    }
}

/// {код: деньги "0.00"} — суммы участника по категориям.
@propertyWrapper
struct SRMoneyMap: Decodable {
    var wrappedValue: [String: Decimal]
    init(wrappedValue: [String: Decimal]) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        var out: [String: Decimal] = [:]
        if let c = try? decoder.container(keyedBy: SRAnyKey.self) {
            for key in c.allKeys {
                if let v = (try? c.decode(LenientDecimal.self, forKey: key))?.wrappedValue { out[key.stringValue] = v }
            }
        }
        wrappedValue = out
    }
}

/// {код: объект} — словарь правил контроля потерь.
@propertyWrapper
struct SRObjectMap<T: Decodable>: Decodable {
    var wrappedValue: [String: T]
    init(wrappedValue: [String: T]) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        var out: [String: T] = [:]
        if let c = try? decoder.container(keyedBy: SRAnyKey.self) {
            for key in c.allKeys {
                if let v = (try? c.decode(SRObject<T>.self, forKey: key))?.wrappedValue { out[key.stringValue] = v }
            }
        }
        wrappedValue = out
    }
}

extension KeyedDecodingContainer {
    func decode<T: Decodable>(_ type: SRObject<T>.Type, forKey key: Key) throws -> SRObject<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? SRObject(wrappedValue: nil)
    }
    func decode<E: Decodable>(_ type: SRList<E>.Type, forKey key: Key) throws -> SRList<E> {
        (try? decodeIfPresent(type, forKey: key)) ?? SRList(wrappedValue: [])
    }
    func decode(_ type: SRIntMap.Type, forKey key: Key) throws -> SRIntMap {
        (try? decodeIfPresent(type, forKey: key)) ?? SRIntMap(wrappedValue: nil)
    }
    func decode(_ type: SRMoneyMap.Type, forKey key: Key) throws -> SRMoneyMap {
        (try? decodeIfPresent(type, forKey: key)) ?? SRMoneyMap(wrappedValue: [:])
    }
    func decode<T: Decodable>(_ type: SRObjectMap<T>.Type, forKey key: Key) throws -> SRObjectMap<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? SRObjectMap(wrappedValue: [:])
    }
}

// ── Период (общий у обеих ручек) ────────────────────────────────────────────
struct SRPeriod: Decodable {
    @LenientString var from: String?
    @LenientString var to: String?
    @LenientInt var days: Int?
    @LenientString var prevFrom: String?
    @LenientString var prevTo: String?
    @LenientString var prevUntil: String?
    @LenientBool var compareSameTime: Bool?
    @LenientString var label: String?
    @LenientInt var stationId: Int?

    enum CodingKeys: String, CodingKey {
        case from, to, days, label
        case prevFrom = "prev_from"
        case prevTo = "prev_to"
        case prevUntil = "prev_until"
        case compareSameTime = "compare_same_time"
        case stationId = "station_id"
    }
}

// ── GET /api/seller/sales-report ────────────────────────────────────────────
struct SalesReport: Decodable {
    @SRObject var period: SRPeriod?
    @SRObject var summary: SalesSummary?
    @SRObject var compare: SalesCompare?
    @SRList var methods: [SalesMethod]
    @SRList var byDay: [SalesDay]
    @SRList var byHour: [SalesHour]
    @SRList var channels: [SalesChannel]
    @SRList var stations: [SalesStation]

    enum CodingKeys: String, CodingKey {
        case period, summary, compare, methods, channels, stations
        case byDay = "by_day"
        case byHour = "by_hour"
    }
}

struct SalesSummary: Decodable {
    @LenientInt var orders: Int?
    @LenientDecimal var gross: Decimal?
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var revenueBeforeReturns: Decimal?
    @LenientDecimal var avgCheck: Decimal?
    @LenientDecimal var returns: Decimal?
    @LenientInt var returnsCount: Int?
    @LenientDecimal var returnsBonus: Decimal?
    @LenientDecimal var returnsCreatedInPeriod: Decimal?
    @LenientDecimal var cash: Decimal?
    @LenientDecimal var cashless: Decimal?
    @LenientDecimal var pending: Decimal?
    @LenientDecimal var cashNet: Decimal?
    @LenientDecimal var tips: Decimal?
    @LenientDecimal var delivery: Decimal?
    @LenientDecimal var serviceFee: Decimal?
    @LenientDecimal var discountTotal: Decimal?
    @LenientDecimal var discountPromo: Decimal?
    @LenientDecimal var discountManual: Decimal?
    @LenientInt var discountManualOrders: Int?
    @LenientDecimal var pointsSpent: Decimal?
    @LenientDecimal var giftcardsRedeemed: Decimal?

    enum CodingKeys: String, CodingKey {
        case orders, gross, revenue, returns, cash, cashless, pending, tips, delivery
        case revenueBeforeReturns = "revenue_before_returns"
        case avgCheck = "avg_check"
        case returnsCount = "returns_count"
        case returnsBonus = "returns_bonus"
        case returnsCreatedInPeriod = "returns_created_in_period"
        case cashNet = "cash_net"
        case serviceFee = "service_fee"
        case discountTotal = "discount_total"
        case discountPromo = "discount_promo"
        case discountManual = "discount_manual"
        case discountManualOrders = "discount_manual_orders"
        case pointsSpent = "points_spent"
        case giftcardsRedeemed = "giftcards_redeemed"
    }
}

struct SalesCompare: Decodable {
    @LenientDecimal var prevRevenue: Decimal?
    @LenientInt var prevOrders: Int?
    @LenientDecimal var prevAvgCheck: Decimal?
    @LenientBool var sameTime: Bool?
    // null — в прошлом периоде данных нет (стрелку не рисуем).
    @LenientDouble var revenuePct: Double?
    @LenientDouble var ordersPct: Double?
    @LenientDouble var avgCheckPct: Double?
    @LenientDouble var cashPct: Double?
    @LenientDouble var cashlessPct: Double?

    enum CodingKeys: String, CodingKey {
        case prevRevenue = "prev_revenue"
        case prevOrders = "prev_orders"
        case prevAvgCheck = "prev_avg_check"
        case sameTime = "same_time"
        case revenuePct = "revenue_pct"
        case ordersPct = "orders_pct"
        case avgCheckPct = "avg_check_pct"
        case cashPct = "cash_pct"
        case cashlessPct = "cashless_pct"
    }
}

struct SalesMethod: Decodable {
    @LenientString var code: String?
    @LenientString var label: String?
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var refunds: Decimal?
    @LenientDecimal var net: Decimal?
    @LenientDouble var share: Double?
    @LenientInt var orders: Int?
}

struct SalesDay: Decodable {
    @LenientString var date: String?
    @LenientInt var orders: Int?
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var returns: Decimal?
    @LenientDecimal var cash: Decimal?
    @LenientDecimal var card: Decimal?
    @LenientDecimal var sbp: Decimal?
    @LenientDecimal var online: Decimal?
    @LenientDecimal var pending: Decimal?
    @LenientDecimal var other: Decimal?

    /// Сумма способа по коду methods[].code (cash, card, sbp, online, pending, other).
    func amount(_ code: String) -> Decimal {
        switch code {
        case "cash": return cash ?? 0
        case "card": return card ?? 0
        case "sbp": return sbp ?? 0
        case "online": return online ?? 0
        case "pending": return pending ?? 0
        case "other": return other ?? 0
        default: return 0
        }
    }
}

struct SalesHour: Decodable {
    @LenientInt var hour: Int?
    @LenientInt var orders: Int?
    /// Продажи до возвратов.
    @LenientDecimal var sales: Decimal?
}

struct SalesChannel: Decodable {
    @LenientString var code: String?
    @LenientString var label: String?
    @LenientInt var orders: Int?
    @LenientDecimal var sales: Decimal?
    @LenientDecimal var cash: Decimal?
    @LenientDecimal var cashless: Decimal?
    @LenientDecimal var avgCheck: Decimal?

    enum CodingKeys: String, CodingKey {
        case code, label, orders, sales, cash, cashless
        case avgCheck = "avg_check"
    }
}

struct SalesStation: Decodable {
    @LenientInt var stationId: Int?
    @LenientString var name: String?
    @LenientInt var orders: Int?
    @LenientDecimal var sales: Decimal?
    @LenientDecimal var cash: Decimal?
    @LenientDecimal var card: Decimal?
    @LenientDecimal var sbp: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, orders, sales, cash, card, sbp
        case stationId = "station_id"
    }
}

// ── GET /api/seller/loss-control ────────────────────────────────────────────
struct LossControl: Decodable {
    @LenientBool var enabled: Bool?
    @SRObject var period: SRPeriod?
    @LenientInt var index: Int?
    @LenientString var level: String?
    @LenientString var levelLabel: String?
    @SRObject var counts: LossCounts?
    /// Без операций владельца.
    @SRIntMap var byRule: [String: Int]?
    /// С операциями владельца — столько строк покажет фильтр rule (чипы).
    @SRIntMap var byRuleAll: [String: Int]?
    @LenientBool var truncated: Bool?
    @LenientInt var rowsLimit: Int?
    @SRObject var kpi: LossKpi?
    @SRList var actors: [LossActor]
    @SRList var incidents: [LossIncident]
    /// А86 (П-39 №2), только в полном ответе: сколько всего и сколько сервер отдаёт в списке
    /// (incidentsTotal — после фильтра rule). Старый сервер — nil, подписи «Показаны первые…» нет.
    @LenientInt var incidentsTotal: Int?
    @LenientInt var incidentsLimit: Int?
    @LenientInt var actorsTotal: Int?
    @LenientInt var actorsLimit: Int?
    /// brief=1: три главные операции без операций владельца.
    @SRList var top: [LossIncident]
    @SRList var trend: [LossTrend]
    @SRObjectMap var rules: [String: LossRule]

    enum CodingKeys: String, CodingKey {
        case enabled, period, index, level, counts, truncated, kpi, actors, incidents, top, trend, rules
        case levelLabel = "level_label"
        case byRule = "by_rule"
        case byRuleAll = "by_rule_all"
        case rowsLimit = "rows_limit"
        case incidentsTotal = "incidents_total"
        case incidentsLimit = "incidents_limit"
        case actorsTotal = "actors_total"
        case actorsLimit = "actors_limit"
    }
}

struct LossCounts: Decodable {
    @LenientInt var critical: Int?
    @LenientInt var warning: Int?
    @LenientInt var info: Int?
    @LenientInt var total: Int?
    @LenientInt var owner: Int?
}

struct LossKpi: Decodable {
    @LenientDecimal var revenue: Decimal?
    @LenientInt var orders: Int?
    @LenientDecimal var avgCheck: Decimal?
    @LenientDecimal var bigRefundFrom: Decimal?
    @LenientInt var refundsCount: Int?
    @LenientDecimal var refundsSum: Decimal?
    @LenientDouble var refundsPct: Double?
    @LenientInt var voidsCount: Int?
    @LenientDecimal var voidsSum: Decimal?
    @LenientInt var cancelsCount: Int?
    @LenientInt var itemCuts: Int?
    @LenientInt var afterPrebill: Int?
    @LenientInt var manualDiscounts: Int?
    @LenientDecimal var manualDiscountsSum: Decimal?
    @LenientInt var drawerNoSale: Int?
    @LenientInt var noReceipt: Int?
    @LenientDecimal var noReceiptSum: Decimal?
    @LenientInt var freePrice: Int?
    @LenientDecimal var cashOutSum: Decimal?
    @LenientInt var cashOutCount: Int?
    @LenientInt var overrides: Int?
    @LenientInt var offlineApprovals: Int?
    @LenientInt var pinAttacks: Int?
    @LenientInt var shiftsClosed: Int?
    @LenientDecimal var shortageSum: Decimal?
    @LenientDecimal var surplusSum: Decimal?

    enum CodingKeys: String, CodingKey {
        case revenue, orders, overrides
        case avgCheck = "avg_check"
        case bigRefundFrom = "big_refund_from"
        case refundsCount = "refunds_count"
        case refundsSum = "refunds_sum"
        case refundsPct = "refunds_pct"
        case voidsCount = "voids_count"
        case voidsSum = "voids_sum"
        case cancelsCount = "cancels_count"
        case itemCuts = "item_cuts"
        case afterPrebill = "after_prebill"
        case manualDiscounts = "manual_discounts"
        case manualDiscountsSum = "manual_discounts_sum"
        case drawerNoSale = "drawer_no_sale"
        case noReceipt = "no_receipt"
        case noReceiptSum = "no_receipt_sum"
        case freePrice = "free_price"
        case cashOutSum = "cash_out_sum"
        case cashOutCount = "cash_out_count"
        case offlineApprovals = "offline_approvals"
        case pinAttacks = "pin_attacks"
        case shiftsClosed = "shifts_closed"
        case shortageSum = "shortage_sum"
        case surplusSum = "surplus_sum"
    }
}

struct LossActor: Decodable {
    @LenientString var key: String?
    @LenientString var name: String?
    /// cashier | station | staff | owner
    @LenientString var kind: String?
    @SRIntMap var counts: [String: Int]?
    @SRMoneyMap var sums: [String: Decimal]
    @LenientInt var afterPrebill: Int?
    @LenientInt var incidents: Int?
    @LenientInt var riskPoints: Int?
    /// Категории, где операций в 2,5 раза больше обычного — подсвечиваем.
    @LenientStringArray var flags: [String]?
    @LenientString var lastAt: String?

    enum CodingKeys: String, CodingKey {
        case key, name, kind, counts, sums, incidents, flags
        case afterPrebill = "after_prebill"
        case riskPoints = "risk_points"
        case lastAt = "last_at"
    }
}

struct LossIncident: Decodable {
    @LenientString var rule: String?
    @LenientString var title: String?
    /// critical | warning | info
    @LenientString var severity: String?
    @LenientString var detail: String?
    @LenientString var advice: String?
    @LenientString var actor: String?
    @LenientString var actorKey: String?
    @LenientDecimal var amount: Decimal?
    @LenientString var at: String?
    @LenientInt var orderId: Int?
    @LenientString var receiptNumber: String?
    @LenientInt var auditId: Int?
    /// Операция владельца: в ленте, но не в индексе и счётчиках.
    @LenientBool var owner: Bool?

    enum CodingKeys: String, CodingKey {
        case rule, title, severity, detail, advice, actor, amount, at, owner
        case actorKey = "actor_key"
        case orderId = "order_id"
        case receiptNumber = "receipt_number"
        case auditId = "audit_id"
    }
}

struct LossTrend: Decodable {
    @LenientString var date: String?
    @LenientInt var critical: Int?
    @LenientInt var warning: Int?
}

struct LossRule: Decodable {
    @LenientString var title: String?
    @LenientString var advice: String?
}
