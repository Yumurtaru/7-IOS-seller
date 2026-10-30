import Foundation

// ============================================================================
//  Models+Phase3.swift — DTO Фазы 3, выведены 1:1 из PHP-роутов:
//   • склад/остатки/партии/сроки/отчёты — routes/seller_warehouse.php
//     + routes/seller_warehouse_reports.php (reorder, writeoff-analytics).
//     /warehouse/valuation и /warehouse/analytics обслуживает
//     seller_warehouse_reports.php (простые дубли в seller_warehouse.php
//     отключены на сервере) — модели ниже соответствуют именно им.
//   • поставщики/закупки/прайсы        — routes/seller_purchase.php
//   • доставка/зоны/тарифы/KYC         — routes/seller_settings.php
//   • курьеры                          — routes/seller_couriers.php (конверт
//     обычный Response::ok, несмотря на путь /api/v1/…)
//   • безопасность (журнал/алерты)     — routes/seller_security.php
//   • столы / станции / тех-карты      — routes/tables.php, stations.php,
//     seller_warehouse.php (tech-cards)
//  Правила прежние: деньги/DECIMAL — @LenientDecimal, флаги 0/1 — @LenientBool,
//  счётчики — @LenientInt, имена полей через CodingKeys 1:1.
// ============================================================================

// ── Строка, которая может прийти числом (station_number, номер стола) ────────
@propertyWrapper
struct LenientString: Codable, Hashable {
    var wrappedValue: String?
    init(wrappedValue: String?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let s = try? c.decode(String.self) { wrappedValue = s }
        else if let i = try? c.decode(Int.self) { wrappedValue = String(i) }
        else if let d = try? c.decode(Double.self) { wrappedValue = String(d) }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

// ── meta журнала безопасности: произвольный JSON-объект → [String: String] ───
@propertyWrapper
struct LenientStringMap: Decodable {
    var wrappedValue: [String: String]
    init(wrappedValue: [String: String] = [:]) { self.wrappedValue = wrappedValue }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        var out: [String: String] = [:]
        if let c = try? decoder.container(keyedBy: AnyKey.self) {
            for key in c.allKeys {
                if let s = try? c.decode(String.self, forKey: key) { out[key.stringValue] = s }
                else if let i = try? c.decode(Int.self, forKey: key) { out[key.stringValue] = String(i) }
                else if let d = try? c.decode(Double.self, forKey: key) { out[key.stringValue] = String(d) }
                else if let b = try? c.decode(Bool.self, forKey: key) { out[key.stringValue] = b ? "1" : "0" }
            }
        }
        wrappedValue = out
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: LenientString.Type, forKey key: Key) throws -> LenientString {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientString(wrappedValue: nil)
    }
    func decode(_ type: LenientStringMap.Type, forKey key: Key) throws -> LenientStringMap {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientStringMap(wrappedValue: [:])
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  СКЛАД
// ════════════════════════════════════════════════════════════════════════════

/// GET /api/seller/warehouses — warehouses.{id,name,is_default,address}.
struct WarehouseInfo: Decodable, Identifiable, Hashable {
    @LenientInt var id: Int?
    var name: String?
    @LenientBool var isDefault: Bool?
    var address: String?

    enum CodingKeys: String, CodingKey {
        case id, name, address
        case isDefault = "is_default"
    }
    var warehouseId: Int { id ?? 0 }
}

/// GET /api/seller/warehouse/settings — {auto_writeoff: bool}.
struct WarehouseSettingsData: Decodable {
    @LenientBool var autoWriteoff: Bool?
    enum CodingKeys: String, CodingKey { case autoWriteoff = "auto_writeoff" }
}

/// GET /api/seller/stock — bare array; товары и ингредиенты в одном списке.
/// Товар: {…, stock_min, kind:"product", min_qty(=stock_min)};
/// ингредиент: {…, min_qty, price_per_unit, kind:"ingredient", stock_min(=min_qty)}.
struct StockItem: Decodable, Identifiable {
    @LenientInt var itemId: Int?
    var name: String?
    var article: String?
    var barcode: String?
    var unit: String?
    @LenientDecimal var stockQty: Decimal?
    @LenientDecimal var stockMin: Decimal?
    @LenientDecimal var minQty: Decimal?
    @LenientDecimal var pricePerUnit: Decimal?
    var kind: String?               // product | ingredient

    enum CodingKeys: String, CodingKey {
        case name, article, barcode, unit, kind
        case itemId = "id"
        case stockQty = "stock_qty"
        case stockMin = "stock_min"
        case minQty = "min_qty"
        case pricePerUnit = "price_per_unit"
    }
    var id: String { (kind ?? "?") + "-\(itemId ?? 0)" }
    /// Единый порог минимума (сервер дублирует поле для обоих видов).
    var minimum: Decimal { stockMin ?? minQty ?? 0 }
    var isLow: Bool { minimum > 0 && (stockQty ?? 0) <= minimum }
}

/// GET /api/seller/stock/search — позиции для строки документа/прайса.
struct StockSearchItem: Decodable, Identifiable {
    @LenientInt var itemId: Int?
    var name: String?
    var article: String?
    var barcode: String?
    var unit: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var pricePerUnit: Decimal?
    var kind: String?
    /// Учётный остаток (по складу из warehouse_id, иначе общий) — сервер
    /// отдаёт его в поиске для строки инвентаризации («По учёту»).
    @LenientDecimal var stockQty: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, article, barcode, unit, price, kind
        case itemId = "id"
        case pricePerUnit = "price_per_unit"
        case stockQty = "stock_qty"
    }
    var id: String { (kind ?? "?") + "-\(itemId ?? 0)" }
    var anyPrice: Decimal? { price ?? pricePerUnit }
}

/// GET /api/seller/warehouse/position/{kind}/{id}/batches — партии (FEFO).
struct StockBatch: Decodable, Identifiable {
    @LenientInt var batchId: Int?
    @LenientInt var warehouseId: Int?
    var warehouse: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var cost: Decimal?
    var expiresAt: String?
    var receivedAt: String?
    @LenientInt var daysLeft: Int?

    enum CodingKeys: String, CodingKey {
        case warehouse, qty, cost
        case batchId = "id"
        case warehouseId = "warehouse_id"
        case expiresAt = "expires_at"
        case receivedAt = "received_at"
        case daysLeft = "days_left"
    }
    var id: Int { batchId ?? 0 }
}

/// GET /api/seller/warehouse/position/{kind}/{id}/balances — остаток по складам.
struct WarehouseBalance: Decodable, Identifiable {
    @LenientInt var warehouseId: Int?
    var name: String?
    @LenientBool var isDefault: Bool?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var avgCost: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, qty
        case warehouseId = "warehouse_id"
        case isDefault = "is_default"
        case avgCost = "avg_cost"
    }
    var id: Int { warehouseId ?? 0 }
}

/// GET /api/seller/warehouse/expiry — {items, summary}.
struct ExpiryReport: Decodable {
    var items: [ExpiryBatch]?
    var summary: ExpirySummary?
}

struct ExpiryBatch: Decodable, Identifiable {
    @LenientInt var batchId: Int?
    @LenientInt var warehouseId: Int?
    var warehouse: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var cost: Decimal?
    var expiresAt: String?
    var receivedAt: String?
    @LenientInt var daysLeft: Int?
    var name: String?
    var unit: String?
    var kind: String?
    @LenientInt var positionId: Int?
    @LenientBool var expired: Bool?

