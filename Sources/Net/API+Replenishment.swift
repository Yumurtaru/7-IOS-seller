import Foundation

// ============================================================================
//  План закупок — /api/seller/replenishment/* (routes/seller_replenishment.php).
//  Отказы приходят как APIDetailedError (статус, код): 404/405 — сайт ещё без
//  раздела, 403 — нет права «Склад» (создание заказов — ещё «Поставщики»).
// ============================================================================

extension API {
    private static let repl = "api/seller/replenishment"

    func replStatus(retries: Int = 0) async throws -> ReplStatus {
        try await getDetailed(API.repl + "/status", as: ReplStatus.self, retries: retries)
    }

    /// horizon: "7" | "14" | "30" | "next_delivery".
    /// limit = 1000 (максимум сервера), как на Android: по умолчанию сервер отдаёт 300 строк.
    func replPlan(horizon: String) async throws -> ReplPlan {
        try await getDetailed(API.repl + "/plan", query: ["horizon": horizon, "limit": "1000"], as: ReplPlan.self)
    }

    /// «Почему столько» для одной позиции (строки плана без explain, когда их больше 50).
    func replExplain(kind: String, itemId: Int, horizon: String) async throws -> ReplExplainReply {
        try await getDetailed(API.repl + "/plan/explain",
                              query: ["kind": kind, "id": String(itemId), "horizon": horizon],
                              as: ReplExplainReply.self, retries: 0)
    }

    /// «Пересчитать сейчас». Повторный вызов при идущем расчёте вернёт тот же job_id.
    func replRecalc() async throws -> ReplStatus {
        try await postDetailed(API.repl + "/recalc", as: ReplStatus.self)
    }

    /// Правка количества строки. qty — строка с точкой; пустая строка — сбросить к расчётному.
    func replSetQty(kind: String, itemId: Int, qty: String) async throws {
        _ = try await putDetailed(API.repl + "/plan/line",
                                  body: ["kind": kind, "id": itemId, "qty": qty], as: EmptyData.self)
    }

    /// Черновики заказов поставщикам. Ключ повтора — в заголовке И в теле (сервер берёт заголовок).
    /// Тело с ключами по алфавиту: повтор после обрыва уходит байт-в-байт тем же.
    /// Отказ ключа (idempotency_*) приходит IdempotencyError, остальные — APIDetailedError.
    func replCreateOrders(body: [String: Any?], key: String) async throws -> ReplOrdersResult {
        try await postBodyKeyed(API.repl + "/plan/create-orders", body: body,
                                idempotencyKey: key, detailedErrors: true, long: true, as: ReplOrdersResult.self)
    }
}
