import Foundation

// ============================================================================
//  Волна А82: «Отчёт по продажам» и «Контроль потерь» (только чтение).
//  Права: отчёт — «Аналитика и отчёты» (analytics), потери — «Безопасность»
//  (security); без права — 403. Старый сервер без ручек — 404 (code no_route).
//  Запросы идут через getDetailed: статус нужен, чтобы молча спрятать блок.
// ============================================================================

extension API {
    /// GET /api/seller/sales-report — query: period=… или from/to, station_id.
    /// retries: 0 — дашборд и проверка пункта меню (без повторов).
    func salesReport(_ query: [String: String], retries: Int = 2) async throws -> SalesReport {
        try await getDetailed("api/seller/sales-report", query: query, as: SalesReport.self, retries: retries)
    }

    /// GET /api/seller/loss-control — query: period=… или from/to, rule, brief=1.
    /// Ручка тяжёлая (разбор журнала) — на дашборде retries: 0.
    func lossControl(_ query: [String: String], retries: Int = 2) async throws -> LossControl {
        try await getDetailed("api/seller/loss-control", query: query, as: LossControl.self, retries: retries)
    }

    /// GET /api/seller/sales-report/export?format=xlsx&<те же параметры> — файл
    /// во временную папку (имя — из Content-Disposition, sales_<from>_<to>.xlsx).
    func exportSalesReportXlsx(_ query: [String: String]) async throws -> URL {
        var q = query
        q["format"] = "xlsx"
        return try await downloadFile("api/seller/sales-report/export", query: q, fallbackName: "sales.xlsx")
    }
}