    enum CodingKeys: String, CodingKey {
        case warehouse, qty, cost, name, unit, kind, expired
        case batchId = "id"
        case warehouseId = "warehouse_id"
        case expiresAt = "expires_at"
        case receivedAt = "received_at"
        case daysLeft = "days_left"
        case positionId = "position_id"
    }
    var id: Int { batchId ?? 0 }
}

struct ExpirySummary: Decodable {
    @LenientInt var days: Int?
    @LenientInt var expired: Int?
    @LenientInt var soon: Int?
    @LenientDecimal var atRiskValue: Decimal?
    enum CodingKeys: String, CodingKey {
        case days, expired, soon
        case atRiskValue = "at_risk_value"
    }
}

/// GET /api/seller/warehouse/valuation?q= (обработчик seller_warehouse_reports.php):
/// {items:[{kind,id,name,unit,category,stock_qty,stock_min,cost,cost_source,price,
///          cost_value,retail_value,margin}],
///  totals:{cost_value,retail_value,qty_positions,margin}, by_category:[{category,cost_value}]}.
struct ValuationReport: Decodable {
    var items: [ValuationRow]?
    var totals: ValuationTotals?
    var byCategory: [ValuationCategory]?
    /// Сервер отдаёт не все позиции: shown из total_positions, has_more — есть ещё.
    @LenientInt var totalPositions: Int?
    @LenientInt var shown: Int?
    @LenientBool var hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case items, totals, shown
        case byCategory = "by_category"
        case totalPositions = "total_positions"
        case hasMore = "has_more"
    }
    /// Себестоимость всего остатка. Прежний обработчик отдавал её полем total —
    /// экраны продолжают читать .total, значение берётся из totals.cost_value.
    var total: Decimal? { totals?.costValue }
}

struct ValuationTotals: Decodable {
    @LenientDecimal var costValue: Decimal?
    @LenientDecimal var retailValue: Decimal?
    @LenientInt var qtyPositions: Int?
    @LenientDecimal var margin: Decimal?

    enum CodingKeys: String, CodingKey {
        case margin
        case costValue = "cost_value"
        case retailValue = "retail_value"
        case qtyPositions = "qty_positions"
    }
}

struct ValuationCategory: Decodable, Identifiable {
    var category: String?
    @LenientDecimal var costValue: Decimal?
    enum CodingKeys: String, CodingKey {
        case category
        case costValue = "cost_value"
    }
    var id: String { category ?? "—" }
}

struct ValuationRow: Decodable, Identifiable {
    @LenientInt var positionId: Int?
    var kind: String?
    var name: String?
    var unit: String?
    var category: String?
    @LenientDecimal var qty: Decimal?         // остаток (на сервере stock_qty)
    @LenientDecimal var avgCost: Decimal?     // себестоимость единицы (cost)
    @LenientDecimal var price: Decimal?
    @LenientDecimal var value: Decimal?       // остаток × себестоимость (cost_value)
    @LenientDecimal var retailValue: Decimal?
    @LenientDecimal var margin: Decimal?

    // Имена свойств оставлены прежними (qty/avgCost/value), а ключи переведены
    // на те, что реально приходят с сервера: старые qty/avg_cost/value давал
    // отключённый обработчик, и список позиций из-за этого выходил пустым.
    enum CodingKeys: String, CodingKey {
        case kind, name, unit, category, price, margin
        case positionId = "id"
        case qty = "stock_qty"
        case avgCost = "cost"
        case value = "cost_value"
        case retailValue = "retail_value"
    }
    var id: String { (kind ?? "?") + "-\(positionId ?? 0)" }
}

