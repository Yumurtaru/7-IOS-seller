import Foundation

// ============================================================================
//  План закупок — routes/seller_replenishment.php (волна В5 сайта).
//
//  Продавец декодирует БЕЗ convertFromSnakeCase: явные CodingKeys.
//  Деньги ("0.00") и количества ("0.000") — строки, @LenientDecimal.
//  days_cover, cover_after_days — ЧИСЛА (JSON number), но принимаем и строку.
//  Все поля необязательные: старый сервер или кривое поле не роняют экран.
// ============================================================================

/// GET /status (и поле status внутри плана).
struct ReplStatus: Decodable {
    @LenientBool var running: Bool?
    @LenientInt var jobId: Int?
    @LenientString var status: String?
    @LenientString var stage: String?
    @LenientString var stageLabel: String?
    @LenientInt var progress: Int?
    @LenientInt var itemsDone: Int?
    @LenientInt var itemsTotal: Int?
    @LenientString var error: String?
    @LenientString var lastComputedAt: String?
    @LenientBool var hasData: Bool?

    enum CodingKeys: String, CodingKey {
        case running, status, stage, progress, error
        case jobId = "job_id"
        case stageLabel = "stage_label"
        case itemsDone = "items_done"
        case itemsTotal = "items_total"
        case lastComputedAt = "last_computed_at"
        case hasData = "has_data"
    }
}

struct ReplBudget: Decodable {
    @LenientDecimal var limit: Decimal?
    @LenientDecimal var totalBefore: Decimal?
    @LenientInt var cutLines: Int?
    @LenientBool var over: Bool?

    enum CodingKeys: String, CodingKey {
        case limit, over
        case totalBefore = "total_before"
        case cutLines = "cut_lines"
    }
}

struct ReplSummary: Decodable {
    @LenientInt var riskCount: Int?
    @LenientInt var orderLines: Int?
    @LenientInt var orderSuppliers: Int?
    @LenientDecimal var orderAmount: Decimal?
    @LenientInt var noSupplier: Int?
    var budget: ReplBudget?

    enum CodingKeys: String, CodingKey {
        case budget
        case riskCount = "risk_count"
        case orderLines = "order_lines"
        case orderSuppliers = "order_suppliers"
        case orderAmount = "order_amount"
        case noSupplier = "no_supplier"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _riskCount = try c.decode(LenientInt.self, forKey: .riskCount)
        _orderLines = try c.decode(LenientInt.self, forKey: .orderLines)
        _orderSuppliers = try c.decode(LenientInt.self, forKey: .orderSuppliers)
        _orderAmount = try c.decode(LenientDecimal.self, forKey: .orderAmount)
        _noSupplier = try c.decode(LenientInt.self, forKey: .noSupplier)
        budget = c.tol(ReplBudget.self, .budget)
    }
}

/// Группа поставщика (suppliers[]). supplier_id = null — «Без поставщика».
struct ReplGroup: Decodable {
    @LenientInt var supplierId: Int?
    @LenientString var name: String?
    @LenientInt var lines: Int?
    @LenientInt var toOrder: Int?
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var minOrderAmount: Decimal?
    @LenientDecimal var toMin: Decimal?
    @LenientBool var minReached: Bool?
    @LenientString var deliveryDate: String?
    @LenientString var orderBy: String?
    @LenientInt var riskLines: Int?

    enum CodingKeys: String, CodingKey {
        case name, lines, amount
        case supplierId = "supplier_id"
        case toOrder = "to_order"
        case minOrderAmount = "min_order_amount"
        case toMin = "to_min"
        case minReached = "min_reached"
        case deliveryDate = "delivery_date"
        case orderBy = "order_by"
        case riskLines = "risk_lines"
    }
}

struct ReplLineSupplier: Decodable {
    @LenientInt var supplierId: Int?
    @LenientString var name: String?
    @LenientString var deliveryDate: String?
    @LenientInt var leadDays: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case supplierId = "id"
        case deliveryDate = "delivery_date"
        case leadDays = "lead_days"
    }
}

struct ReplFlags: Decodable {
    @LenientBool var risk: Bool?
    @LenientBool var excess: Bool?
    @LenientBool var dead: Bool?
    @LenientBool var edited: Bool?
    @LenientBool var cutByBudget: Bool?
    @LenientBool var moqBlocked: Bool?
    @LenientBool var noForecast: Bool?

    enum CodingKeys: String, CodingKey {
        case risk, excess, dead, edited
        case cutByBudget = "cut_by_budget"
        case moqBlocked = "moq_blocked"
        case noForecast = "no_forecast"
    }
}

/// «Почему столько»: приложению достаточно text.
struct ReplExplain: Decodable {
    var text: [String] = []
    enum CodingKeys: String, CodingKey { case text }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = c.tolList(String.self, .text)
    }
}

/// GET /plan/explain -> {id, kind, name, explain:{text:[…]}}; нужен только explain.
struct ReplExplainReply: Decodable {
    var explain: ReplExplain?
    enum CodingKeys: String, CodingKey { case explain }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        explain = c.tol(ReplExplain.self, .explain)
    }
}

