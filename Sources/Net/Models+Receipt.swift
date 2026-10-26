import Foundation

// ============================================================================
//  Волна А99: приёмка товара, наценка и переоценка (routes/seller_receipt.php).
//
//  Всё новое — необязательное. Старый сервер на эти ручки отвечает 404, у
//  сотрудника без права — 403: экраны молча прячут «было N ₽», наценку и
//  раздел «Переоценка», и приложение работает как раньше.
//
//  Деньги приходят строкой "0.00" (@LenientDecimal). Все поля терпимы к
//  отсутствию и null: разбор одного кривого поля не должен ронять список.
// ============================================================================

/// POST /api/seller/stock/price-info → сведения по позиции прихода.
struct PriceInfoItem: Decodable {
    let kind: String?
    @LenientInt var id: Int?
    @LenientString var name: String?
    @LenientString var unit: String?
    /// Текущая розничная цена товара (у ингредиента — null).
    @LenientDecimal var retail: Decimal?
    /// Цена задана вручную — приход её по категории не пересчитает.
    @LenientBool var retailManual: Bool?
    @LenientDecimal var stockQty: Decimal?
    @LenientString var category: String?
    /// Наценка категории, %; nil — у категории не задана.
    @LenientDecimal var markupPercent: Decimal?
    @LenientString var roundingMode: String?
    /// Последняя закупочная цена (проведённый приход); nil — приходов не было.
    @LenientDecimal var lastPrice: Decimal?
    @LenientString var lastAt: String?
    @LenientString var lastSupplier: String?
    @LenientInt var lastDocId: Int?
    /// Средняя себестоимость ингредиента.
    @LenientDecimal var avgCost: Decimal?

    var isProduct: Bool { (kind ?? "product") != "ingredient" }
    var key: String { (kind ?? "product") + ":\(id ?? 0)" }
    var last: Decimal? { (lastPrice ?? 0) > 0 ? lastPrice : nil }

    enum CodingKeys: String, CodingKey {
        case kind, id, name, unit, retail, category
        case retailManual = "retail_manual"
        case stockQty = "stock_qty"
        case markupPercent = "markup_percent"
        case roundingMode = "rounding_mode"
        case lastPrice = "last_price"
        case lastAt = "last_at"
        case lastSupplier = "last_supplier"
        case lastDocId = "last_doc_id"
        case avgCost = "avg_cost"
    }
}

struct PriceInfoResponse: Decodable {
    let items: [PriceInfoItem]?
    /// Режим магазина: shop | restaurant.
    @LenientString var mode: String?
    /// «Полный магазин»: приход ставит розничную цену по наценке.
    @LenientBool var retailOnIncome: Bool?
    /// Есть право «Менять цены».
    @LenientBool var mayPrice: Bool?

    enum CodingKeys: String, CodingKey {
        case items, mode
        case retailOnIncome = "retail_on_income"
        case mayPrice = "may_price"
    }
}

/// Правило переоценки, как его сохранил сервер ({mode, value, rounding}).
struct RevalRule: Decodable {
    @LenientString var mode: String?
    @LenientDecimal var value: Decimal?
    @LenientString var rounding: String?
}

/// Переоценка: строка списка и карточка (items — только в карточке).
struct Revaluation: Decodable, Identifiable {
    @LenientInt var revId: Int?
    @LenientString var number: String?
    /// draft | applied | cancelled
    @LenientString var status: String?
    @LenientString var statusLabel: String?
    @LenientString var basis: String?
    @LenientString var comment: String?
    let rule: RevalRule?
    @LenientInt var itemsCount: Int?
    @LenientDecimal var sumOld: Decimal?
    @LenientDecimal var sumNew: Decimal?
    @LenientString var appliedAt: String?
    @LenientString var cancelledAt: String?
    @LenientString var createdAt: String?
    let items: [RevaluationItem]?

    var id: Int { revId ?? 0 }
    var isDraft: Bool { (status ?? "draft") == "draft" }
    var isApplied: Bool { status == "applied" }
    var statusText: String {
        if let s = statusLabel, !s.isEmpty { return s }
        switch status {
        case "applied": return "Применена"
        case "cancelled": return "Отменена"
        default: return "Черновик"
        }
    }

