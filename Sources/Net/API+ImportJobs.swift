import Foundation

// ============================================================================
//  Импорт заданиями — /api/seller/import/jobs/* (routes/seller_import.php, волна В4А сайта).
//
//  Все отказы приходят как APIDetailedError (HTTP-статус, code): 404/405 — сайт ещё без раздела,
//  403 — нет права, 409 perms_changed — права изменились после проверки. Текст для человека — message сервера.
//  Опрос и действия сами двигают задание на сервере (до ~6 с работы): ответ ждём до 45–90 с.
//  Старые ручки (import/upload, preview, run, status) остаются в API+Import.swift.
// ============================================================================

extension API {
    private static let impJobsPath = "api/seller/import/jobs"

    /// Проба раздела и история (без заданий в статусе uploaded).
    func impJobs(page: Int = 1, perPage: Int = 20, retries: Int = 0) async throws -> ImpJobsReply {
        try await getDetailed(API.impJobsPath, query: ["page": String(page), "per_page": String(perPage)],
                              as: ImpJobsReply.self, retries: retries)
    }

    /// Незавершённое задание (проверка, импорт, пауза) или job = nil.
    func impActive() async throws -> ImpActiveReply {
        try await getDetailed(API.impJobsPath + "/active", as: ImpActiveReply.self, retries: 1)
    }

    /// Загрузка файла: один файл в поле file, target — в адресе. Файл читается потоком, в памяти целиком не держится.
    func impUpload(target: String, filename: String, mime: String, source: URL) async throws -> ImportUpload {
        try await uploadFileStreamed(API.impJobsPath, query: ["target": target], field: "file",
                                     filename: filename, mime: mime, source: source,
                                     maxBytes: ImpLogic.maxBytes, as: ImportUpload.self)
    }

    /// XLSX: другой лист. Ответ — как у загрузки.
    func impSheet(id: Int, name: String) async throws -> ImportUpload {
        try await postDetailedLong(API.impJobsPath + "/\(id)/sheet", body: ["sheet": name], as: ImportUpload.self)
    }

    /// Состояние задания; ответ ждём до 45 с, без повторов (следующий тик опроса повторит сам).
    func impJob(id: Int) async throws -> ImpJob {
        try await getDetailedLongWait(API.impJobsPath + "/\(id)", as: ImpJob.self)
    }

    /// Пробный прогон: в каталог ничего не пишется.
    func impPreview(id: Int, body: [String: Any?]) async throws -> ImpJob {
        try await postDetailedLong(API.impJobsPath + "/\(id)/preview", body: body, as: ImpJob.self)
    }

    func impRows(id: Int, filter: String, page: Int) async throws -> ImpRowsReply {
        try await getDetailed(API.impJobsPath + "/\(id)/rows",
                              query: ["filter": filter, "page": String(page), "per_page": String(ImpLogic.rowsPerPage)],
                              as: ImpRowsReply.self, retries: 1)
    }

    /// Запуск. Без повторов: после обрыва экран сначала перечитывает задание (ключа повтора у запуска нет).
    func impRun(id: Int, confirmHide: Bool) async throws -> ImpJob {
        try await postDetailedLong(API.impJobsPath + "/\(id)/run", body: ["confirm_hide": confirmHide], as: ImpJob.self)
    }

    func impPause(id: Int) async throws -> ImpJob {
        try await postDetailedLong(API.impJobsPath + "/\(id)/pause", as: ImpJob.self)
    }

    func impResume(id: Int) async throws -> ImpJob {
        try await postDetailedLong(API.impJobsPath + "/\(id)/resume", as: ImpJob.self)
    }

    func impCancel(id: Int) async throws -> ImpJob {
        try await postDetailedLong(API.impJobsPath + "/\(id)/cancel", as: ImpJob.self)
    }

    func impRollback(id: Int) async throws -> ImpJob {
        try await postDetailedLong(API.impJobsPath + "/\(id)/rollback", as: ImpJob.self)
    }

    /// Файл ошибок с Bearer потоком на диск (временная папка exports).
    func impErrorsFile(job: ImpJob) async throws -> URL {
        try await downloadToDisk(ImpLogic.errorsFilePath(job), fallbackName: ImpLogic.errorsFileName(job)).url
    }
}
