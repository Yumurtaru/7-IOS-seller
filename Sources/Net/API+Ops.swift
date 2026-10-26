import Foundation

// ============================================================================
//  Листы ожидания и брони столов.
// ============================================================================

extension API {

    /// Кто ждёт товар и кто ждёт снижения цены.
    func waitlist() async throws -> WaitlistResponse {
        try await get("api/seller/waitlist", as: WaitlistResponse.self)
    }

    /// Брони столов. Фильтры сервера: status и date (YYYY-MM-DD).
    func reservations(status: String? = nil, date: String? = nil) async throws -> [TableReservation] {
        var q: [String: String] = [:]
        if let status, !status.isEmpty { q["status"] = status }
        if let date, !date.isEmpty { q["date"] = date }
        return try await get("api/seller/reservations", query: q, as: [TableReservation].self)
    }

    /// confirmed | rejected | cancelled | seated — список валидируется сервером.
    func setReservationStatus(id: Int, status: String) async throws {
        _ = try await post("api/seller/reservations/\(id)/status", body: ["status": status], as: Phase2BoolAck.self)
    }
}
