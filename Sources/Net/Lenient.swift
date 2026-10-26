import Foundation

/// Сервер (PHP/MySQL DECIMAL) отдаёт десятичные значения строками: "4.00", "350.00".
/// Этот property wrapper декодирует Double? и из числа, и из строки, и из null —
/// чтобы строгий JSONDecoder в Swift не ронял весь объект.
@propertyWrapper
struct LenientDouble: Codable, Hashable {
    var wrappedValue: Double?
    init(wrappedValue: Double?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let d = try? c.decode(Double.self) { wrappedValue = d }
        else if let i = try? c.decode(Int.self) { wrappedValue = Double(i) }
        else if let s = try? c.decode(String.self) { wrappedValue = Double(s) }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// Сервер отдаёт булевы как 0/1 (Int) или "0"/"1" (строки). Принимаем всё.
@propertyWrapper
struct LenientBool: Codable, Hashable {
    var wrappedValue: Bool?
    init(wrappedValue: Bool?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let b = try? c.decode(Bool.self) { wrappedValue = b }
        else if let i = try? c.decode(Int.self) { wrappedValue = i != 0 }
        else if let s = try? c.decode(String.self) { wrappedValue = (s == "1" || s.lowercased() == "true") }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// Сервер отдаёт целые иногда строкой или DECIMAL ("1.000"). Принимаем всё.
@propertyWrapper
struct LenientInt: Codable, Hashable {
    var wrappedValue: Int?
    init(wrappedValue: Int?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let i = try? c.decode(Int.self) { wrappedValue = i }
        else if let d = try? c.decode(Double.self) { wrappedValue = Self.int(d) }
        else if let s = try? c.decode(String.self) { wrappedValue = Int(s) ?? Double(s).flatMap { Self.int($0) } }
        else { wrappedValue = nil }
    }
    /// Int(Double) падает на NaN/бесконечности и числах за пределами Int — тогда nil.
    private static func int(_ d: Double) -> Int? {
        d.isFinite && abs(d) < 9e18 ? Int(d) : nil
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// ДЕНЬГИ (Фаза 1.9 аудита, канон SKILL.md): точный Decimal вместо Double.
/// Основной путь — из строки "0.00" БЕЗ потери точности (Decimal(string:)),
/// запасные — из Int/Double. Для всех новых денежных полей моделей использовать
/// именно @LenientDecimal; существующие @LenientDouble-деньги мигрируются
/// поэтапно (этап 2 — вместе со сборкой в Xcode).
@propertyWrapper
struct LenientDecimal: Codable, Hashable {
    var wrappedValue: Decimal?
    init(wrappedValue: Decimal?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let s = try? c.decode(String.self), let d = Decimal(string: s) { wrappedValue = d } // без потери точности
        else if let i = try? c.decode(Int.self) { wrappedValue = Decimal(i) }
        // Запасной путь — дробное число JSON. Decimal(Double) тащит двоичный хвост:
        // 150.3 становилось 150.30000000000001, и такое значение, подставленное в
        // поле формы (цена зоны доставки и т.п.), не проходило строгую проверку при
        // сохранении. Берём кратчайшую запись числа — её Double печатает точно.
        else if let dbl = try? c.decode(Double.self) { wrappedValue = Decimal(string: "\(dbl)") ?? Decimal(dbl) }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let v = wrappedValue { try c.encode("\(v)") } else { try c.encodeNil() }
    }
}

extension KeyedDecodingContainer {
    /// Чтобы отсутствующий ключ давал nil, а не ошибку «keyNotFound».
    func decode(_ type: LenientDouble.Type, forKey key: Key) throws -> LenientDouble {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientDouble(wrappedValue: nil)
    }
    func decode(_ type: LenientBool.Type, forKey key: Key) throws -> LenientBool {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientBool(wrappedValue: nil)
    }
    func decode(_ type: LenientInt.Type, forKey key: Key) throws -> LenientInt {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientInt(wrappedValue: nil)
    }
    func decode(_ type: LenientDecimal.Type, forKey key: Key) throws -> LenientDecimal {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientDecimal(wrappedValue: nil)
    }
}
