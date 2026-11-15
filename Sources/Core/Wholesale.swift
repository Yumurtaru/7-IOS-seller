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
        guard v.isFinite, abs(v) < 1e15 else { return "—" }   // Int(∞/огромное) роняет приложение
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
    /// П-70: единица не указана — без единицы («опт от 25»), как на сайте: пустая единица — не «шт».
    static func listLabel(tiers: [PriceTier]?, retail: Decimal?, unit: String?) -> String? {
        guard let first = eff(tiers, retail: retail).first, let q = first.minQty else { return nil }
        let u = (unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if u.isEmpty { return "опт от \(qtyText(q))" }
        return "опт от \(qtyText(q)) \(u)"
    }

    // ── Редактор ────────────────────────────────────────────────────────────

    /// Деньги ступени для поля ввода: 37 → «37», 37.5 → «37.5».
    static func priceInput(_ p: Decimal?) -> String { p.map { "\($0)" } ?? "" }

    static func rows(from tiers: [PriceTier]?) -> [Row] {
        (tiers ?? []).sorted { ($0.minQty ?? 0) < ($1.minQty ?? 0) }
            .map { Row(qty: $0.minQty.map(qtyText) ?? "", price: priceInput($0.price)) }
    }

    /// Единицы, которые сервер считает дробными (регистр и точка в конце не важны).
    private static let fractionalUnits: Set<String> = ["кг", "kg", "г", "g", "гр", "л", "l", "мл", "ml", "м", "m"]

    /// Штучный ли товар — правило сервера (ответ на П-69): решает qty_fractional (товар, затем категория;
    /// true — дробный, false — штучный); не задан нигде — по единице: кг/kg/г/g/гр/л/l/мл/ml/м/m — дробный,
    /// всё остальное (в т.ч. пустая единица) — штучный. Так же на Android.
    static func isPiece(unit: String?, fractional: Bool? = nil) -> Bool {
        if let f = fractional { return !f }
        var u = (unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while u.hasSuffix(".") { u.removeLast() }
        u = u.trimmingCharacters(in: .whitespacesAndNewlines)
        return !fractionalUnits.contains(u)
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
            let qd = NSDecimalNumber(decimal: q).doubleValue   // только для сортировки
            return (qd, ["min_qty": NSDecimalNumber(decimal: q), "price": price])
        }
        return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}

// ============================================================================
//  А1331 — опт категории («от N — скидка X %»). Чистая логика формы категории,
//  метки в списке и подсказки в карточке товара. Тексты — как в кабинете сайта.
// ============================================================================

enum CategoryWholesaleLogic {
    static let maxTiers = 5
    static let modeInherit = "inherit"
    static let modeRule = "rule"
    static let modeOff = "off"

    static let errEmpty = "Добавьте хотя бы одну ступень «от … — скидка … %» или выберите «Без опта»"
    static let errMax = "Не больше 5 ступеней"
    static let errQty = "Количество «от» должно быть больше нуля"
    static let errPercent = "Скидка — больше 0 и меньше 100 %"
    static let errOrder = "Чем больше берут, тем больше скидка: количество и скидка должны расти"

    /// Строка редактора: оба поля — текст как ввёл продавец.
    struct Row: Identifiable, Equatable {
        var id = UUID()
        var qty = ""
        var pct = ""
        var isEmpty: Bool {
            qty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && pct.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        /// Для сравнения «менялось ли» — без id.
        var key: String { qty + "|" + pct }
    }

    static func rows(from w: CategoryWholesale?) -> [Row] {
        (w?.tiers ?? []).sorted { ($0.minQty ?? 0) < ($1.minQty ?? 0) }.map {
            Row(qty: $0.minQty.map(Wholesale.qtyText) ?? "", pct: $0.percent.map(Wholesale.qtyText) ?? "")
        }
    }

    /// Режим из ответа сервера; неизвестный/пустой — «как у родителя».
    static func mode(from w: CategoryWholesale?) -> String {
        let m = (w?.mode ?? "").lowercased()
        return (m == modeRule || m == modeOff) ? m : modeInherit
    }

    private struct Parsed { var qty: Decimal; var pct: Decimal }

    private static func parse(_ rows: [Row]) -> [Parsed]? {
        var out: [Parsed] = []
        for r in rows where !r.isEmpty {
            guard let q = Money.strict(r.qty.trimmingCharacters(in: .whitespacesAndNewlines), maxFraction: 3), q > 0 else { return nil }
            guard let p = Money.strict(r.pct.trimmingCharacters(in: .whitespacesAndNewlines), maxFraction: 2), p > 0, p < 100 else { return nil }
            out.append(Parsed(qty: q, pct: p))
        }
        return out
    }

    /// Проверка ступеней (режим «Скидка от количества»). nil — всё в порядке.
    static func validate(rows: [Row]) -> String? {
        let filled = rows.filter { !$0.isEmpty }
        if filled.isEmpty { return errEmpty }
        if filled.count > maxTiers { return errMax }
        for r in filled {
            guard let q = Money.strict(r.qty.trimmingCharacters(in: .whitespacesAndNewlines), maxFraction: 3), q > 0 else { return errQty }
            guard let p = Money.strict(r.pct.trimmingCharacters(in: .whitespacesAndNewlines), maxFraction: 2), p > 0, p < 100 else { return errPercent }
        }
        guard let items = parse(rows) else { return errQty }
        let sorted = items.sorted { $0.qty < $1.qty }
        if sorted.count > 1 {
            for i in 1..<sorted.count where sorted[i].qty <= sorted[i - 1].qty || sorted[i].pct <= sorted[i - 1].pct { return errOrder }
        }
        return nil
    }

    /// Тело ключа wholesale. Вызывать после validate (для rule).
    static func payload(mode: String, rows: [Row]) -> [String: Any] {
        guard mode == modeRule, let items = parse(rows) else { return ["mode": mode, "tiers": [[String: Any]]()] }
        let tiers: [[String: Any]] = items.sorted { $0.qty < $1.qty }.map {
            ["min_qty": NSDecimalNumber(decimal: $0.qty), "percent": NSDecimalNumber(decimal: $0.pct)]
        }
        return ["mode": mode, "tiers": tiers]
    }

    /// Метка в списке категорий: «опт −5 % от 10, −12,5 % от 24» / «без опта». Иначе nil.
    static func badge(_ w: CategoryWholesale?) -> String? {
        guard let w = w else { return nil }
        let m = (w.mode ?? "").lowercased()
        if m == modeRule, let ts = w.tiers, !ts.isEmpty {
            let parts: [String] = ts.map { t in
                let p = Wholesale.qtyText(t.percent ?? 0)
                let q = Wholesale.qtyText(t.minQty ?? 0)
                return "−\(p) % от \(q)"
            }
            return "опт " + parts.joined(separator: ", ")
        }
        if m == modeOff { return "без опта" }
        return nil
    }

    /// Цена со скидкой, до копеек (только для показа; итог считает сервер).
    private static func discounted(retail: Decimal, percent: Double) -> Decimal {
        let p = Decimal(string: String(percent)) ?? 0
        var value = retail * (100 - p) / 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return rounded
    }

    /// Подсказка у оптовых цен товара. nil — у категории опта нет.
    static func productNote(_ info: WholesaleCategoryInfo?, ownTiers: Bool, retail: Decimal?, unit: String) -> String? {
        guard let info = info, let rule = info.rule, !rule.isEmpty else { return nil }
        let name = (info.categoryName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rows: [String] = rule.sorted { ($0.minQty ?? 0) < ($1.minQty ?? 0) }.map { t in
            let q = Wholesale.qtyText(t.minQty ?? 0)
            let p = Wholesale.qtyText(t.percent ?? 0)
            var s = "от \(q) \(unit) — скидка \(p) %"
            if let r = retail, r > 0 { s += " (\(Money.rub(discounted(retail: r, percent: t.percent ?? 0))))" }
            return s
        }
        let list = rows.joined(separator: "; ")
        if ownTiers { return "Опт категории «\(name)» (\(list)) не действует: у товара свои оптовые цены." }
        return "Действует опт категории «\(name)»: \(list). Чтобы задать свои цены, добавьте ступени выше."
    }
}
