import Foundation

// ============================================================================
//  Волна O1 — оптовая цена от количества: чистая логика редактора продавца.
//  Деньги — Decimal. Тексты дословно как на Android продавца.
//  Формула (только для показа; итог считает сервер):
//    eff = ступени с minQty > 0 и 0 < price < retail, по возрастанию minQty.
// ============================================================================

enum Wholesale {
    static let maxTiers = 5

    static let hint = "Цена ступени действует на весь объём. Чем больше берут — тем дешевле."
    static let errMax = "Не больше 5 ступеней"
    static let errQty = "Количество должно быть больше нуля"
    static let errPiece = "Для штучного товара — целое число от 2"
    static let errPrice = "Оптовая цена должна быть ниже розничной"
    static let errPriceEmpty = "Укажите оптовую цену ступени"
    static let errOrder = "С ростом количества цена должна снижаться"
    static let errDup = "Одинаковое количество в двух ступенях"

    /// Строка редактора: оба поля — текст как ввёл продавец.
    struct Row: Identifiable, Equatable {
        var id = UUID()
        var qty = ""
        var price = ""
        var isEmpty: Bool {
            qty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && price.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // ── Показ ───────────────────────────────────────────────────────────────

    /// Единица товара; нет/пусто — «шт».
    static func unitLabel(_ unit: String?) -> String {
        let u = (unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? "шт" : u
    }

    private static let qtyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.decimalSeparator = ","
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 3
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    /// 25 → «25», 2.5 → «2,5» (до 3 знаков).
    static func qtyText(_ v: Double) -> String {
        if abs(v - v.rounded()) < 1e-9 { return String(Int(v.rounded())) }
        return qtyFormatter.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    /// Ступени, которые действуют: minQty > 0, 0 < цена < розницы; по возрастанию.
    static func eff(_ tiers: [PriceTier]?, retail: Decimal?) -> [PriceTier] {
        guard let retail = retail, retail > 0 else { return [] }
        return (tiers ?? [])
            .filter { ($0.minQty ?? 0) > 0 && ($0.price ?? 0) > 0 && ($0.price ?? 0) < retail }
            .sorted { ($0.minQty ?? 0) < ($1.minQty ?? 0) }
    }

    /// Метка списка товаров: «опт от 25 кг» (первая действующая ступень). Нет опта — nil.
    static func listLabel(tiers: [PriceTier]?, retail: Decimal?, unit: String?) -> String? {
        guard let first = eff(tiers, retail: retail).first, let q = first.minQty else { return nil }
        return "опт от \(qtyText(q)) \(unitLabel(unit))"
    }

    // ── Редактор ────────────────────────────────────────────────────────────

    /// Деньги ступени для поля ввода: 37 → «37», 37.5 → «37.5».
    static func priceInput(_ p: Decimal?) -> String { p.map { "\($0)" } ?? "" }

    static func rows(from tiers: [PriceTier]?) -> [Row] {
        (tiers ?? []).sorted { ($0.minQty ?? 0) < ($1.minQty ?? 0) }
            .map { Row(qty: $0.minQty.map(qtyText) ?? "", price: priceInput($0.price)) }
    }

    /// Штучный: единица «шт» (или пусто) и нет признака дробного количества.
    static func isPiece(unit: String?, fractional: Bool) -> Bool {
        if fractional { return false }
        let u = unitLabel(unit).lowercased().replacingOccurrences(of: ".", with: "")
        return u == "шт" || u == "штука" || u == "штук"
    }

    private struct Parsed { var qty: Decimal?; var price: Decimal? }

    /// Пустые строки отброшены; поле, которое не разобралось, — nil.
    private static func parsed(_ rows: [Row]) -> [Parsed] {
        rows.filter { !$0.isEmpty }.map {
            Parsed(qty: Money.strict($0.qty.trimmingCharacters(in: .whitespacesAndNewlines), maxFraction: 3),
                   price: Money.strict($0.price.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    /// Проверка до отправки. nil — всё в порядке. retail — розница из поля цены (nil — не разобрана).
    static func validate(rows: [Row], retail: Decimal?, piece: Bool) -> String? {
        let items = parsed(rows)
        if items.count > maxTiers { return errMax }
        for it in items {
            guard let q = it.qty, q > 0 else { return errQty }
            if piece {
                let v = NSDecimalNumber(decimal: q).doubleValue
                if abs(v - v.rounded()) > 1e-9 || v < 2 { return errPiece }
            }
            guard let p = it.price, p > 0 else { return errPriceEmpty }
            if let r = retail, p >= r { return errPrice }
        }
        let sorted = items.sorted { ($0.qty ?? 0) < ($1.qty ?? 0) }
        if sorted.count > 1 {
            for i in 1..<sorted.count where sorted[i].qty == sorted[i - 1].qty { return errDup }
            for i in 1..<sorted.count where (sorted[i].price ?? 0) >= (sorted[i - 1].price ?? 0) { return errOrder }
        }
        return nil
    }

    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.decimalSeparator = "."
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Тело для POST/PUT: [{min_qty: число, price: "37.00"}]. Пустые строки отброшены.
    /// Вызывать после validate (разбор уже проверен).
    static func payload(rows: [Row]) -> [[String: Any]] {
        let out: [(Double, [String: Any])] = parsed(rows).compactMap { it in
            guard let q = it.qty, let p = it.price else { return nil }
            let price = moneyFormatter.string(from: NSDecimalNumber(decimal: p)) ?? "\(p)"
            let qd = NSDecimalNumber(decimal: q).doubleValue
            return (qd, ["min_qty": qd, "price": price])
        }
        return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}
