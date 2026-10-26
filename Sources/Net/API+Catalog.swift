import Foundation

// ============================================================================
//  Каталог: категории, наборы, модификаторы, артикулы.
//
//  Особенности контракта, которые видно только по коду сервера:
//   • у категории нет POST для картинки без файла — обложка грузится
//     multipart’ом на отдельный адрес;
//   • «набор» — это товар, у которого есть combo_items; создать пустой набор
//     нельзя, он появляется в списке только после первой позиции;
//   • группа модификаторов всегда создаётся ПРИ товаре, но живёт в общей
//     библиотеке магазина и может быть прикреплена к другим товарам.
// ============================================================================

extension API {

    // ── Категории ────────────────────────────────────────────────────────
    /// Та же ручка, что и categories() в API+Seller, но с полным разбором:
    /// станция печати, дробность и наценка. Имя другое намеренно — две
    /// функции с одинаковой сигнатурой и разным типом ответа сделали бы
    /// каждый вызов неоднозначным.
    func catalogCategories() async throws -> [ProductCategory] {
        try await get("api/seller/categories", as: [ProductCategory].self)
    }

    func createCategory(name: String, parentId: Int? = nil, sortOrder: Int? = nil,
                        stationRoute: String? = nil) async throws -> IdAck {
        var body: [String: Any?] = ["name": name]
        // Без sort_order сервер ставит новую категорию в конец уровня
        // (seller_products.php); 0 ставил её первой. Ключ шлём только если задан.
        if let sortOrder { body["sort_order"] = sortOrder }
        if let parentId { body["parent_id"] = parentId }
        if let stationRoute { body["station_route"] = stationRoute }
        return try await post("api/seller/categories", body: body, as: IdAck.self)
    }

    func updateCategory(id: Int, name: String? = nil, isActive: Bool? = nil,
                        sortOrder: Int? = nil, stationRoute: String? = nil) async throws {
        var body: [String: Any?] = [:]
        if let name { body["name"] = name }
        if let isActive { body["is_active"] = isActive ? 1 : 0 }
        if let sortOrder { body["sort_order"] = sortOrder }
        if let stationRoute { body["station_route"] = stationRoute }
        _ = try await put("api/seller/categories/\(id)", body: body, as: Phase2BoolAck.self)
    }

    func deleteCategory(id: Int) async throws {
        _ = try await delete("api/seller/categories/\(id)", as: Phase2BoolAck.self)
    }

    /// А65: новый порядок ОДНОГО уровня (соседи с одним parent_id) одним
    /// запросом. Тело ответа не разбираем (EmptyData принимает любое, даже без
    /// data) — после успеха список перечитывается.
    func reorderCategories(ids: [Int]) async throws {
        _ = try await post("api/seller/categories/reorder", body: ["ids": ids], as: EmptyData.self)
    }

    /// Обложка категории. Сервер читает файл из поля «photo» multipart-формы
    /// ($_FILES['photo'] в routes/seller_products.php) — с полем «image» он
    /// отвечал «Файл не передан».
    func uploadCategoryImage(id: Int, jpeg: Data) async throws -> Phase2BoolAck {
        try await upload("api/seller/categories/\(id)/image",
                         field: "photo", filename: "category.jpg", mime: "image/jpeg",
                         fileData: jpeg, as: Phase2BoolAck.self)
    }

    // ── Наборы ───────────────────────────────────────────────────────────
    func combos() async throws -> [ComboSummary] {
        try await get("api/seller/combos", as: [ComboSummary].self)
    }

    func comboPickProducts() async throws -> [ComboPickProduct] {
        try await get("api/seller/combos/products", as: [ComboPickProduct].self)
    }

    func comboItems(comboId: Int) async throws -> [ComboItem] {
        try await get("api/seller/products/\(comboId)/combo-items", as: [ComboItem].self)
    }

    /// Добавить позицию или изменить её количество (сервер сам решает по паре id).
    func setComboItem(comboId: Int, productId: Int, qty: Int) async throws {
        _ = try await post("api/seller/products/\(comboId)/combo-items",
                           body: ["product_id": productId, "qty": qty], as: Phase2BoolAck.self)
    }

    func deleteComboItem(itemId: Int) async throws {
        _ = try await delete("api/seller/combo-items/\(itemId)", as: Phase2BoolAck.self)
    }

    // ── Модификаторы ─────────────────────────────────────────────────────
    /// Библиотека групп магазина со всеми опциями.
    func modifierGroups() async throws -> [ModifierGroup] {
        try await get("api/seller/modifier-groups", as: [ModifierGroup].self)
    }

    // Группы, прикреплённые к товару, читает productModifiers(productId:)
    // из API+Seller.swift — там ровно такая же ручка и тип ответа.

    /// Новая группа. Создаётся при товаре — так устроен сервер.
    func createModifierGroup(productId: Int, name: String, multiple: Bool,
                             required: Bool, minQty: Int, maxQty: Int?) async throws -> IdAck {
        try await post("api/seller/products/\(productId)/modifier-groups", body: [
            "name": name,
            "type": multiple ? "multiple" : "single",
            "is_required": required ? 1 : 0,
            "min_qty": minQty,
            "max_qty": maxQty,
        ], as: IdAck.self)
    }

    func deleteModifierGroup(id: Int) async throws {
        _ = try await delete("api/seller/modifier-groups/\(id)", as: Phase2BoolAck.self)
    }

    func addModifierOption(groupId: Int, name: String, price: Decimal,
                           article: String? = nil, barcode: String? = nil) async throws -> IdAck {
        try await post("api/seller/modifier-groups/\(groupId)/modifiers", body: [
            "name": name, "price": "\(price)", "article": article, "barcode": barcode,
        ], as: IdAck.self)
    }

    func deleteModifierOption(id: Int) async throws {
        _ = try await delete("api/seller/modifiers/\(id)", as: Phase2BoolAck.self)
    }

    func attachModifierGroup(productId: Int, groupId: Int) async throws {
        _ = try await post("api/seller/products/\(productId)/modifier-groups/\(groupId)/attach",
                           as: Phase2BoolAck.self)
    }

    func detachModifierGroup(productId: Int, groupId: Int) async throws {
        _ = try await delete("api/seller/products/\(productId)/modifier-groups/\(groupId)/detach",
                             as: Phase2BoolAck.self)
    }

    // ── Артикулы и штрихкоды ─────────────────────────────────────────────
    func articles() async throws -> [ArticleRow] {
        try await get("api/seller/articles", as: [ArticleRow].self)
    }

    /// Пакетное сохранение артикулов и штрихкодов.
    ///
    /// Сложить сюда `[[String: Any?]]` нельзя: makeRequest чистит nil только
    /// на верхнем уровне словаря, и nil внутри вложенных строк уронил бы
    /// JSONSerialization — запрос ушёл бы с пустым телом. Поэтому собираем
    /// строки сами, а пустая строка на сервере превращается в NULL (`?: null`).
    func saveArticles(_ rows: [ArticleEdit]) async throws -> ArticlesBulkAck {
        let payload: [[String: Any]] = rows.map { r in
            ["id": r.id, "article": r.article, "barcode": r.barcode]
        }
        return try await post("api/seller/articles/bulk", body: ["rows": payload], as: ArticlesBulkAck.self)
    }

    /// EAN-13 из внутреннего диапазона 200… — считает сервер.
    func generateBarcode(productId: Int) async throws -> BarcodeAck {
        try await post("api/seller/articles/\(productId)/gen-barcode", as: BarcodeAck.self)
    }
}
