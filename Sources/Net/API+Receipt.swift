import Foundation

// ============================================================================
//  Волна А99: приёмка, наценка и переоценка (routes/seller_receipt.php).
//
//  Старый сервер отвечает на эти ручки 404, сотрудник без права — 403: экраны
//  прячут новое молча (DocumentEditView, RevalFeature). Тела собираем без nil
//  во вложенных словарях: makeRequest чистит nil только на верхнем уровне.
// ============================================================================

extension API {

    /// Последняя закупка, текущая розница, наценка категории по позициям;
    /// плюс mode / retail_on_income / may_price. Пустой список — проба сервера.
    func priceInfo(_ keys: [(kind: String, id: Int)]) async throws -> PriceInfoResponse {
        let items: [[String: Any]] = keys.map { ["kind": $0.kind, "id": $0.id] }
        return try await post("api/seller/stock/price-info", body: ["items": items], as: PriceInfoResponse.self)
    }

    /// Список переоценок (status: draft | applied | cancelled, nil — все).
    /// С кодом отказа (APIDetailedError): 403/404 — раздела нет, прячем пункт.
    func revaluations(status: String? = nil, retries: Int = 2) async throws -> [Revaluation] {
        var q: [String: String] = [:]
        if let status, !status.isEmpty { q["status"] = status }
        return try await getDetailed("api/seller/revaluations", query: q, as: [Revaluation].self, retries: retries)
    }

    func revaluation(id: Int) async throws -> Revaluation {
        try await get("api/seller/revaluations/\(id)", as: Revaluation.self)
    }

    /// Расчёт новых цен по правилу: rule {mode, value, rounding}, scope {product_ids |
    /// category_id | supplier_id | all, in_stock}, keep_same — оставлять строки без изменений.
    func revaluationPreview(rule: [String: Any], scope: [String: Any], keepSame: Bool) async throws -> RevalPreview {
        try await post("api/seller/revaluations/preview",
                       body: ["rule": rule, "scope": scope, "keep_same": keepSame], as: RevalPreview.self)
    }

    private func revalBody(items: [(productId: Int, newPrice: Decimal)], rule: [String: Any]?,
                           basis: String, comment: String) -> [String: Any?] {
        let rows: [[String: Any]] = items.map {
            ["product_id": $0.productId, "new_price": ReceiptMath.moneyInput($0.newPrice).replacingOccurrences(of: ",", with: ".")]
        }
        // basis и comment уходят всегда: пустая строка очищает поле (как в кабинете).
        return ["items": rows, "rule": rule, "basis": basis, "comment": comment]
    }

    /// А102 (П-54 №2): с Idempotency-Key (postKeyed, ключи окна — keys). Тот же ключ и то же
    /// тело → тот же {id}, второго черновика нет; тот же ключ с другим телом — 422
    /// idempotency_key_reused. Отказ — APIDetailedError (статус и код), как у документов склада.
    func createRevaluation(items: [(productId: Int, newPrice: Decimal)], rule: [String: Any]?,
                           basis: String, comment: String, keys: IdempotencyKeys? = nil) async throws -> RevalIdAck {
        try await postKeyed("api/seller/revaluations", body: revalBody(items: items, rule: rule, basis: basis, comment: comment),
                            as: RevalIdAck.self, detailed: true, keys: keys)
    }

    func updateRevaluation(id: Int, items: [(productId: Int, newPrice: Decimal)], rule: [String: Any]?,
                           basis: String, comment: String) async throws {
        _ = try await put("api/seller/revaluations/\(id)", body: revalBody(items: items, rule: rule, basis: basis, comment: comment),
                          as: EmptyData.self)
    }

    func deleteRevaluation(id: Int) async throws {
        _ = try await delete("api/seller/revaluations/\(id)", as: EmptyData.self)
    }

    /// Право «Менять цены», иначе 403 с текстом сервера.
    func applyRevaluation(id: Int) async throws -> RevalApplyAck {
        try await post("api/seller/revaluations/\(id)/apply", as: RevalApplyAck.self)
    }

    func cancelRevaluation(id: Int) async throws -> RevalCancelAck {
        try await post("api/seller/revaluations/\(id)/cancel", as: RevalCancelAck.self)
    }

    func priceLog(q: String?) async throws -> [PriceLogRow] {
        var query: [String: String] = [:]
        if let q, q.count >= 2 { query["q"] = q }
        return try await get("api/seller/revaluations/price-log", query: query, as: [PriceLogRow].self)
    }

    /// Наценка категории: markup nil — снять (пустая строка, как markupVal сервера).
    func updateCategoryMarkup(id: Int, markup: Decimal?, rounding: String) async throws {
        let m = markup.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        _ = try await put("api/seller/categories/\(id)", body: ["markup_percent": m, "rounding_mode": rounding],
                          as: EmptyData.self)
    }
}
