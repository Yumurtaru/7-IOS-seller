import Foundation

// ============================================================================
//  К-57 (лояльность «кэшбэк или скидка») и П-72 п.4 (замены товаров).
//  Продавец декодирует БЕЗ convertFromSnakeCase — у всех моделей явные CodingKeys.
//  Все поля необязательные; вложенные модели не бросают исключений на мусоре,
//  чтобы кривой блок не ронял разбор всего заказа / программы.
// ============================================================================

/// loyalty.category_rules[]: {category_id:int, percent:"5.00"}. Редактируется в кабинете.
struct LoyaltyCategoryRule: Decodable {
    @LenientInt var categoryId: Int?
    @LenientDecimal var percent: Decimal?
    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id"
        case percent
    }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        _categoryId = (try? c?.decode(LenientInt.self, forKey: .categoryId)) ?? LenientInt(wrappedValue: nil)
        _percent = (try? c?.decode(LenientDecimal.self, forKey: .percent)) ?? LenientDecimal(wrappedValue: nil)
    }
}

/// loyalty.restricted[]: {scope:"category"|"product", id:int, kind:"tobacco"|"alcohol_mrc"}.
struct LoyaltyRestrictedItem: Decodable {
    var scope: String?
    @LenientInt var id: Int?
    var kind: String?
    enum CodingKeys: String, CodingKey { case scope, id, kind }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        scope = (try? c?.decodeIfPresent(String.self, forKey: .scope)) ?? nil
        _id = (try? c?.decode(LenientInt.self, forKey: .id)) ?? LenientInt(wrappedValue: nil)
        kind = (try? c?.decodeIfPresent(String.self, forKey: .kind)) ?? nil
    }
}

/// items[].substitute.original — исходная строка, которую заменяют.
struct SubstituteOriginal: Decodable {
    var name: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var price: Decimal?
    enum CodingKeys: String, CodingKey { case name, qty, price }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        name = (try? c?.decodeIfPresent(String.self, forKey: .name)) ?? nil
        _qty = (try? c?.decode(LenientDecimal.self, forKey: .qty)) ?? LenientDecimal(wrappedValue: nil)
        _price = (try? c?.decode(LenientDecimal.self, forKey: .price)) ?? LenientDecimal(wrappedValue: nil)
    }
}

/// items[].substitute (П-72 п.4). qty "2.000", price "60.00", sum "120.00" — строками.
/// status: pending|accepted|declined|auto; outcome: replaced|removed|nil.
struct SubstituteInfo: Decodable {
    @LenientInt var productId: Int?
    var name: String?
    var photo: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var sum: Decimal?
    var status: String?
    var outcome: String?
    var deadlineAt: String?
    @LenientBool var needsCall: Bool?
    var original: SubstituteOriginal?

    enum CodingKeys: String, CodingKey {
        case name, photo, qty, price, sum, status, outcome, original
        case productId = "product_id"
        case deadlineAt = "deadline_at"
        case needsCall = "needs_call"
    }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        _productId = (try? c?.decode(LenientInt.self, forKey: .productId)) ?? LenientInt(wrappedValue: nil)
        name = (try? c?.decodeIfPresent(String.self, forKey: .name)) ?? nil
        photo = (try? c?.decodeIfPresent(String.self, forKey: .photo)) ?? nil
        _qty = (try? c?.decode(LenientDecimal.self, forKey: .qty)) ?? LenientDecimal(wrappedValue: nil)
        _price = (try? c?.decode(LenientDecimal.self, forKey: .price)) ?? LenientDecimal(wrappedValue: nil)
        _sum = (try? c?.decode(LenientDecimal.self, forKey: .sum)) ?? LenientDecimal(wrappedValue: nil)
        status = (try? c?.decodeIfPresent(String.self, forKey: .status)) ?? nil
        outcome = (try? c?.decodeIfPresent(String.self, forKey: .outcome)) ?? nil
        deadlineAt = (try? c?.decodeIfPresent(String.self, forKey: .deadlineAt)) ?? nil
        _needsCall = (try? c?.decode(LenientBool.self, forKey: .needsCall)) ?? LenientBool(wrappedValue: nil)
        original = (try? c?.decodeIfPresent(SubstituteOriginal.self, forKey: .original)) ?? nil
    }
}

/// GET /api/seller/substitution/settings → {timeout_min}.
struct SubstitutionSettings: Decodable {
    @LenientInt var timeoutMin: Int?
    enum CodingKeys: String, CodingKey { case timeoutMin = "timeout_min" }
}

/// Хелперы подписей замены (общие для карточки заказа).
enum Substitution {
    /// «2026-11-12T20:00:00+03:00» / «2026-11-12 20:00:00» → «20:00» (время магазина, как прислал сервер).
    static func hhmm(_ iso: String?) -> String? {
        guard let s = iso, let r = s.range(of: #"[T ](\d{2}:\d{2})"#, options: .regularExpression) else { return nil }
        return String(s[r].dropFirst())
    }

    /// Выбор клиента «если товара нет».
    static func choiceLabel(_ code: String?) -> String? {
        switch code {
        case "similar": return "Если нет: заменить похожим"
        case "call": return "Если нет: позвонить"
        case "remove": return "Если нет: убрать"
        default: return nil
        }
    }

    /// Заказ уже в конце пути — замену предлагать поздно.
    static func orderClosed(_ status: String?) -> Bool {
        ["completed", "delivered", "cancelled", "refunded", "rejected"].contains(status ?? "")
    }
}
