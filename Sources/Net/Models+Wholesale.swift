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