    enum CodingKeys: String, CodingKey {
        case number, status, basis, comment, items
        case revId = "id"
        case statusLabel = "status_label"
        case itemsCount = "items_count"
        case sumOld = "sum_old"
        case sumNew = "sum_new"
        case appliedAt = "applied_at"
        case cancelledAt = "cancelled_at"
        case createdAt = "created_at"
        case rule
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _revId = try c.decode(LenientInt.self, forKey: .revId)
        _number = try c.decode(LenientString.self, forKey: .number)
        _status = try c.decode(LenientString.self, forKey: .status)
        _statusLabel = try c.decode(LenientString.self, forKey: .statusLabel)
        _basis = try c.decode(LenientString.self, forKey: .basis)
        _comment = try c.decode(LenientString.self, forKey: .comment)
        // Правило — как сохранили; бывает null или не объект: тогда без него.
        rule = try? c.decodeIfPresent(RevalRule.self, forKey: .rule)
        _itemsCount = try c.decode(LenientInt.self, forKey: .itemsCount)
        _sumOld = try c.decode(LenientDecimal.self, forKey: .sumOld)
        _sumNew = try c.decode(LenientDecimal.self, forKey: .sumNew)
        _appliedAt = try c.decode(LenientString.self, forKey: .appliedAt)
        _cancelledAt = try c.decode(LenientString.self, forKey: .cancelledAt)
        _createdAt = try c.decode(LenientString.self, forKey: .createdAt)
        items = try c.decodeIfPresent([RevaluationItem].self, forKey: .items)
    }
}

struct RevaluationItem: Decodable {
    @LenientInt var id: Int?
    @LenientInt var productId: Int?
    @LenientString var name: String?
    @LenientDecimal var oldPrice: Decimal?
    @LenientDecimal var newPrice: Decimal?
    /// Последняя закупочная; nil — закупок не было.
    @LenientDecimal var cost: Decimal?
    @LenientDecimal var stockQty: Decimal?
    @LenientBool var applied: Bool?
    /// Цена товара сейчас (после применения её могли поменять).
    @LenientDecimal var currentPrice: Decimal?
    @LenientString var barcode: String?
    @LenientString var article: String?

    enum CodingKeys: String, CodingKey {
        case id, name, cost, applied, barcode, article
        case productId = "product_id"
        case oldPrice = "old_price"
        case newPrice = "new_price"
        case stockQty = "stock_qty"
        case currentPrice = "current_price"
    }
}

/// Строка предпросмотра (и пропущенная — с причиной reason).
struct RevalPreviewItem: Decodable {
    @LenientInt var productId: Int?
    @LenientString var name: String?
    @LenientString var category: String?
    @LenientDecimal var oldPrice: Decimal?
    @LenientDecimal var cost: Decimal?
    @LenientDecimal var stockQty: Decimal?
    @LenientString var barcode: String?
    @LenientString var article: String?
    @LenientDecimal var newPrice: Decimal?
    @LenientString var reason: String?

    enum CodingKeys: String, CodingKey {
        case name, category, cost, barcode, article, reason
        case productId = "product_id"
        case oldPrice = "old_price"
        case stockQty = "stock_qty"
        case newPrice = "new_price"
    }
}

struct RevalPreview: Decodable {
    let items: [RevalPreviewItem]?
    let skipped: [RevalPreviewItem]?
    /// Сколько товаров правило оставило по прежней цене (в список не идут).
    @LenientInt var unchanged: Int?
    /// Взяты первые 3000 товаров.
    @LenientBool var truncated: Bool?
}

struct RevalIdAck: Decodable { @LenientInt var id: Int? }

struct RevalApplyAck: Decodable {
    @LenientBool var applied: Bool?
    @LenientInt var changed: Int?
}

struct RevalCancelAck: Decodable {
    @LenientBool var cancelled: Bool?
    @LenientInt var restored: Int?
    @LenientInt var keptCount: Int?
    enum CodingKeys: String, CodingKey {
        case cancelled, restored
        case keptCount = "kept_count"
    }
}

/// GET /api/seller/revaluations/price-log — журнал изменений розничных цен.
struct PriceLogRow: Decodable, Identifiable {
    @LenientInt var rowId: Int?
    @LenientInt var productId: Int?
    @LenientString var name: String?
    @LenientDecimal var oldPrice: Decimal?
    @LenientDecimal var newPrice: Decimal?
    /// income | revaluation | revaluation_cancel
    @LenientString var source: String?
    @LenientString var sourceLabel: String?
    @LenientInt var documentId: Int?
    @LenientString var user: String?
    @LenientString var createdAt: String?

    var id: Int { rowId ?? 0 }

    enum CodingKeys: String, CodingKey {
        case name, source, user
        case rowId = "id"
        case productId = "product_id"
        case oldPrice = "old_price"
        case newPrice = "new_price"
        case sourceLabel = "source_label"
        case documentId = "document_id"
        case createdAt = "created_at"
    }
}
