import Foundation

// ============================================================================
//  Продажи с кассы — GET /api/seller/pos-sales, /pos-sales/receipts,
//  /pos-sales/receipts/{id}. Срез строится по orders.source = 'pos'.
//
//  Деньги — только @LenientDecimal: сервер отдаёт их строками "0.00".
//  Количество тоже приходит строкой ("7.000") — весовой товар бывает дробным,
//  поэтому qty здесь Decimal, а не Int.
// ============================================================================

struct PosSalesSummary: Decodable {
    @LenientInt var receipts: Int?
    @LenientDecimal var revenue: Decimal?
    @LenientDecimal var avgCheck: Decimal?
    @LenientDecimal var cash: Decimal?
    @LenientDecimal var card: Decimal?
    /// Раскладка нал/карта появилась отдельной миграцией: на старой базе
    /// сервер отдаёт нули и has_split = false — тогда плитки просто не рисуем.
    @LenientBool var hasSplit: Bool?
    /// Возвраты за период: выручка = нал + карта − возвраты. Без этой плитки
    /// шапка не сходилась, и было непонятно, куда делась разница.
    @LenientDecimal var returned: Decimal?

    enum CodingKeys: String, CodingKey {
        case receipts, revenue, cash, card, returned
        case avgCheck = "avg_check"
        case hasSplit = "has_split"
    }
}

struct PosSalesItem: Decodable, Identifiable {
    @LenientInt var productId: Int?
    let name: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var qtyReturned: Decimal?
    @LenientDecimal var revenue: Decimal?
    @LenientInt var receipts: Int?
    let unit: String?

    /// Сервер группирует по (product_id, name): свободные позиции идут с product_id = 0,
    /// а переименованный товар даёт две строки с одним id — поэтому ключ составной.
    var id: String { "\(productId ?? 0)_\(name ?? "")" }

    enum CodingKeys: String, CodingKey {
        case name, qty, revenue, receipts, unit
        case productId = "product_id"
        case qtyReturned = "qty_returned"
    }
}

struct PosSalesResponse: Decodable {
    let summary: PosSalesSummary?
    let items: [PosSalesItem]?
    @LenientBool var hasMore: Bool?     // позиции отдаются по 50 на страницу

    enum CodingKeys: String, CodingKey {
        case summary, items
        case hasMore = "has_more"
    }
}

struct PosReceipt: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var dailyNumber: Int?
    let createdAt: String?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var discount: Decimal?
    let paymentStatus: String?
    let paymentType: String?
    /// pay_cash | pay_card | mixed — появляется вместе с раскладкой платежей.
    let paidMethod: String?
    @LenientDecimal var paidCash: Decimal?
    @LenientDecimal var paidCard: Decimal?
    @LenientInt var positions: Int?

    var receiptId: Int { id ?? 0 }
    var isPaid: Bool { (paymentStatus ?? "") == "paid" }

    enum CodingKeys: String, CodingKey {
        case id, total, discount, positions
        case dailyNumber = "daily_number"
        case createdAt = "created_at"
        case paymentStatus = "payment_status"
        case paymentType = "payment_type"
        case paidMethod = "paid_method"
        case paidCash = "paid_cash"
        case paidCard = "paid_card"
    }
}

struct PosReceiptsPage: Decodable {
    let items: [PosReceipt]?
    @LenientInt var total: Int?
    @LenientInt var page: Int?
    @LenientBool var hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case items, total, page
        case hasMore = "has_more"
    }
}

struct PosReceiptItem: Decodable, Identifiable {
    let name: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var returnQty: Decimal?
    @LenientDecimal var sum: Decimal?
    /// Модификаторы позиции — тот же JSON-текст, что и в обычных заказах.
    let modifiersJson: String?

    var id: String { (name ?? "—") + "-" + ((price?.description) ?? "") + "-" + ((qty?.description) ?? "") }

    enum CodingKeys: String, CodingKey {
        case name, price, qty, sum
        case returnQty = "return_qty"
        case modifiersJson = "modifiers_json"
    }
}

struct PosReceiptDetail: Decodable {
    @LenientInt var id: Int?
    @LenientInt var dailyNumber: Int?
    let createdAt: String?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var discount: Decimal?
    let paymentStatus: String?
    let items: [PosReceiptItem]?

    enum CodingKeys: String, CodingKey {
        case id, total, discount, items
        case dailyNumber = "daily_number"
        case createdAt = "created_at"
        case paymentStatus = "payment_status"
    }
}