/// GET /api/seller/warehouse/analytics?days= (seller_warehouse_reports.php —
/// оборачиваемость, ABC, неликвиды по товарам):
/// {items:[{id,name,article,unit,stock_qty,sold_qty,revenue,profit,avg_daily,
///          days_cover,turnover,dead,abc}], summary:{days,positions,revenue,profit,dead_count,a_count}}.
struct WarehouseAnalytics: Decodable {
    var items: [TurnoverRow]?
    var summary: TurnoverSummary?

    // Поля прежнего обработчика (обороты по документам). Сервер их больше не
    // отдаёт; оставлены опциональными, чтобы экраны, которые их читают,
    // собирались без правок — так же сделано в приложении на Android.
    @LenientInt var days: Int?
    var byType: [DocTypeStat]?
    var writeoffReasons: [WriteoffReason]?
    var topReceived: [ReceivedTopRow]?
    @LenientDecimal var stockValue: Decimal?

    enum CodingKeys: String, CodingKey {
        case items, summary, days
        case byType = "by_type"
        case writeoffReasons = "writeoff_reasons"
        case topReceived = "top_received"
        case stockValue = "stock_value"
    }
}

struct TurnoverSummary: Decodable {
    @LenientInt var days: Int?
    @LenientInt var positions: Int?
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var profit: Decimal?
    @LenientInt var deadCount: Int?
    @LenientInt var aCount: Int?

    enum CodingKeys: String, CodingKey {
        case days, positions, revenue, profit
        case deadCount = "dead_count"
        case aCount = "a_count"
    }
}

struct TurnoverRow: Decodable, Identifiable {
    @LenientInt var positionId: Int?
    var name: String?
    var unit: String?
    @LenientDecimal var stockQty: Decimal?
    @LenientDecimal var soldQty: Decimal?
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var profit: Decimal?
    @LenientDecimal var daysCover: Decimal?   // null — продаж не было
    @LenientDecimal var turnover: Decimal?
    @LenientBool var dead: Bool?
    var abc: String?                          // A | B | C | D (неликвид)

    enum CodingKeys: String, CodingKey {
        case name, unit, revenue, profit, turnover, dead, abc
        case positionId = "id"
        case stockQty = "stock_qty"
        case soldQty = "sold_qty"
        case daysCover = "days_cover"
    }
    var id: Int { positionId ?? 0 }
}

struct DocTypeStat: Decodable, Identifiable {
    var type: String?               // income | expense | move | inventory | return_supplier
    @LenientInt var cnt: Int?
    @LenientDecimal var amount: Decimal?
    var id: String { type ?? UUID().uuidString }
}

struct WriteoffReason: Decodable, Identifiable {
    var reason: String?             // spoilage | breakage | shortage | test | sale | other
    @LenientInt var cnt: Int?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var amount: Decimal?
    var id: String { reason ?? UUID().uuidString }
}

struct ReceivedTopRow: Decodable, Identifiable {
    var name: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var amount: Decimal?
    var id: String { name ?? UUID().uuidString }
}

/// GET /api/seller/warehouse/writeoff-analytics?days= — {days, total, by_reason, top_items}.
struct WriteoffAnalytics: Decodable {
    @LenientInt var days: Int?
    @LenientDecimal var total: Decimal?
    var byReason: [WriteoffReason]?
    var topItems: [WriteoffTopItem]?

    enum CodingKeys: String, CodingKey {
        case days, total
        case byReason = "by_reason"
        case topItems = "top_items"
    }
}

struct WriteoffTopItem: Decodable, Identifiable {
    var name: String?
    var unit: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var amount: Decimal?
    var id: String { (name ?? "") + (unit ?? "") }
}

/// GET /api/seller/warehouse/reorder?lead=&days= — «что закупить».
struct ReorderReport: Decodable {
    var items: [ReorderRow]?
    @LenientInt var lead: Int?
    @LenientInt var days: Int?
    @LenientInt var count: Int?
}

struct ReorderRow: Decodable, Identifiable {
    var kind: String?
    @LenientInt var itemId: Int?
    var name: String?
    var article: String?
    var unit: String?
    @LenientDecimal var stockQty: Decimal?
    @LenientDecimal var stockMin: Decimal?
    @LenientDecimal var avgDaily: Decimal?
    @LenientDecimal var recommend: Decimal?
    @LenientBool var belowMin: Bool?
    var supplier: String?
    /// АY (сайт А616): заказано у поставщиков и ещё не принято; id последнего
    /// поставщика; остаток ушёл в минус. Старый сервер — nil.
    @LenientDecimal var inTransit: Decimal?
    @LenientInt var supplierId: Int?
    @LenientBool var negative: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, name, article, unit, supplier, recommend, negative
        case itemId = "id"
        case stockQty = "stock_qty"
        case stockMin = "stock_min"
        case avgDaily = "avg_daily"
        case belowMin = "below_min"
        case inTransit = "in_transit"
        case supplierId = "supplier_id"
    }
    var id: String { (kind ?? "?") + "-\(itemId ?? 0)" }
}

// ════════════════════════════════════════════════════════════════════════════
//  ПОСТАВЩИКИ И ЗАКУПКИ (routes/seller_warehouse.php + seller_purchase.php)
// ════════════════════════════════════════════════════════════════════════════

/// GET /api/seller/suppliers — SELECT * FROM suppliers.
struct Supplier: Decodable, Identifiable {
    @LenientInt var supplierId: Int?
    var name: String?
    var phone: String?
    var email: String?
    var inn: String?
    var address: String?
    var comment: String?
    @LenientBool var isActive: Bool?
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case name, phone, email, inn, address, comment
        case supplierId = "id"
        case isActive = "is_active"
        case createdAt = "created_at"
    }
    var id: Int { supplierId ?? 0 }
}

