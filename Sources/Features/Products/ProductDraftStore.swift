import Foundation

// ============================================================================
//  Черновик НОВОГО товара (паритет с Android: SavedStateHandle в
//  ProductEditScreen). Телефон выгрузил приложение, пока продавец был в
//  другом приложении, — при следующем «Новый товар» форма возвращается
//  заполненной, а не пустой.
//
//  Хранится в UserDefaults отдельно для пары «аккаунт + организация»: черновик
//  одной точки не всплывает в другой. Пишется при уходе приложения в фон, при
//  закрытии экрана без явного «Закрыть» и перед каждой попыткой создания;
//  стирается после создания товара и по «Закрыть».
// ============================================================================

struct ProductDraft: Codable, Equatable {
    var name = ""
    var descriptionText = ""
    var categoryId: Int?
    var type = "product"
    var price = ""
    var priceOld = ""
    var unit = ""
    var weight = ""
    var article = ""
    var barcode = ""
    var tags: [String] = []
    var allergens: [String] = []
    var calories = ""
    var proteins = ""
    var fats = ""
    var carbs = ""
    var status = "active"
    var isAvailable = true
    var isMarked = false
    /// Последняя попытка создания ушла на сервер, а ответа не было (обрыв,
    /// выгрузка приложения посреди запроса): товар мог уже создаться.
    var maybeSent = false
    var savedAt = Date()

    /// Есть что восстанавливать: хоть одно поле заполнено.
    var hasContent: Bool {
        let texts = [name, descriptionText, price, priceOld, weight, article, barcode,
                     calories, proteins, fats, carbs]
        return texts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            || !tags.isEmpty || !allergens.isEmpty || categoryId != nil
    }
}

@MainActor
enum ProductDraftStore {
    /// Черновик старше недели не восстанавливаем: это уже не «вернулся к форме».
    private static let maxAge: TimeInterval = 7 * 24 * 3600
    private static let prefix = "seller_product_draft_v1_"

    /// Ключ черновика для текущих аккаунта и организации. Карточка берёт его
    /// ОДИН раз при открытии и дальше пользуется только им: переключение
    /// магазина (в т.ч. по push) иначе писало черновик точки А под ключом Б,
    /// а clear() стирал черновик Б.
    static func currentKey() -> String? {
        guard let shop = Session.shared.activeShopId else { return nil }
        let user = Session.shared.user?.id ?? 0
        return prefix + "\(user)_\(shop)"
    }

    static func load(key: String?) -> ProductDraft? {
        guard let k = key, let data = UserDefaults.standard.data(forKey: k),
              let d = try? JSONDecoder().decode(ProductDraft.self, from: data) else { return nil }
        guard Date().timeIntervalSince(d.savedAt) < maxAge, d.hasContent else {
            UserDefaults.standard.removeObject(forKey: k)
            return nil
        }
        return d
    }

    static func save(_ draft: ProductDraft, key: String?) {
        guard let k = key else { return }
        guard draft.hasContent else { UserDefaults.standard.removeObject(forKey: k); return }
        var d = draft
        d.savedAt = Date()
        if let data = try? JSONEncoder().encode(d) { UserDefaults.standard.set(data, forKey: k) }
    }

    static func clear(key: String?) {
        guard let k = key else { return }
        UserDefaults.standard.removeObject(forKey: k)
    }

    /// «Выйти из аккаунта» вручную: черновики всех точек этого телефона стираем —
    /// набранное не должно достаться следующему, кто войдёт.
    static func clearAll() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix(prefix) { d.removeObject(forKey: k) }
    }
}
