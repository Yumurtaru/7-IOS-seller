import Foundation

// ============================================================================
//  ВА (сайт А618): списки продавца вместе с `meta` конверта — по нему экран
//  понимает, применил ли сервер сортировку, поиск и сегмент. Те же запросы, что
//  у orders()/returns()/clients(), но ответ — (данные, meta). У старого сервера
//  meta пустой. Повторы GET и текст ошибки — как у get() (getWithMeta).
// ============================================================================

extension API {
    /// GET /api/seller/orders + meta {sort, search}. sort — ?sort=old только для «Сначала старые».
    func ordersPage(status: String?, payment: String?, date: String?, search: String?,
                    sort: OrderSort, page: Int) async throws -> (page: OrdersPage, meta: [String: Any]) {
        var q = ["page": String(page)]
        if let s = status, !s.isEmpty { q["status"] = s }
        if let p = payment, !p.isEmpty { q["payment"] = p }
        if let d = date, !d.isEmpty { q["date"] = d }
        if let t = search, !t.isEmpty { q["search"] = t }
        if let so = sort.param { q["sort"] = so }
        let (res, meta) = try await getWithMeta("api/seller/orders", query: q, as: OrdersPage.self)
        return (res, meta)
    }

    /// GET /api/seller/returns + meta {sort, search}. Поиск — номер заказа, клиент, телефон.
    func returnsPage(status: String?, search: String?) async throws -> (items: [ReturnSummary], meta: [String: Any]) {
        var q: [String: String] = [:]
        if let s = status, !s.isEmpty { q["status"] = s }
        if let t = search, !t.isEmpty { q["search"] = t }
        let (rows, meta) = try await getWithMeta("api/seller/returns", query: q, as: [ReturnSummary].self)
        return (rows, meta)
    }

    /// GET /api/seller/clients + meta {sort, dir, segment, search}. Параметры — как у clients().
    func clientsPage(search: String, segment: String?, sort: String?,
                     dir: String?) async throws -> (items: [ClientSummary], meta: [String: Any]) {
        var q: [String: String] = [:]
        if !search.isEmpty { q["search"] = search }
        if let seg = segment, !seg.isEmpty { q["segment"] = seg }
        if let s = sort, !s.isEmpty { q["sort"] = s }
        if let d = dir, !d.isEmpty { q["dir"] = d }
        let (rows, meta) = try await getWithMeta("api/seller/clients", query: q, as: [ClientSummary].self)
        return (rows, meta)
    }
}