struct ReplLine: Decodable, Identifiable {
    @LenientString var kind: String?
    @LenientInt var itemId: Int?
    @LenientString var name: String?
    @LenientString var article: String?
    @LenientString var unit: String?
    @LenientString var status: String?
    @LenientDecimal var stock: Decimal?
    @LenientDecimal var inTransit: Decimal?
    @LenientDecimal var avgDaily: Decimal?
    /// ЧИСЛО (может быть null): на сколько дней хватит остатка.
    @LenientDouble var daysCover: Double?
    @LenientString var orderBy: String?
    @LenientDecimal var qtyRecommended: Decimal?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var amount: Decimal?
    @LenientBool var priceKnown: Bool?
    var supplier: ReplLineSupplier?
    @LenientString var confidenceLabel: String?
    @LenientBool var selected: Bool?
    var flags: ReplFlags?
    var explain: ReplExplain?

    enum CodingKeys: String, CodingKey {
        case kind, name, article, unit, status, stock, qty, price, amount, supplier, selected, flags, explain
        case avgDaily = "avg_daily"
        case itemId = "id"
        case inTransit = "in_transit"
        case daysCover = "days_cover"
        case orderBy = "order_by"
        case qtyRecommended = "qty_recommended"
        case priceKnown = "price_known"
        case confidenceLabel = "confidence_label"
    }

    /// Ключ строки для exclude и для списков: "goods:12".
    var key: String { (kind ?? "goods") + ":\(itemId ?? 0)" }
    var id: String { key }

    init(from decoder: Decoder) throws {
        let d = try decoder.container(keyedBy: CodingKeys.self)
        _kind = try d.decode(LenientString.self, forKey: .kind)
        _itemId = try d.decode(LenientInt.self, forKey: .itemId)
        _name = try d.decode(LenientString.self, forKey: .name)
        _article = try d.decode(LenientString.self, forKey: .article)
        _unit = try d.decode(LenientString.self, forKey: .unit)
        _status = try d.decode(LenientString.self, forKey: .status)
        _stock = try d.decode(LenientDecimal.self, forKey: .stock)
        _inTransit = try d.decode(LenientDecimal.self, forKey: .inTransit)
        _avgDaily = try d.decode(LenientDecimal.self, forKey: .avgDaily)
        _daysCover = try d.decode(LenientDouble.self, forKey: .daysCover)
        _orderBy = try d.decode(LenientString.self, forKey: .orderBy)
        _qtyRecommended = try d.decode(LenientDecimal.self, forKey: .qtyRecommended)
        _qty = try d.decode(LenientDecimal.self, forKey: .qty)
        _price = try d.decode(LenientDecimal.self, forKey: .price)
        _amount = try d.decode(LenientDecimal.self, forKey: .amount)
        _priceKnown = try d.decode(LenientBool.self, forKey: .priceKnown)
        supplier = d.tol(ReplLineSupplier.self, .supplier)
        _confidenceLabel = try d.decode(LenientString.self, forKey: .confidenceLabel)
        _selected = try d.decode(LenientBool.self, forKey: .selected)
        flags = d.tol(ReplFlags.self, .flags)
        explain = d.tol(ReplExplain.self, .explain)
    }
}

/// params плана: нужен только бюджет — строка "0.00" или null.
struct ReplParams: Decodable {
    @LenientDecimal var budget: Decimal?
    enum CodingKeys: String, CodingKey { case budget }
}

struct ReplPlan: Decodable {
    @LenientString var horizon: String?
    var summary: ReplSummary?
    var suppliers: [ReplGroup] = []
    var lines: [ReplLine] = []
    @LenientInt var total: Int?
    var params: ReplParams?
    var status: ReplStatus?
    @LenientInt var staleLines: Int?

    enum CodingKeys: String, CodingKey {
        case horizon, summary, suppliers, lines, total, params, status
        case staleLines = "stale_lines"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _horizon = try c.decode(LenientString.self, forKey: .horizon)
        summary = c.tol(ReplSummary.self, .summary)
        suppliers = c.tolList(ReplGroup.self, .suppliers)
        lines = c.tolList(ReplLine.self, .lines)
        _total = try c.decode(LenientInt.self, forKey: .total)
        params = c.tol(ReplParams.self, .params)
        status = c.tol(ReplStatus.self, .status)
        _staleLines = try c.decode(LenientInt.self, forKey: .staleLines)
    }
}

// ── Итог «Создать заказы» ─────────────────────────────────────────────────────

struct ReplCreated: Decodable {
    @LenientInt var supplierId: Int?
    @LenientInt var poId: Int?
    @LenientString var number: String?
    @LenientDecimal var amount: Decimal?
    @LenientInt var lines: Int?

    enum CodingKeys: String, CodingKey {
        case number, amount, lines
        case supplierId = "supplier_id"
        case poId = "po_id"
    }
}

struct ReplSkipped: Decodable {
    @LenientString var kind: String?
    @LenientInt var itemId: Int?
    @LenientString var reason: String?

    enum CodingKeys: String, CodingKey {
        case kind, reason
        case itemId = "id"
    }
}

struct ReplFailed: Decodable {
    @LenientInt var supplierId: Int?
    @LenientString var error: String?

    enum CodingKeys: String, CodingKey {
        case error
        case supplierId = "supplier_id"
    }
}

/// Ответ POST /plan/create-orders. reused[] — те же поля без lines.
struct ReplOrdersResult: Decodable {
    var created: [ReplCreated] = []
    var reused: [ReplCreated] = []
    var skipped: [ReplSkipped] = []
    var failed: [ReplFailed] = []

    enum CodingKeys: String, CodingKey { case created, reused, skipped, failed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created = c.tolList(ReplCreated.self, .created)
        reused = c.tolList(ReplCreated.self, .reused)
        skipped = c.tolList(ReplSkipped.self, .skipped)
        failed = c.tolList(ReplFailed.self, .failed)
    }
}
