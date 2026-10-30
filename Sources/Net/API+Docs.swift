import Foundation

// ============================================================================
//  Документы склада, ингредиенты и тех. карты.
//
//  Все ручки этой группы идут через warehouseShop() на сервере — у магазина
//  без склада (услуги, витрина) они отвечают «Склад недоступен для этого типа
//  магазина». Текст показываем как есть.
//
//  Адрес именно /api/seller/stock-documents, а не /documents: на последнем
//  висят документы организации (лицензии), и складские ручки были им
//  перекрыты — роутер берёт первое совпадение по порядку регистрации.
// ============================================================================

extension API {

    // ── Документы ────────────────────────────────────────────────────────
    func documents(type: String? = nil, status: String? = nil) async throws -> [StockDocument] {
        var q: [String: String] = [:]
        if let type, !type.isEmpty { q["type"] = type }
        if let status, !status.isEmpty { q["status"] = status }
        return try await get("api/seller/stock-documents", query: q, as: [StockDocument].self)
    }

    /// А316: страница списка (page, limit; meta.has_more). Старый сервер параметры
    /// не знает — отдаёт 200 последних без meta, тогда hasMore = false.
    func documentsPage(type: String? = nil, status: String? = nil, page: Int,
                       limit: Int) async throws -> (items: [StockDocument], hasMore: Bool) {
        var q: [String: String] = ["page": String(page), "limit": String(limit)]
        if let type, !type.isEmpty { q["type"] = type }
        if let status, !status.isEmpty { q["status"] = status }
        let (rows, meta) = try await getWithMeta("api/seller/stock-documents", query: q, as: [StockDocument].self)
        let more = (meta["has_more"] as? Bool) ?? ((meta["has_more"] as? NSNumber)?.boolValue ?? false)
        return (rows, more)
    }

    func document(id: Int) async throws -> StockDocumentDetail {
        try await get("api/seller/stock-documents/\(id)", as: StockDocumentDetail.self)
    }

    /// Создание документа. Строки собираем вручную: makeRequest чистит nil
    /// только на верхнем уровне, и nil внутри вложенных строк уронил бы
    /// JSONSerialization — запрос ушёл бы с пустым телом.
    func createDocument(type: DocType, warehouseId: Int?, warehouseToId: Int?,
                        supplierId: Int?, comment: String?, post: Bool,
                        items: [DocItemDraft],
                        supplierDocNo: String? = nil, supplierDocDate: String? = nil,
                        keys: IdempotencyKeys? = nil) async throws -> DocCreateAck {
        var body: [String: Any?] = [
            "type": type.rawValue,
            "items": items.map { $0.payload },
            "post": post ? 1 : 0,
        ]
        if let warehouseId, warehouseId > 0 { body["warehouse_id"] = warehouseId }
        if let warehouseToId, warehouseToId > 0 { body["warehouse_to_id"] = warehouseToId }
        if let supplierId, supplierId > 0 { body["supplier_id"] = supplierId }
        if let comment, !comment.isEmpty { body["comment"] = comment }
        // А99: накладная поставщика № (до 64 знаков) и дата YYYY-MM-DD — только если
        // заданы; иначе ключей нет, и документ уходит как раньше.
        if let supplierDocNo, !supplierDocNo.isEmpty { body["supplier_doc_no"] = supplierDocNo }
        if let supplierDocDate, !supplierDocDate.isEmpty { body["supplier_doc_date"] = supplierDocDate }
        // self обязателен: у метода есть параметр post: Bool, и без него
        // имя post разрешается в этот параметр, а не в метод запроса.
        // П-27.14: ключ повтора — повторное «Создать» после обрыва без дубля документа.
        // detailed: экрану нужен HTTP-статус (409 / 403 с document_id — черновик уже сохранён).
        // keys — ключи окна документа: без срока, пока окно открыто (повтор через 6 минут — тот же ключ).
        return try await self.postKeyed("api/seller/stock-documents", body: body, as: DocCreateAck.self, detailed: true, keys: keys)
    }

    /// Проведение: остатки двигаются только здесь, до этого документ — черновик.
    /// П-27.14: с ключом повтора — повтор после обрыва получает тот же ответ, а не отказ.
    func postDocument(id: Int) async throws -> DocPostAck {
        try await postKeyed("api/seller/stock-documents/\(id)/post", as: DocPostAck.self)
    }

    /// Отмена проведения — сервер разворачивает движения обратно. Черновик
    /// (А316) — становится cancelled без движений ({cancelled, draft}).
    func cancelDocument(id: Int) async throws -> DocPostAck {
        try await post("api/seller/stock-documents/\(id)/cancel", as: DocPostAck.self)
    }

    func duplicateDocument(id: Int) async throws -> DocCreateAck {
        try await post("api/seller/stock-documents/\(id)/duplicate", as: DocCreateAck.self)
    }

    // Поиск по складу — stockSearch(q:) и список складов — warehouses()
    // уже объявлены в API+Seller3.swift, повторно не объявляем.

    // ── Ингредиенты ──────────────────────────────────────────────────────
    func ingredients() async throws -> [Ingredient] {
        try await get("api/seller/ingredients", as: [Ingredient].self)
    }

    func createIngredient(name: String, unit: String, minQty: Decimal,
                          pricePerUnit: Decimal, category: String?) async throws -> IdAck {
        try await post("api/seller/ingredients", body: [
            "name": name, "unit": unit,
            "min_qty": "\(minQty)", "price_per_unit": "\(pricePerUnit)",
            "category": category,
        ], as: IdAck.self)
    }

    func deleteIngredient(id: Int) async throws {
        _ = try await delete("api/seller/ingredients/\(id)", as: Phase2BoolAck.self)
    }

    // ── Тех. карты ───────────────────────────────────────────────────────
    // Чтение карты techCard(type:entityId:) и список модификаторов
    // tcModifiers() уже есть в API+Seller3.swift — здесь только сохранение,
    // которого там не было.

    func saveTechCard(type: String, entityId: Int, yieldWeight: String?, portions: Int?,
                      cookingTimeMin: Int?, process: String?, description: String? = nil,
                      items: [TechCardDraft]) async throws {
        var body: [String: Any?] = ["items": items.map { $0.payload }]
        if let yieldWeight, !yieldWeight.isEmpty { body["yield_weight"] = yieldWeight }
        if let portions, portions > 0 { body["portions"] = portions }
        if let cookingTimeMin, cookingTimeMin > 0 { body["cooking_time_min"] = cookingTimeMin }
        if let process, !process.isEmpty { body["process"] = process }
        // Сервер перезаписывает description при каждом сохранении (нет ключа —
        // NULL), поэтому описание из кабинета сайта возвращаем как было.
        if let description, !description.isEmpty { body["description"] = description }
        _ = try await post("api/seller/tech-cards/\(type)/\(entityId)", body: body, as: TechCardSaveAck.self)
    }
}

struct TechCardSaveAck: Decodable {
    @LenientInt var techCardId: Int?
    enum CodingKeys: String, CodingKey { case techCardId = "tech_card_id" }
}