/// GET /api/seller/suppliers/{id} — suppliers.* + deliveries + stats.
struct SupplierDetail: Decodable {
    @LenientInt var supplierId: Int?
    var name: String?
    var phone: String?
    var email: String?
    var inn: String?
    var address: String?
    var comment: String?
    @LenientBool var isActive: Bool?
    var createdAt: String?
    var deliveries: [SupplierDelivery]?
    var stats: SupplierStats?

    enum CodingKeys: String, CodingKey {
        case name, phone, email, inn, address, comment, deliveries, stats
        case supplierId = "id"
        case isActive = "is_active"
        case createdAt = "created_at"
    }
}

struct SupplierDelivery: Decodable, Identifiable {
    @LenientInt var docId: Int?
    var number: String?
    var type: String?
    var status: String?             // draft | posted | cancelled
    var postedAt: String?
    var createdAt: String?
    @LenientDecimal var totalAmount: Decimal?

    enum CodingKeys: String, CodingKey {
        case number, type, status
        case docId = "id"
        case postedAt = "posted_at"
        case createdAt = "created_at"
        case totalAmount = "total_amount"
    }
    var id: Int { docId ?? 0 }
}

struct SupplierStats: Decodable {
    @LenientInt var cnt: Int?
    @LenientDecimal var turnover: Decimal?
    var lastAt: String?
    enum CodingKeys: String, CodingKey {
        case cnt, turnover
        case lastAt = "last_at"
    }
}

/// GET /api/seller/suppliers/{id}/prices — прайс-лист поставщика.
struct SupplierPrice: Decodable, Identifiable {
    @LenientInt var priceId: Int?
    var supplierSku: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var packQty: Decimal?
    var kind: String?
    @LenientInt var positionId: Int?
    var name: String?
    var unit: String?

    enum CodingKeys: String, CodingKey {
        case price, kind, name, unit
        case priceId = "id"
        case supplierSku = "supplier_sku"
        case packQty = "pack_qty"
        case positionId = "position_id"
    }
    var id: Int { priceId ?? 0 }
}

/// GET /api/seller/purchase-orders — список заказов поставщику.
struct PurchaseOrderSummary: Decodable, Identifiable {
    @LenientInt var poId: Int?
    var number: String?
    var status: String?             // draft | sent | received | cancelled
    @LenientDecimal var totalAmount: Decimal?
    var comment: String?
    var createdAt: String?
    var sentAt: String?
    var receivedAt: String?
    @LenientInt var incomeDocumentId: Int?
    var supplier: String?
    var warehouse: String?

    enum CodingKeys: String, CodingKey {
        case number, status, comment, supplier, warehouse
        case poId = "id"
        case totalAmount = "total_amount"
        case createdAt = "created_at"
        case sentAt = "sent_at"
        case receivedAt = "received_at"
        case incomeDocumentId = "income_document_id"
    }
    var id: Int { poId ?? 0 }
}

/// GET /api/seller/purchase-orders/{id} — purchase_orders.* + items.
struct PurchaseOrderDetail: Decodable {
    @LenientInt var poId: Int?
    @LenientInt var supplierId: Int?
    @LenientInt var warehouseId: Int?
    var number: String?
    var status: String?
    var comment: String?
    @LenientDecimal var totalAmount: Decimal?
    var createdAt: String?
    var sentAt: String?
    var receivedAt: String?
    @LenientInt var incomeDocumentId: Int?
    /// А60/П-23.11: статус документа прихода ("draft" — принят, но не проведён).
    /// Нет поля (старый сервер) — nil, кнопки «Провести приход» нет.
    @LenientString var incomeDocumentStatus: String?
    var items: [PurchaseOrderItem]?
    /// П-28.12: названия поставщика и склада (строка|null). Старый сервер их не
    /// шлёт — nil, имя поставщика берётся из строки списка, как раньше.
    @LenientString var supplierName: String?
    @LenientString var warehouseName: String?

    enum CodingKeys: String, CodingKey {
        case number, status, comment, items
        case supplierName = "supplier"
        case warehouseName = "warehouse"
        case poId = "id"
        case supplierId = "supplier_id"
        case warehouseId = "warehouse_id"
        case totalAmount = "total_amount"
        case createdAt = "created_at"
        case sentAt = "sent_at"
        case receivedAt = "received_at"
        case incomeDocumentId = "income_document_id"
        case incomeDocumentStatus = "income_document_status"
    }
}

struct PurchaseOrderItem: Decodable, Identifiable {
    @LenientInt var poiId: Int?
    @LenientInt var productId: Int?
    @LenientInt var ingredientId: Int?
    var name: String?
    var unit: String?
    var article: String?
    @LenientDecimal var qtyOrdered: Decimal?
    @LenientDecimal var qtyReceived: Decimal?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var amount: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, unit, article, price, amount
        case poiId = "id"
        case productId = "product_id"
        case ingredientId = "ingredient_id"
        case qtyOrdered = "qty_ordered"
        case qtyReceived = "qty_received"
    }
    var id: Int { poiId ?? 0 }
    var remaining: Decimal { max((qtyOrdered ?? 0) - (qtyReceived ?? 0), 0) }
    var kind: String { productId != nil && productId != 0 ? "product" : "ingredient" }
}

