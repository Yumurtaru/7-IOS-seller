import Foundation

// ============================================================================
//  Сканер штрихкода: чистая логика без камеры и экранов (паритет с Android core/BarcodeLogic.kt).
//   1. normalize — приводим прочитанную строку к тому, что кладём в поле «Штрихкод»
//   2. Confirmer — защита от ложного чтения линейных кодов (два одинаковых чтения подряд)
//  Сервер (seller_products.php): barcode — строка до 64 знаков, пустая — NULL, не уникален.
//  Тексты для людей — дословно те же, что на Android.
// ============================================================================

/// Какой код прочитали. Нужен, чтобы по-разному проверять цифры и коды маркировки.
enum BarcodeKind {
    /// EAN-13 (в т.ч. UPC-A), EAN-8 — цифры с контрольной цифрой GS1.
    case gtin
    /// UPC-E: 8 цифр с контрольной цифрой по другому правилу — берём как есть.
    case upce
    /// ITF (ITF-14 и Interleaved 2 of 5): 14 цифр — с контрольной цифрой GS1, иначе как есть (как на Android).
    case itf
    /// Code128 / Code39 / Code93 — любая печатная строка, как на Android.
    case other
    /// DataMatrix («Честный знак», GS1): читается с первого раза.
    case dataMatrix
}

/// Итог чтения: что положить в поле и взято ли это из кода маркировки.
struct BarcodeScanResult: Equatable {
    let value: String
    let fromMarking: Bool
}

enum BarcodeLogic {
    /// Больше сервер не примет.
    static let maxLength = 64

    /// Подпись под полем, если штрихкод вынут из кода маркировки.
    static let markingNote = "Штрихкод взят из кода маркировки"

    /// Подпись под полем поиска, если после скана ни одна позиция не нашлась (склад, документы, закупки, стоп-лист).
    static let notFoundNote = "Товар с таким штрихкодом не найден"

    /// Индекс единственной позиции, чей штрихкод (после trim) РОВНО равен коду; nil — совпадений нет или их несколько.
    /// Паритет с Android BarcodeLogic.exactMatch. Пустой код ничего не совпадает.
    static func exactMatch(code: String, barcodes: [String?]) -> Int? {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { return nil }
        var found: Int?
        for (i, b) in barcodes.enumerated() {
            guard let raw = b else { continue }
            if raw.trimmingCharacters(in: .whitespacesAndNewlines) == c {
                if found != nil { return nil }
                found = i
            }
        }
        return found
    }

