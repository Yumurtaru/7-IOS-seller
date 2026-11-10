import Foundation

// ============================================================================
//  Выгрузка заданиями и фиды площадок — /api/seller/exports/*, /api/seller/feeds/*
//  (routes/seller_feeds.php, волна В4Б сайта).
//
//  Все отказы приходят как APIDetailedError (HTTP-статус, code): 404/405 — сайт ещё
//  без раздела, 403 — нет права. Текст для человека — message сервера. Файлы
//  (готовая выгрузка) скачиваются своим клиентом с Bearer, потоком на диск.
// ============================================================================

extension API {
    private static let exps = "api/seller/exports"
    private static let feedsPath = "api/seller/feeds"

    // ── Выгрузки ─────────────────────────────────────────────────────────

    /// Проба и список последних заданий.
    func expJobs(retries: Int = 0) async throws -> ExpJobsReply {
        try await getDetailed(API.exps + "/jobs", as: ExpJobsReply.self, retries: retries)
    }

    func expMeta(kind: String) async throws -> ExpMeta {
        try await getDetailed(API.exps + "/\(kind)/meta", as: ExpMeta.self, retries: 1)
    }

    /// Запуск. До 3000 строк файл готовится прямо в запросе (до 25 с на сервере), поэтому ждём до 90 с. Без повторов.
    func expRun(kind: String, columns: [String], filters: [String: String], format: String) async throws -> ExpJobReply {
        try await postDetailedLong(API.exps + "/\(kind)/run",
                                   body: ["columns": columns, "filters": filters, "format": format],
                                   as: ExpJobReply.self)
    }

    /// Опрос: ответ ждём до 45 с, без повторов (следующий тик повторит сам).
    func expJob(id: Int) async throws -> ExpJobReply {
        try await getDetailedLongWait(API.exps + "/jobs/\(id)", as: ExpJobReply.self)
    }

    func expCancel(id: Int) async throws -> ExpJobReply {
        try await postDetailed(API.exps + "/jobs/\(id)/cancel", as: ExpJobReply.self)
    }

    /// Готовый файл с Bearer потоком на диск.
    func expDownload(job: ExpJob) async throws -> URL {
        let name = ExpLogic.fileName(for: job)
        return try await downloadToDisk(API.exps + "/jobs/\(job.id)/download", fallbackName: name).url
    }

    // ── Старая выгрузка в 1С: тот же файл, но с чтением заголовка X-Yumurta-Warning ──
    func export1C() async throws -> (url: URL, vatNotSet: Bool) {
        try await downloadToDisk("api/seller/export/1c", fallbackName: "1c_products.xml")
    }

    // ── Фиды ─────────────────────────────────────────────────────────────

    func feeds(retries: Int = 0) async throws -> FeedsReply {
        try await getDetailed(API.feedsPath, as: FeedsReply.self, retries: retries)
    }

    /// Ставка НДС: пустая строка — «не указывать» (шлём именно "", не nil: nil makeRequest выбросит из тела).
    func feedSetVat(_ value: String) async throws -> FeedVatReply {
        try await postDetailed(API.feedsPath + "/vat", body: ["vat": value], as: FeedVatReply.self)
    }

    func feedEnable(type: String, on: Bool) async throws -> FeedReply {
        try await postDetailed(API.feedsPath + "/\(type)/enable", body: ["enabled": on], as: FeedReply.self)
    }

    /// Настройки одним объектом options; очищенные поля — пустыми строками (см. FeedLogic.optionsBody).
    func feedSaveOptions(type: String, options: [String: Any]) async throws -> FeedReply {
        try await postDetailed(API.feedsPath + "/\(type)/options", body: ["options": options], as: FeedReply.self)
    }

    func feedRotate(type: String) async throws -> FeedReply {
        try await postDetailed(API.feedsPath + "/\(type)/rotate", as: FeedReply.self)
    }

    /// Сборка большого каталога может идти дольше обычного запроса.
    func feedRebuild(type: String) async throws -> FeedReply {
        try await postDetailedLong(API.feedsPath + "/\(type)/rebuild", as: FeedReply.self)
    }
}