/// POST /api/seller/purchase-orders/{id}/receive → {income_document_id, fully_received}.
struct ReceiveAck: Decodable {
    @LenientInt var incomeDocumentId: Int?
    @LenientBool var fullyReceived: Bool?
    /// Сколько строк заказа принять не удалось (позиция удалена из справочника) —
    /// seller_purchase.php отдаёт broken_items, чтобы объяснить, почему заказ не закрылся.
    @LenientInt var brokenItems: Int?
    enum CodingKeys: String, CodingKey {
        case incomeDocumentId = "income_document_id"
        case fullyReceived = "fully_received"
        case brokenItems = "broken_items"
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  ДОСТАВКА: способы, зоны, курьеры
// ════════════════════════════════════════════════════════════════════════════

/// GET /api/seller/settings/delivery — {methods, zones, map_center}.
struct DeliverySettings: Decodable {
    var methods: [DeliveryMethod]?
    var zones: [DeliveryZone]?
    var mapCenter: MapCenter?
    enum CodingKeys: String, CodingKey {
        case methods, zones
        case mapCenter = "map_center"
    }
}

struct DeliveryMethod: Decodable, Identifiable {
    var type: String?               // delivery | pickup | dine_in
    @LenientBool var isEnabled: Bool?
    var pickupAddress: String?
    @LenientDecimal var pickupLat: Decimal?
    @LenientDecimal var pickupLng: Decimal?
    var pickupComment: String?
    @LenientBool var dineInTableRequired: Bool?
    /// Фиксированная цена доставки (поля ответа GET settings/delivery). В
    /// приложении не правятся — только передаются обратно при сохранении способа.
    @LenientDecimal var flatPrice: Decimal?
    @LenientDecimal var flatFreeFrom: Decimal?
    @LenientDecimal var flatMinOrder: Decimal?
    @LenientInt var flatTimeMin: Int?
    @LenientInt var flatTimeMax: Int?
    @LenientBool var flatCityOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case isEnabled = "is_enabled"
        case pickupAddress = "pickup_address"
        case pickupLat = "pickup_lat"
        case pickupLng = "pickup_lng"
        case pickupComment = "pickup_comment"
        case dineInTableRequired = "dine_in_table_required"
        case flatPrice = "flat_price"
        case flatFreeFrom = "flat_free_from"
        case flatMinOrder = "flat_min_order"
        case flatTimeMin = "flat_time_min"
        case flatTimeMax = "flat_time_max"
        case flatCityOnly = "flat_city_only"
    }
    var id: String { type ?? UUID().uuidString }
}

/// delivery_zones.* (SELECT *): pro-колонки (priority/цвета) — после миграции.
struct DeliveryZone: Decodable, Identifiable {
    @LenientInt var zoneId: Int?
    var name: String?
    var polygonJson: String?
    @LenientDecimal var deliveryPrice: Decimal?
    @LenientDecimal var minOrder: Decimal?
    @LenientDecimal var freeFrom: Decimal?
    @LenientInt var deliveryTimeMin: Int?
    @LenientInt var deliveryTimeMax: Int?
    @LenientBool var isActive: Bool?
    @LenientInt var priority: Int?
    @LenientBool var isExcluded: Bool?
    var fillColor: String?
    var strokeColor: String?
    @LenientDecimal var fillOpacity: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, priority
        case zoneId = "id"
        case polygonJson = "polygon_json"
        case deliveryPrice = "delivery_price"
        case minOrder = "min_order"
        case freeFrom = "free_from"
        case deliveryTimeMin = "delivery_time_min"
        case deliveryTimeMax = "delivery_time_max"
        case isActive = "is_active"
        case isExcluded = "is_excluded"
        case fillColor = "fill_color"
        case strokeColor = "stroke_color"
        case fillOpacity = "fill_opacity"
    }
    var id: Int { zoneId ?? 0 }
    /// Число вершин полигона (полигоны рисует веб — тут только просмотр).
    var polygonPointsCount: Int {
        guard let raw = polygonJson, let data = raw.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
        return arr.count
    }
    /// Полигон как есть (разобранный polygon_json). В PUT зоны больше не уходит:
    /// сервер меняет только присланные ключи.
    var polygonRaw: Any {
        guard let raw = polygonJson, let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [Any]() }
        return obj
    }
}

struct MapCenter: Decodable {
    @LenientDecimal var lat: Decimal?
    @LenientDecimal var lng: Decimal?
    @LenientInt var zoom: Int?
    var source: String?
    var city: String?
    var region: String?
}

/// GET /api/v1/seller/couriers (конверт обычный {ok,data}).
struct Courier: Decodable, Identifiable {
    @LenientInt var courierId: Int?
    var name: String?
    var phone: String?
    var status: String?             // active | blocked
    var permissions: [String]?
    @LenientInt var activeOrders: Int?
    /// Аккаунт курьера заведён этим магазином (seller_couriers.php, account_owned).
    /// Только у таких можно менять имя и пароль. Старый сервер — nil.
    @LenientBool var accountOwned: Bool?

    enum CodingKeys: String, CodingKey {
        case name, phone, status, permissions
        case courierId = "id"
        case activeOrders = "active_orders"
        case accountOwned = "account_owned"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _courierId = try c.decode(LenientInt.self, forKey: .courierId)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        phone = try? c.decodeIfPresent(String.self, forKey: .phone)
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        permissions = (try? c.decodeIfPresent([String].self, forKey: .permissions)) ?? []
        _activeOrders = try c.decode(LenientInt.self, forKey: .activeOrders)
        _accountOwned = try c.decode(LenientBool.self, forKey: .accountOwned)
    }
    var id: Int { courierId ?? 0 }
}

/// POST /api/v1/seller/couriers → {id, phone, login, created, notice}.
/// created=false + notice — у номера уже был аккаунт Yumurta: курьер входит
/// СВОИМ паролем, введённый продавцом пароль не применился.
struct CourierCreateAck: Decodable {
    @LenientInt var id: Int?
    var phone: String?
    var login: String?
    @LenientBool var created: Bool?
    var notice: String?
}

