import Foundation

// ============================================================================
//  Этап AV (паритет с Android): ручки, которых не хватало экранам iOS.
//  Каждое поле сверено с сервером (sitecode114):
//   • POST /api/seller/products → {id}                (routes/seller_products.php)
//   • PUT  /api/seller/services/{id} → {updated, slots_removed?, slots_kept_booked?}
//     и частичное обновление: сервер берёт ТОЛЬКО пришедшие ключи (seller_services.php)
//   • GET  /api/seller/orders?date=yyyy-MM-dd          (routes/seller.php)
//   • POST/DELETE /api/seller/categories/{id}/image → {image} / {deleted}
// ============================================================================

/// Ответ PUT services/{id}: сколько свободных будущих окон сервер удалил после
/// смены длительности или перерыва и сколько окон с записями осталось.
/// Поля аддитивные: нет их (ничего не удалено или старый сервер) — nil.
struct ServiceUpdateAck: Decodable {
    @LenientBool var updated: Bool?
    @LenientInt var slotsRemoved: Int?
    @LenientInt var slotsKeptBooked: Int?

    enum CodingKeys: String, CodingKey {
        case updated
        case slotsRemoved = "slots_removed"
        case slotsKeptBooked = "slots_kept_booked"
    }
}

/// Ответ загрузки обложки категории: путь картинки (как в списке категорий).
struct CategoryImageAck: Decodable {
    var image: String?
}

extension API {
    /// Создание товара с ключом повтора ОКНА (IdempotencyKeys.form()): повтор после
    /// обрыва тем же телом уходит с тем же ключом, и сервер не заводит второй товар.
    /// Возвращает номер нового товара (nil — сервер его не прислал).
    func createProduct(fields: [String: Any?], keys: IdempotencyKeys) async throws -> Int? {
        // detailed: 5xx с JSON-телом и idempotency_in_progress приходят как
        // APIDetailedError, ключ окна остаётся, и API.keyedOutcomeUnknown видит
        // «исход неизвестен» (как buyBoost) — повтор уйдёт с тем же ключом.
        let ack = try await postKeyed("api/seller/products", body: fields, as: IdAck.self,
                                      detailed: true, keys: keys)
        return ack.id
    }

    /// То же, что updateService, но с ответом сервера (slots_removed и др.).
    func updateServiceAck(id: Int, name: String, description: String?, durationMin: Int, bufferMin: Int,
                          price: Decimal, masterId: Int?, isActive: Bool,
                          categoryId: Int = 0, sortOrder: Int = 0) async throws -> ServiceUpdateAck {
        try await put("api/seller/services/\(id)", body: [
            "name": name, "description": description,
            "duration_min": durationMin, "buffer_min": bufferMin,
            "price": "\(price)", "master_id": masterId ?? 0, "is_active": isActive ? 1 : 0,
            "category_id": categoryId, "sort_order": sortOrder,
        ], as: ServiceUpdateAck.self)
    }

    /// Быстрый тумблер «активна» в списке услуг: только is_active. Сервер обновляет
    /// лишь пришедшие ключи — цена, мастер, категория и расписание не трогаются.
    func setServiceActive(id: Int, active: Bool) async throws {
        _ = try await put("api/seller/services/\(id)", body: ["is_active": active ? 1 : 0],
                          as: ServiceUpdateAck.self)
    }

    /// Заказы с фильтром по дню оформления (?date=yyyy-MM-dd, routes/seller.php).
    /// search — поиск сервера по номеру, телефону или имени (П-61 №1); nil или
    /// пусто — параметр не уходит. Старый сервер неизвестный параметр игнорирует.
    func orders(status: String?, payment: String?, date: String?, search: String? = nil, page: Int) async throws -> OrdersPage {
        var q = ["page": String(page)]
        if let s = status, !s.isEmpty { q["status"] = s }
        if let p = payment, !p.isEmpty { q["payment"] = p }
        if let d = date, !d.isEmpty { q["date"] = d }
        if let t = search, !t.isEmpty { q["search"] = t }
        return try await get("api/seller/orders", query: q, as: OrdersPage.self)
    }

    /// Обложка категории: файл в поле «photo» (как uploadCategoryImage), ответ {image}.
    func uploadCategoryCover(id: Int, jpeg: Data) async throws -> CategoryImageAck {
        try await upload("api/seller/categories/\(id)/image",
                         field: "photo", filename: "category.jpg", mime: "image/jpeg",
                         fileData: jpeg, as: CategoryImageAck.self)
    }

    func deleteCategoryCover(id: Int) async throws {
        _ = try await delete("api/seller/categories/\(id)/image", as: Phase2BoolAck.self)
    }
}