    /// nil — чтение игнорируем (мусор, неверная контрольная цифра, не GS1 DataMatrix) и сканируем дальше.
    static func normalize(_ raw: String, kind: BarcodeKind) -> BarcodeScanResult? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = removeGroupSeparators(s)
        s = stripSymbologyPrefix(s)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if kind == .dataMatrix { return marking(s) }
        return linear(s, kind: kind)
    }

    // ── Разбор ───────────────────────────────────────────────────────────────

    /// Разделитель групп GS (U+001D) в коде маркировки в штрихкод не нужен.
    private static func removeGroupSeparators(_ s: String) -> String {
        var kept = String.UnicodeScalarView()
        for c in s.unicodeScalars where c.value != 0x1D { kept.append(c) }
        return String(kept)
    }

    /// Префикс символики AIM: «]» + буква + цифра в начале («]d2», «]C1», «]e0», «]E0»…).
    private static func stripSymbologyPrefix(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        guard u.count >= 3, u[0].value == 0x5D else { return s }
        let letter = u[1].value
        let isLetter = (letter >= 65 && letter <= 90) || (letter >= 97 && letter <= 122)
        let isDigit = u[2].value >= 48 && u[2].value <= 57
        guard isLetter && isDigit else { return s }
        var rest = String.UnicodeScalarView()
        for c in u[3...] { rest.append(c) }
        return String(rest)
    }

    private static func isDigits(_ s: String) -> Bool {
        if s.isEmpty { return false }
        for b in s.utf8 where b < 48 || b > 57 { return false }
        return true
    }

    /// Контрольная цифра GS1 (mod 10): EAN-8, UPC-A, EAN-13, GTIN-14. Последняя цифра — контрольная.
    static func gs1CheckValid(_ digits: String) -> Bool {
        guard isDigits(digits), digits.utf8.count >= 2 else { return false }
        let d = digits.utf8.map { Int($0) - 48 }
        var sum = 0
        var weight = 3
        var i = d.count - 2
        while i >= 0 {
            sum += d[i] * weight
            weight = (weight == 3) ? 1 : 3
            i -= 1
        }
        return (10 - sum % 10) % 10 == d[d.count - 1]
    }

    /// Код маркировки GS1: «01» + 14 цифр GTIN. Иначе чтение не наше — игнорируем.
    private static func marking(_ s: String) -> BarcodeScanResult? {
        let head = String(s.prefix(16))
        guard head.count == 16, head.hasPrefix("01") else { return nil }
        let gtin = String(head.dropFirst(2))
        guard gtin.count == 14, isDigits(gtin) else { return nil }
        // GTIN-14 с ведущим нулём и верной контрольной цифрой — это обычный EAN-13.
        if gtin.hasPrefix("0") && gs1CheckValid(gtin) {
            return BarcodeScanResult(value: String(gtin.dropFirst()), fromMarking: true)
        }
        return BarcodeScanResult(value: gtin, fromMarking: true)
    }

    private static func linear(_ s: String, kind: BarcodeKind) -> BarcodeScanResult? {
        guard s.count <= maxLength else { return nil }
        // Управляющие символы в штрихкоде — мусор (как на Android).
        for c in s.unicodeScalars where c.value < 0x20 || c.value == 0x7F {
            return nil
        }
        switch kind {
        case .gtin:
            // EAN-8 / UPC-A / EAN-13 — только с верной контрольной цифрой.
            let n = s.count
            guard isDigits(s), n == 8 || n == 12 || n == 13, gs1CheckValid(s) else { return nil }
            // UPC-A (12) приводим к EAN-13: на iOS он обычно и так приходит с нулём, на Android — 12 цифр.
            return BarcodeScanResult(value: n == 12 ? "0" + s : s, fromMarking: false)
        case .itf:
            // ITF-14 — с проверкой контрольной цифры; ITF другой длины — как есть.
            if s.count == 14 && isDigits(s) && !gs1CheckValid(s) { return nil }
            return BarcodeScanResult(value: s, fromMarking: false)
        case .upce, .other, .dataMatrix:
            // UPC-E — как есть (своя контрольная цифра, по развёрнутому коду); Code128/39/93, ITF — любая печатная строка.
            return BarcodeScanResult(value: s, fromMarking: false)
        }
    }

    // ── Защита от ложного чтения ─────────────────────────────────────────────

    /// Линейный код принимаем, только когда ОДНО И ТО ЖЕ нормализованное значение прочитано
    /// два раза подряд в пределах ~1,5 с. DataMatrix — с первого раза (в нём есть коррекция ошибок).
    struct Confirmer {
        static let window: TimeInterval = 1.5
        // Время последнего чтения по КАЖДОМУ значению: два кода в кадре читаются вперемешку A, B, A, B —
        // с одним «последним значением» подтверждения не было бы никогда (как на Android).
        private var seen: [String: TimeInterval] = [:]

        init() {}

        /// now — любое монотонное время в секундах. true — значение подтверждено.
        mutating func accept(_ value: String, kind: BarcodeKind, now: TimeInterval) -> Bool {
            if kind == .dataMatrix {
                reset()
                return true
            }
            // Устаревшие (и «из будущего») чтения забываем.
            seen = seen.filter { now - $0.value >= 0 && now - $0.value <= Confirmer.window }
            if seen[value] != nil {
                reset()
                return true
            }
            seen[value] = now
            return false
        }

        mutating func reset() {
            seen = [:]
        }
    }
}