/// PUT /api/v1/seller/couriers/{id} → {updated, name_skipped}. name_skipped —
/// имя не сменено: аккаунт курьера заведён не магазином.
struct CourierUpdateAck: Decodable {
    @LenientBool var nameSkipped: Bool?
    enum CodingKeys: String, CodingKey { case nameSkipped = "name_skipped" }
}

/// Каталог прав курьера — зеркало courierPermLabels() на сервере.
enum CourierPerms {
    static let all = ["take_order", "pickup", "deliver", "accept_cash", "view_phone", "navigate"]
    // view_phone входит в набор по умолчанию: без телефона клиента курьер не
    // может позвонить у подъезда. Снятая галочка теперь действительно скрывает
    // номер (на сервере право наконец проверяется).
    static let defaults = ["take_order", "pickup", "deliver", "accept_cash", "view_phone", "navigate"]
    /// Метка «список прав полный, верь ему»: без неё сервер считает отсутствие
    /// view_phone незнанием старой сборки, а не запретом.
    static let listMarker = "pv2"
    static func label(_ code: String) -> String {
        switch code {
        case "take_order": return "Брать заказы"
        case "pickup": return "Отметка «забрал»"
        case "deliver": return "Отметка «доставлено»"
        case "accept_cash": return "Принимать оплату наличными"
        case "view_phone": return "Видеть телефон клиента"
        case "navigate": return "Навигация / маршрут"
        default: return code
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  БЕЗОПАСНОСТЬ (routes/seller_security.php)
// ════════════════════════════════════════════════════════════════════════════

/// GET /api/seller/security/feed — {items, labels, enabled, has_more, next_before_id}.
/// А320: по 300 записей; has_more и next_before_id (→ ?before_id=) — следующая
/// страница. Старый сервер их не шлёт — nil, листания с сервера нет.
struct SecurityFeed: Decodable {
    var items: [AuditEntry]?
    var labels: [String: String]?
    @LenientBool var enabled: Bool?
    @LenientBool var hasMore: Bool?
    @LenientInt var nextBeforeId: Int?

    enum CodingKeys: String, CodingKey {
        case items, labels, enabled
        case hasMore = "has_more"
        case nextBeforeId = "next_before_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([AuditEntry].self, forKey: .items)) ?? []
        labels = (try? c.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
        _enabled = try c.decode(LenientBool.self, forKey: .enabled)
        _hasMore = try c.decode(LenientBool.self, forKey: .hasMore)
        _nextBeforeId = try c.decode(LenientInt.self, forKey: .nextBeforeId)
    }
}

struct AuditEntry: Decodable, Identifiable {
    @LenientInt var entryId: Int?
    var actorType: String?          // seller | staff | station | courier
    @LenientInt var actorId: Int?
    var actorName: String?
    var action: String?
    var entityType: String?
    @LenientInt var entityId: Int?
    @LenientDecimal var amount: Decimal?
    var severity: String?           // info | warning | critical
    @LenientStringMap var meta: [String: String]
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case action, severity, meta
        case entryId = "id"
        case actorType = "actor_type"
        case actorId = "actor_id"
        case actorName = "actor_name"
        case entityType = "entity_type"
        case entityId = "entity_id"
        case amount
        case createdAt = "created_at"
    }
    var id: Int { entryId ?? 0 }
}

/// GET /api/seller/security/stats — {by_action, total}.
struct SecurityStats: Decodable {
    var byAction: [ActionStat]?
    @LenientInt var total: Int?
    enum CodingKeys: String, CodingKey {
        case total
        case byAction = "by_action"
    }
}

struct ActionStat: Decodable, Identifiable {
    var action: String?
    @LenientInt var cnt: Int?
    @LenientDecimal var amount: Decimal?
    var id: String { action ?? UUID().uuidString }
}

/// GET /api/seller/security/by_cashier — {rows} (SUM() MySQL приходит строками).
struct CashierRiskReport: Decodable {
    var rows: [CashierRiskRow]?
}

struct CashierRiskRow: Decodable, Identifiable {
    var actorName: String?
    @LenientInt var total: Int?
    @LenientInt var refunds: Int?
    @LenientDecimal var refundSum: Decimal?
    @LenientInt var cancels: Int?
    @LenientInt var voidPaid: Int?
    @LenientInt var discounts: Int?
    @LenientInt var qtyCuts: Int?
    @LenientInt var noSale: Int?
    @LenientInt var critical: Int?
    var lastAt: String?

    enum CodingKeys: String, CodingKey {
        case total, refunds, cancels, discounts, critical
        case actorName = "actor_name"
        case refundSum = "refund_sum"
        case voidPaid = "void_paid"
        case qtyCuts = "qty_cuts"
        case noSale = "no_sale"
        case lastAt = "last_at"
    }
    var id: String { actorName ?? UUID().uuidString }
}

/// GET /api/seller/security/alerts — {alerts, enabled}.
struct SecurityAlerts: Decodable {
    var alerts: [SecurityAlert]?
    @LenientBool var enabled: Bool?

    enum CodingKeys: String, CodingKey { case alerts, enabled }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alerts = (try? c.decodeIfPresent([SecurityAlert].self, forKey: .alerts)) ?? []
        _enabled = try c.decode(LenientBool.self, forKey: .enabled)
    }
}

struct SecurityAlert: Decodable, Identifiable {
    var severity: String?           // critical | warning
    var icon: String?               // ph-* (иконки веба — маппим на SF Symbols)
    var title: String?
    var detail: String?
    var when: String?
    var id: String { (title ?? "") + (detail ?? "") + (when ?? "") }
}

// ════════════════════════════════════════════════════════════════════════════
//  ТАРИФЫ (routes/seller_settings.php)
// ════════════════════════════════════════════════════════════════════════════

/// GET /api/seller/plans — {plans, current, enabled}.
struct PlansResponse: Decodable {
    var plans: [SubscriptionPlan]?
    @LenientInt var current: Int?
    /// Включены ли тарифы на площадке. Ключа может не быть — сервер старее
    /// приложения; тогда считаем, что включены, и экран работает как раньше.
    /// Пустой список при enabled = false означает «раздел отключён
    /// администратором», а не «планы не настроены» — это разные подписи.
    var enabled: Bool

    enum CodingKeys: String, CodingKey { case plans, current, enabled }

    // Инициализатор написан руками: у enabled нет значения в старых ответах, а
    // синтезированный декодер на отсутствующем ключе уронил бы весь ответ.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plans = (try? c.decodeIfPresent([SubscriptionPlan].self, forKey: .plans)) ?? nil
        _current = (try? c.decode(LenientInt.self, forKey: .current)) ?? LenientInt(wrappedValue: 0)
        let asBool = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
        let asInt = (try? c.decodeIfPresent(Int.self, forKey: .enabled)) ?? nil
        if let b = asBool { enabled = b }
        else if let i = asInt { enabled = i != 0 }
        else { enabled = true }
    }
}

struct SubscriptionPlan: Decodable, Identifiable {
    @LenientInt var planId: Int?
    var name: String?
    @LenientDecimal var priceMonthly: Decimal?
    @LenientDecimal var priceYearly: Decimal?
    @LenientInt var maxProducts: Int?
    @LenientDecimal var commissionDiscountPercent: Decimal?
    var features: [String]?

