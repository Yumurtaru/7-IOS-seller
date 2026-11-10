import Foundation

// ============================================================================
//  Приход по фото накладной — /api/seller/invoice-ocr/* (routes/seller_invoice_ocr.php).
//
//  Все отказы приходят как APIDetailedError (HTTP-статус, code, extras["code"]):
//  404/405 — сайт ещё без раздела, 403 — нет права или склада, 429 busy /
//  daily_limit / retry_limit — по коду. Текст для человека — message сервера.
//  Idempotency-Key здесь сервер НЕ поддерживает: защита от дубля прихода —
//  его собственное already:true, а кнопка на время запроса заблокирована.
// ============================================================================

/// Один файл для загрузки (страница накладной).
struct OcrUploadFile {
    let filename: String
    let mime: String
    let data: Data
}

extension API {
    private static let ocr = "api/seller/invoice-ocr"

    func ocrState() async throws -> OcrState {
        try await getDetailed(API.ocr + "/state", as: OcrState.self, retries: 0)
    }

    func ocrHistory(page: Int) async throws -> OcrHistory {
        try await getDetailed(API.ocr, query: ["page": String(page)], as: OcrHistory.self)
    }

    /// Статус и экран проверки. Для опроса — retries 0: сбой сети переживёт следующий тик.
    func ocrJob(id: Int, retries: Int = 2) async throws -> OcrJob {
        try await getDetailed(API.ocr + "/\(id)", as: OcrJob.self, retries: retries)
    }

    func ocrUpload(_ files: [OcrUploadFile]) async throws -> OcrJob {
        let list = files.map { (filename: $0.filename, mime: $0.mime, data: $0.data) }
        return try await uploadFiles(API.ocr, field: "files[]", files: list, as: OcrJob.self)
    }

    /// Шапка: передаём только изменённые поля. Очистить значение — пустая строка
    /// (nil makeRequest отбрасывает, и сервер счёл бы поле «не передано»).
    func ocrUpdateHeader(id: Int, fields: [String: Any?]) async throws -> OcrJob {
        try await putDetailed(API.ocr + "/\(id)", body: fields, as: OcrJob.self)
    }

    func ocrUpdateLine(id: Int, lineId: Int, fields: [String: Any?]) async throws -> OcrJob {
        try await putDetailed(API.ocr + "/\(id)/lines/\(lineId)", body: fields, as: OcrJob.self)
    }

    /// Сопоставление строки. factor — строка вида "1" или "0.5" (точка).
    /// Подтверждение единицы — тот же вызов с теми же kind / id / factor.
    func ocrMap(id: Int, lineId: Int, kind: String, itemId: Int, factor: String) async throws -> OcrJob {
        try await putDetailed(API.ocr + "/\(id)/lines/\(lineId)/map",
                              body: ["kind": kind, "id": itemId, "factor": factor, "remember": true],
                              as: OcrJob.self)
    }

    func ocrPreview(id: Int, priceBasis: String) async throws -> OcrPreview {
        try await getDetailed(API.ocr + "/\(id)/receipt-preview", query: ["price_basis": priceBasis],
                              as: OcrPreview.self)
    }

    /// Приход. Повтор после обрыва — тот же вызов: сервер ответит already:true.
    func ocrReceipt(id: Int, warehouseId: Int, post: Bool, priceBasis: String,
                    skipUnmapped: Bool, acceptDiff: Bool) async throws -> OcrReceiptAck {
        let body: [String: Any?] = [
            "warehouse_id": warehouseId,
            "post": post,
            "price_basis": priceBasis,
            "skip_unmapped": skipUnmapped,
            "accept_diff": acceptDiff,
        ]
        // Проводка долгая: ждём ответ до 90 с (как загрузка), иначе обрыв по 20 с при уже созданном приходе.
        return try await postDetailedLong(API.ocr + "/\(id)/receipt", body: body, as: OcrReceiptAck.self)
    }

    /// «Сопоставить сами»: память сопоставления по ИНН поставщика, штрихкоды и артикулы.
    /// Ответ — полный вид накладной (поле automap с итогом сервер добавляет сверху, оно не нужно).
    func ocrAutomap(id: Int) async throws -> OcrJob {
        try await postDetailed(API.ocr + "/\(id)/automap", as: OcrJob.self)
    }

    func ocrRetry(id: Int) async throws -> OcrJob {
        try await postDetailed(API.ocr + "/\(id)/retry", as: OcrJob.self)
    }

    func ocrDelete(id: Int) async throws {
        _ = try await delete(API.ocr + "/\(id)", as: EmptyData.self)
    }
}
