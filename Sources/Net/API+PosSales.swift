import Foundation

// ============================================================================
//  Продажи с кассы. Все три ручки требуют колонку orders.source — без неё
//  сервер отвечает 422 с понятным текстом, его и показываем.
//
//  Фильтры одинаковые у среза и у списка чеков: from / to (YYYY-MM-DD) и
//  paid (paid | unpaid). Поэтому собираем их в одном месте.
// ============================================================================

extension API {

    private func posQuery(from: String?, to: String?, paid: String?) -> [String: String] {
        var q: [String: String] = [:]
        if let from, !from.isEmpty { q["from"] = from }
        if let to, !to.isEmpty { q["to"] = to }
        if let paid, !paid.isEmpty { q["paid"] = paid }
        return q
    }

    /// Срез: сводка (чеки, выручка, средний чек, нал/карта) + продажи по позициям.
    func posSales(from: String? = nil, to: String? = nil, paid: String? = nil,
                  q: String? = nil, sort: String? = nil, page: Int = 1) async throws -> PosSalesResponse {
        var query = posQuery(from: from, to: to, paid: paid)
        if page > 1 { query["page"] = String(page) }
        if let q, !q.isEmpty { query["q"] = q }
        if let sort, !sort.isEmpty { query["sort"] = sort }
        // Без dir сервер сортирует по убыванию (seller_pos_sales.php), и
        // «По названию» шло от «Я» к «А». Название — по алфавиту.
        if sort == "name" { query["dir"] = "asc" }
        return try await get("api/seller/pos-sales", query: query, as: PosSalesResponse.self)
    }

    /// Лента чеков, по 30 на страницу.
    func posReceipts(page: Int = 1, from: String? = nil, to: String? = nil, paid: String? = nil) async throws -> PosReceiptsPage {
        var query = posQuery(from: from, to: to, paid: paid)
        query["page"] = String(page)
        return try await get("api/seller/pos-sales/receipts", query: query, as: PosReceiptsPage.self)
    }

    /// Один чек с позициями.
    func posReceipt(id: Int) async throws -> PosReceiptDetail {
        try await get("api/seller/pos-sales/receipts/\(id)", as: PosReceiptDetail.self)
    }
}