    enum CodingKeys: String, CodingKey {
        case name, features
        case planId = "id"
        case priceMonthly = "price_monthly"
        case priceYearly = "price_yearly"
        case maxProducts = "max_products"
        case commissionDiscountPercent = "commission_discount_percent"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _planId = try c.decode(LenientInt.self, forKey: .planId)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        _priceMonthly = try c.decode(LenientDecimal.self, forKey: .priceMonthly)
        _priceYearly = try c.decode(LenientDecimal.self, forKey: .priceYearly)
        _maxProducts = try c.decode(LenientInt.self, forKey: .maxProducts)
        _commissionDiscountPercent = try c.decode(LenientDecimal.self, forKey: .commissionDiscountPercent)
        // features_json может содержать не только строки — берём толерантно.
        features = (try? c.decodeIfPresent([String].self, forKey: .features)) ?? []
    }
    var id: Int { planId ?? 0 }
    /// Цена за год: серверная логика — price_yearly, иначе месячная ×12 со скидкой 20%.
    var effectiveYearly: Decimal {
        if let y = priceYearly, y > 0 { return y }
        return (priceMonthly ?? 0) * 12 * Decimal(string: "0.8")!
    }
}

struct PlanSelectAck: Decodable {
    @LenientBool var selected: Bool?
}

// ════════════════════════════════════════════════════════════════════════════
//  CAFE — просмотр: столы, станции, тех-карты
// ════════════════════════════════════════════════════════════════════════════

/// GET /api/seller/tables — restaurant_tables.
struct RestaurantTable: Decodable, Identifiable {
    @LenientInt var tableId: Int?
    @LenientString var number: String?
    @LenientInt var seats: Int?
    var zone: String?
    var qrToken: String?
    @LenientBool var isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case seats, zone, number
        case tableId = "id"
        case qrToken = "qr_token"
        case isActive = "is_active"
    }
    var id: Int { tableId ?? 0 }
}

/// GET /api/v1/seller/stations (конверт обычный {ok,data}).
struct StationAccount: Decodable, Identifiable {
    @LenientInt var stationId: Int?
    var type: String?               // kitchen | bar | kiosk | queue | picker | chef
    var login: String?
    var displayName: String?
    @LenientString var stationNumber: String?
    @LenientBool var isActive: Bool?
    var lastLoginAt: String?
    var permissions: [String]?
    @LenientBool var hasPin: Bool?

    enum CodingKeys: String, CodingKey {
        case type, login, permissions
        case stationId = "id"
        case displayName = "display_name"
        case stationNumber = "station_number"
        case isActive = "is_active"
        case lastLoginAt = "last_login_at"
        case hasPin = "has_pin"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _stationId = try c.decode(LenientInt.self, forKey: .stationId)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        login = try? c.decodeIfPresent(String.self, forKey: .login)
        displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        _stationNumber = try c.decode(LenientString.self, forKey: .stationNumber)
        _isActive = try c.decode(LenientBool.self, forKey: .isActive)
        lastLoginAt = try? c.decodeIfPresent(String.self, forKey: .lastLoginAt)
        permissions = (try? c.decodeIfPresent([String].self, forKey: .permissions)) ?? []
        _hasPin = try c.decode(LenientBool.self, forKey: .hasPin)
    }
    var id: Int { stationId ?? 0 }

    static func typeLabel(_ t: String?) -> String {
        switch t {
        case "kitchen": return "Кухня"
        case "bar": return "Бар"
        case "kiosk": return "Киоск"
        case "queue": return "Табло очереди"
        case "picker": return "Сборщик"
        case "chef": return "Шеф-экран"
        // Старый тип станции из прежней схемы (сервер ещё отдаёт 'cafe') и
        // незнакомые типы — по-русски, а не кодом.
        case "cafe": return "Станция кафе"
        default: return "Станция"
        }
    }
}

/// GET /api/v1/seller/stations/health — heartbeat касс (online = < 5 мин).
struct StationHealth: Decodable, Identifiable {
    @LenientInt var stationAccountId: Int?
    var stationName: String?
    var appVersion: String?
    var fnStatus: String?
    @LenientBool var shiftOpen: Bool?
    @LenientInt var deferredCount: Int?
    var lastError: String?
    var updatedAt: String?
    @LenientBool var online: Bool?

