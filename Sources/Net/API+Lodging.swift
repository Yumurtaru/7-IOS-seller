import Foundation

// ============================================================================
//  API жилья (routes/seller_lodging.php).
// ----------------------------------------------------------------------------
//  Раздел доступен только организациям типа «Жильё»: на другой тип сервер
//  отвечает 403 «Раздел «Жильё» доступен организациям формата «Жильё»»,
//  поэтому и меню его показывает только там.
//
//  ВАЖНО: сервер трогает ТОЛЬКО пришедшие ключи, поэтому тело сохранения
//  собирается словарём из того, что экран действительно менял. Отправлять
//  объект целиком нельзя — затрёт настройки, сделанные в веб-кабинете.
// ============================================================================

extension API {

    // MARK: Объекты

    func lodgingUnits() async throws -> LodgingUnitsResponse {
        try await get("api/seller/lodging/units", as: LodgingUnitsResponse.self)
    }

    func lodgingAmenities() async throws -> [LodgingAmenityGroup] {
        try await get("api/seller/lodging/amenities", as: [LodgingAmenityGroup].self)
    }

    /// keys — ключи окна создания объекта (IdempotencyKeys.form()).
    func createLodgingUnit(_ body: [String: Any?], keys: IdempotencyKeys? = nil) async throws -> IdAck {
        // Ключ повтора (сервер: lodging.units.create): повтор после обрыва — без второго объекта.
        try await postKeyed("api/seller/lodging/units", body: body, as: IdAck.self, keys: keys)
    }

    func updateLodgingUnit(id: Int, body: [String: Any?]) async throws {
        _ = try await put("api/seller/lodging/units/\(id)", body: body, as: BoolAck.self)
    }

    /// По объекту с бронями сервер возвращает deleted=false и текст причины:
    /// история броней не удаляется, объект только снимается с витрины.
    func deleteLodgingUnit(id: Int) async throws -> LodgingUnitDeleteAck {
        try await delete("api/seller/lodging/units/\(id)", as: LodgingUnitDeleteAck.self)
    }

    func uploadLodgingPhoto(unitId: Int, jpeg: Data) async throws -> LodgingPhotoAck {
        try await upload("api/seller/lodging/units/\(unitId)/photos",
                         field: "photo", filename: "photo.jpg", mime: "image/jpeg",
                         fileData: jpeg, as: LodgingPhotoAck.self)
    }

    /// Сделать фотографию обложкой (ручка порядка фотографий). Без неё сменить
    /// обложку из приложения можно было только удалив текущую.
    func setLodgingCover(unitId: Int, photoId: Int) async throws {
        _ = try await post("api/seller/lodging/units/\(unitId)/photos/order",
                           body: ["cover_id": photoId], as: BoolAck.self)
    }

    func deleteLodgingPhoto(id: Int) async throws {
        _ = try await delete("api/seller/lodging/photos/\(id)", as: BoolAck.self)
    }

    // MARK: Тарифы

    func lodgingRatePlans(unitId: Int) async throws -> [LodgingRatePlan] {
        try await get("api/seller/lodging/units/\(unitId)/rate-plans", as: [LodgingRatePlan].self)
    }

    func createLodgingRatePlan(unitId: Int, body: [String: Any?]) async throws -> IdAck {
        try await post("api/seller/lodging/units/\(unitId)/rate-plans", body: body, as: IdAck.self)
    }

    func updateLodgingRatePlan(id: Int, body: [String: Any?]) async throws {
        _ = try await put("api/seller/lodging/rate-plans/\(id)", body: body, as: BoolAck.self)
    }

    /// По проданному тарифу сервер его ВЫКЛЮЧАЕТ (deleted=false, disabled=true):
    /// условия уже проданных броней меняться не должны.
    func deleteLodgingRatePlan(id: Int) async throws -> LodgingPlanDeleteAck {
        try await delete("api/seller/lodging/rate-plans/\(id)", as: LodgingPlanDeleteAck.self)
    }

    // MARK: Календарь

    /// from/to — «ГГГГ-ММ-ДД». Сервер отдаёт максимум 400 дней за раз.
    func lodgingCalendar(unitId: Int, from: String, to: String) async throws -> LodgingCalendar {
        try await get("api/seller/lodging/units/\(unitId)/calendar",
                      query: ["from": from, "to": to], as: LodgingCalendar.self)
    }

    /// Массовая правка диапазона: меняются только переданные ключи.
    /// weekdays: 1=Пн … 7=Вс (как date('N') на сервере).
    func lodgingCalendarBulk(unitId: Int, body: [String: Any?]) async throws -> LodgingCalendarAck {
        try await post("api/seller/lodging/units/\(unitId)/calendar", body: body, as: LodgingCalendarAck.self)
    }

    // MARK: Брони

    func lodgingBookings(status: String?, unitId: Int? = nil) async throws -> LodgingBookingsResponse {
        var q: [String: String] = [:]
        if let s = status, !s.isEmpty { q["status"] = s }
        if let u = unitId, u > 0 { q["unit_id"] = String(u) }
        return try await get("api/seller/lodging-bookings", query: q, as: LodgingBookingsResponse.self)
    }

    /// Бронь «от стойки»: гость позвонил или пришёл. Заказ и оплата через
    /// площадку не создаются — так сделано на сервере (комиссию брать не с чего).
    /// keys — ключи окна брони (IdempotencyKeys.form()).
    func createLodgingBooking(_ body: [String: Any?], keys: IdempotencyKeys? = nil) async throws -> LodgingBookingCreatedAck {
        // Ключ повтора (сервер: lodging.bookings.create): повтор после обрыва — без второй брони.
        try await postKeyed("api/seller/lodging-bookings", body: body, as: LodgingBookingCreatedAck.self, keys: keys)
    }

    /// status ∈ confirmed | checked_in | checked_out | cancelled | no_show.
    func setLodgingBookingStatus(id: Int, status: String, note: String? = nil) async throws -> LodgingStatusAck {
        var body: [String: Any?] = ["status": status]
        if let n = note, !n.isEmpty { body["note"] = n }
        return try await post("api/seller/lodging-bookings/\(id)/status", body: body, as: LodgingStatusAck.self)
    }

    // MARK: Длительная аренда

    func lodgingLongRequests() async throws -> [LodgingLongRequest] {
        try await get("api/seller/lodging-long", as: [LodgingLongRequest].self)
    }

    /// ВАЖНО: note отправляется ВСЕГДА. Сервер пишет seller_note безусловно
    /// (`'seller_note' => trim(note) ?: null`), поэтому запрос без этого ключа
    /// стирал заметку, набранную раньше: продавец менял статус заявки — и
    /// «просит с 1 ноября, звонить после 18:00» исчезало.
    func setLodgingLongStatus(id: Int, status: String, note: String) async throws {
        _ = try await post("api/seller/lodging-long/\(id)/status",
                           body: ["status": status, "note": note], as: StatusAck.self)
    }

    // MARK: Настройки раздела

    func lodgingSettings() async throws -> LodgingSettings {
        try await get("api/seller/lodging-settings", as: LodgingSettings.self)
    }

    func saveLodgingSettings(taxPct: Double, taxMin: Decimal) async throws {
        _ = try await put("api/seller/lodging-settings", body: [
            "tourist_tax_pct": taxPct,
            "tourist_tax_min": "\(taxMin)",
        ], as: BoolAck.self)
    }
}
