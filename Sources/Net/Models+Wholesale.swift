import Foundation

// ============================================================================
//  Волна O1 — оптовая цена от количества. Ступень товара: от min_qty штук/кг
//  ВЕСЬ объём идёт по цене ступени. Декодер продавца — без convertFromSnakeCase,
//  поэтому ключи заданы явно. Все поля необязательные: старый сервер ключа
//  price_tiers не шлёт — nil (= «опта нет»).
// ============================================================================

struct PriceTier: Codable, Hashable {
    @LenientDouble var minQty: Double?      // "min_qty": 25 или 2.5
    @LenientDecimal var price: Decimal?     // "price": "37.00"
    enum CodingKeys: String, CodingKey { case minQty = "min_qty", price }
}

/// Массив ступеней: мусорный элемент пропускаем, не-массив — nil.
@propertyWrapper
struct LenientPriceTiers: Decodable {
    var wrappedValue: [PriceTier]?
    init(wrappedValue: [PriceTier]?) { self.wrappedValue = wrappedValue }

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        guard var c = try? decoder.unkeyedContainer() else { wrappedValue = nil; return }
        var out: [PriceTier] = []
        while !c.isAtEnd {
            if let t = try? c.decode(PriceTier.self) { out.append(t) }
            else if (try? c.decode(Skip.self)) == nil { break }
        }
        wrappedValue = out
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: LenientPriceTiers.Type, forKey key: Key) throws -> LenientPriceTiers {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientPriceTiers(wrappedValue: nil)
    }
}

// ============================================================================
//  А1331 — опт категории: «от N — скидка X %» для всех товаров категории.
//  GET /api/seller/categories → wholesale {mode: inherit|rule|off, tiers: [{min_qty, percent}]};
//  GET /api/seller/products/{id} → wholesale_category {category_id, category_name, rule: [...]} | null.
//  Старый сервер этих ключей не шлёт — nil. Числа — число или строка (толерантно).
// ============================================================================

struct CategoryWholesaleTier: Decodable, Hashable {
    @LenientDouble var minQty: Double?
    @LenientDouble var percent: Double?
    enum CodingKeys: String, CodingKey { case minQty = "min_qty", percent }
}

struct CategoryWholesale: Decodable {
    var mode: String?
    var tiers: [CategoryWholesaleTier]?

    init(mode: String?, tiers: [CategoryWholesaleTier]?) { self.mode = mode; self.tiers = tiers }

    enum CodingKeys: String, CodingKey { case mode, tiers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil
        tiers = (try? c.decodeIfPresent([CategoryWholesaleTier].self, forKey: .tiers)) ?? nil
    }
}

/// Правило категории в карточке товара: категория-источник (своя или родительская) и ступени в процентах.
struct WholesaleCategoryInfo: Decodable {
    @LenientInt var categoryId: Int?
    var categoryName: String?
    var rule: [CategoryWholesaleTier]?

    enum CodingKeys: String, CodingKey {
        case categoryId = "category_id", categoryName = "category_name", rule
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _categoryId = (try? c.decodeIfPresent(LenientInt.self, forKey: .categoryId)) ?? LenientInt(wrappedValue: nil)
        categoryName = (try? c.decodeIfPresent(String.self, forKey: .categoryName)) ?? nil
        rule = (try? c.decodeIfPresent([CategoryWholesaleTier].self, forKey: .rule)) ?? nil
    }
}

/// Необязательный объект: мусор вместо объекта не роняет всю карточку/категорию — просто nil.
@propertyWrapper
struct LenientObject<T: Decodable>: Decodable {
    var wrappedValue: T?
    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws { wrappedValue = try? T(from: decoder) }
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: LenientObject<T>.Type, forKey key: Key) throws -> LenientObject<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientObject<T>(wrappedValue: nil)
    }
}
