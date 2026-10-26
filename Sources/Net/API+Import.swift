import Foundation

extension API {

    /// Шаг 1. target: products | ingredients. Сервер читает его из query —
    /// в multipart-теле лежит только сам файл.
    func importUpload(target: String, filename: String, mime: String, data: Data) async throws -> ImportUpload {
        try await upload("api/seller/import/upload?target=\(target)",
                         field: "file", filename: filename, mime: mime,
                         fileData: data, as: ImportUpload.self)
    }

    /// Шаги 2 и 3 отличаются только адресом: preview ничего не меняет.
    /// А60/П-23.6: run ждёт ответа до 90 с (большой файл), startRow — продолжить
    /// остановленный импорт с этой строки (nil — ключ не шлём, как раньше).
    func importProcess(apply: Bool, fileId: String, target: String,
                       mapping: [String: Int], mode: String,
                       skipErrors: Bool, startRow: Int? = nil) async throws -> ImportResult {
        var body: [String: Any?] = [
            "file_id": fileId,
            "target": target,
            "mapping": mapping,
            "mode": mode,
            "skip_errors": skipErrors ? 1 : 0,
        ]
        if let s = startRow, s > 0 { body["start_row"] = s }
        if apply {
            return try await postLong("api/seller/import/run", body: body, as: ImportResult.self)
        }
        return try await post("api/seller/import/preview", body: body, as: ImportResult.self)
    }

    /// А60/П-23.6: состояние запуска импорта этого файла (после обрыва или 409
    /// «Импорт уже выполняется»).
    func importStatus(fileId: String) async throws -> ImportStatus {
        try await get("api/seller/import/status", query: ["file_id": fileId], as: ImportStatus.self)
    }
}