    enum CodingKeys: String, CodingKey {
        case online
        case stationAccountId = "station_account_id"
        case stationName = "station_name"
        case appVersion = "app_version"
        case fnStatus = "fn_status"
        case shiftOpen = "shift_open"
        case deferredCount = "deferred_count"
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }
    var id: String { "\(stationAccountId ?? 0)-" + (updatedAt ?? "") }
}

/// GET /api/seller/tech-cards/{type}/{eid} — {tech_card, items}.
/// tech_card = false (PHP DB::fetch), если карты нет — декодируем толерантно.
struct TechCardResponse: Decodable {
    var techCard: TechCard?
    var items: [TechCardItem]?

    enum CodingKeys: String, CodingKey {
        case items
        case techCard = "tech_card"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        techCard = try? c.decodeIfPresent(TechCard.self, forKey: .techCard)
        items = (try? c.decodeIfPresent([TechCardItem].self, forKey: .items)) ?? []
    }
    /// Себестоимость: Σ (чистый расход или брутто) × цена ингредиента — как на сервере.
    var cost: Decimal {
        (items ?? []).reduce(Decimal(0)) { acc, it in
            let qty = (it.qtyNet ?? 0) != 0 ? (it.qtyNet ?? 0) : (it.qtyGross ?? 0)
            return acc + qty * (it.pricePerUnit ?? 0)
        }
    }
}

struct TechCard: Decodable {
    @LenientInt var id: Int?
    var entityType: String?         // product | modifier
    @LenientInt var entityId: Int?
    @LenientDecimal var yieldWeight: Decimal?
    @LenientInt var portions: Int?
    @LenientInt var cookingTimeMin: Int?
    var process: String?
    var description: String?

    enum CodingKeys: String, CodingKey {
        case id, portions, process, description
        case entityType = "entity_type"
        case entityId = "entity_id"
        case yieldWeight = "yield_weight"
        case cookingTimeMin = "cooking_time_min"
    }
}

struct TechCardItem: Decodable, Identifiable {
    @LenientInt var itemId: Int?
    @LenientInt var ingredientId: Int?
    @LenientDecimal var qtyGross: Decimal?
    @LenientDecimal var qtyNet: Decimal?
    var name: String?
    var unit: String?
    @LenientDecimal var pricePerUnit: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, unit
        case itemId = "id"
        case ingredientId = "ingredient_id"
        case qtyGross = "qty_gross"
        case qtyNet = "qty_net"
        case pricePerUnit = "price_per_unit"
    }
    var id: Int { itemId ?? 0 }
}

/// GET /api/seller/tc-modifiers — модификаторы магазина для раздела тех-карт.
struct TCModifier: Decodable, Identifiable {
    @LenientInt var modifierId: Int?
    var name: String?
    @LenientDecimal var price: Decimal?
    @LenientInt var techCardId: Int?
    var groupName: String?
    var productName: String?

    enum CodingKeys: String, CodingKey {
        case name, price
        case modifierId = "id"
        case techCardId = "tech_card_id"
        case groupName = "group_name"
        case productName = "product_name"
    }
    var id: Int { modifierId ?? 0 }
}

// ════════════════════════════════════════════════════════════════════════════
//  KYC (GET /api/seller/kyc — чек-лист готовности магазина)
// ════════════════════════════════════════════════════════════════════════════

struct KycResponse: Decodable {
    var checks: [KycCheck]?
    @LenientInt var done: Int?
    @LenientInt var total: Int?
    @LenientInt var percent: Int?
    var shopStatus: String?

    enum CodingKeys: String, CodingKey {
        case checks, done, total, percent
        case shopStatus = "shop_status"
    }
}

struct KycCheck: Decodable, Identifiable {
    var key: String?
    var label: String?
    @LenientBool var done: Bool?
    var hint: String?
    var id: String { key ?? UUID().uuidString }
}

// ── Подписи Фазы 3 ───────────────────────────────────────────────────────────
enum PurchaseLabels {
    static func status(_ s: String?) -> String {
        switch s {
        case "draft": return "Черновик"
        case "sent": return "Отправлен"
        case "received": return "Принят"
        case "cancelled": return "Отменён"
        default: return s ?? "—"
        }
    }
}

enum WarehouseLabels {
    static func docType(_ t: String?) -> String {
        switch t {
        case "income": return "Приход"
        case "expense": return "Списание"
        case "move": return "Перемещение"
        case "inventory": return "Инвентаризация"
        case "return_supplier": return "Возврат поставщику"
        default: return t ?? "—"
        }
    }
    static func writeoffReason(_ r: String?) -> String {
        switch r {
        case "spoilage": return "Порча"
        // Те же подписи, что в выборе причины документа (DocWriteoffReason) и на
        // Android: в отчёте причина называлась иначе, чем при списании.
        case "breakage": return "Бой"
        case "shortage": return "Недостача"
        case "test": return "Проба"
        case "sale": return "Продажа"
        case "other", nil: return "Прочее"
        default: return r ?? "Прочее"
        }
    }
}

enum SecurityLabels {
    /// Иконки веба (ph-*) → SF Symbols.
    static func sfIcon(_ ph: String?) -> String {
        switch ph {
        case "ph-arrow-u-up-left": return "arrow.uturn.left.circle"
        case "ph-x-circle": return "xmark.circle"
        case "ph-moon": return "moon"
        case "ph-gift": return "gift"
        default: return "exclamationmark.shield"
        }
    }
}
