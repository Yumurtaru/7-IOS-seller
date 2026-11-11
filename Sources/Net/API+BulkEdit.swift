import Foundation

// ============================================================================
//  Массовая правка товаров (волна М1 сайта). Старая POST /products/bulk — в API+Seller.
// ============================================================================

extension API {

    /// Предпросмотр (dry_run): ничего не меняет, ключ повтора не нужен.
    func bulkEditPreview(ids: [Int], changes: [String: Any]) async throws -> BulkEditResult {
        try await post("api/seller/products/bulk-edit",
                       body: ["ids": ids, "changes": changes, "dry_run": true],
                       as: BulkEditResult.self)
    }

    /// Применение: idempotency_key в теле и в заголовке (ключ ведёт экран).
    func bulkEditApply(ids: [Int], changes: [String: Any], key: String) async throws -> BulkEditResult {
        try await postBodyKeyed("api/seller/products/bulk-edit",
                                body: ["ids": ids, "changes": changes],
                                idempotencyKey: key,
                                as: BulkEditResult.self)
    }

    func bulkEditUndo(batchId: Int) async throws -> BulkEditUndo {
        try await post("api/seller/products/bulk-edit/\(batchId)/undo", body: [:], as: BulkEditUndo.self)
    }

    func bulkEditHistory() async throws -> [BulkEditBatch] {
        try await get("api/seller/products/bulk-edit", as: BulkEditHistory.self).items
    }
}
