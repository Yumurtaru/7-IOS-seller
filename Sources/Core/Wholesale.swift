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

    // ── А1432: округление цены ступени ─────────────────────────────────────
    static let modeDown = "down"
    static let modeNearest = "nearest"
    static let modeUp = "up"
    /// Шаги в копейках → подпись выбора.
    static let stepOptions: [(cents: Int, title: String)] = [
        (1, "до копеек"), (10, "до 10 коп."), (50, "до 50 коп."), (100, "до рубля"),
        (500, "до 5 ₽"), (1000, "до 10 ₽"), (5000, "до 50 ₽"), (10000, "до 100 ₽")
    ]
    static let roundModeOptions: [(mode: String, title: String)] = [
        (modeDown, "вниз — в пользу покупателя"), (modeNearest, "до ближайшего"), (modeUp, "вверх")
    ]

    /// Шаг сервера ("1.00") → копейки; не из списка — 1 (до копеек).
    static func stepCents(_ r: CategoryRounding?) -> Int {
        guard let st = r?.step else { return 1 }
        var v = st * 100
        var out = Decimal()
        NSDecimalRound(&out, &v, 0, .plain)
        let c = NSDecimalNumber(decimal: out).intValue
        return stepOptions.contains { $0.cents == c } ? c : 1
    }

    static func roundMode(_ r: CategoryRounding?) -> String {
        let m = (r?.mode ?? "").lowercased()
        return (m == modeDown || m == modeUp) ? m : modeNearest
    }

    /// Шаг в виде денег строкой для запроса: 100 → "1.00".
    static func stepString(_ cents: Int) -> String {
        let k = cents % 100
        return "\(cents / 100)." + (k < 10 ? "0\(k)" : "\(k)")
    }

    static func stepTitle(_ cents: Int) -> String {
        stepOptions.first { $0.cents == cents }?.title ?? "до копеек"
    }

    static func modeWord(_ mode: String) -> String {
        mode == modeDown ? "вниз" : (mode == modeUp ? "вверх" : "до ближайшего")
    }

    /// Цена ступени в рублях: копейки = розница×100×(1−X/100), округление по шагу и способу.
    /// nil — ступень не действует (≤ 0 или не ниже розницы). Только для показа; итог считает сервер.
    static func tierPrice(retail: Decimal, percent: Double, stepCents: Int, mode: String) -> Decimal? {
        guard retail > 0, percent.isFinite else { return nil }
        let p = Decimal(string: String(percent)) ?? 0
        let step = Decimal(max(stepCents, 1))
        let raw = retail * 100 * (100 - p) / 100
        var units = raw / step
        var rounded = Decimal()
        let rm: NSDecimalNumber.RoundingMode = mode == modeDown ? .down : (mode == modeUp ? .up : .plain)
        NSDecimalRound(&rounded, &units, 0, rm)
        let price = rounded * step / 100
        if price <= 0 || price >= retail { return nil }
        return price
    }

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
    /// rounding — (шаг в копейках, способ); nil — ключ rounding не шлём (сервер оставит прежнее).
    static func payload(mode: String, rows: [Row], rounding: (cents: Int, mode: String)? = nil) -> [String: Any] {
        guard mode == modeRule, let items = parse(rows) else { return ["mode": mode, "tiers": [[String: Any]]()] }
        let tiers: [[String: Any]] = items.sorted { $0.qty < $1.qty }.map {
            ["min_qty": NSDecimalNumber(decimal: $0.qty), "percent": NSDecimalNumber(decimal: $0.pct)]
        }
        var out: [String: Any] = ["mode": mode, "tiers": tiers]
        if let r = rounding { out["rounding"] = ["step": stepString(r.cents), "mode": r.mode] }
        return out
    }

    /// Пример на цене продавца: «от 10 — 130 ₽ (−5,39 %)» или «от 10 — не действует».
    static func probeLines(rows: [Row], retail: Decimal, stepCents: Int, mode: String) -> [String] {
        let items = (parse(rows) ?? []).sorted { $0.qty < $1.qty }
        return items.map { it in
            let q = Wholesale.qtyText(NSDecimalNumber(decimal: it.qty).doubleValue)
            let pc = NSDecimalNumber(decimal: it.pct).doubleValue
            guard let price = tierPrice(retail: retail, percent: pc, stepCents: stepCents, mode: mode) else {
                return "от \(q) — не действует (цена не ниже розницы или ноль)"
            }
            let eff = NSDecimalNumber(decimal: (retail - price) / retail * 100).doubleValue
            let effText = String(format: "%.2f", eff).replacingOccurrences(of: ".", with: ",")
            return "от \(q) — \(Money.rub(price)) (−\(effText) %)"
        }
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
            var label = "опт " + parts.joined(separator: ", ")
            let cents = stepCents(w.rounding)
            if cents > 1 {
                label += " · округление \(stepTitle(cents)) \(modeWord(roundMode(w.rounding)))"
            }
            return label
        }
        if m == modeOff { return "без опта" }
        return nil
    }

    /// Подсказка у оптовых цен товара. nil — у категории опта нет.
    static func productNote(_ info: WholesaleCategoryInfo?, ownTiers: Bool, retail: Decimal?, unit: String) -> String? {
        guard let info = info, let rule = info.rule, !rule.isEmpty else { return nil }
        let name = (info.categoryName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cents = stepCents(info.rounding)
        let rmode = roundMode(info.rounding)
        let rows: [String] = rule.sorted { ($0.minQty ?? 0) < ($1.minQty ?? 0) }.map { t in
            let q = Wholesale.qtyText(t.minQty ?? 0)
            let p = Wholesale.qtyText(t.percent ?? 0)
            var s = "от \(q) \(unit) — скидка \(p) %"
            if let r = retail, r > 0 {
                if let price = tierPrice(retail: r, percent: t.percent ?? 0, stepCents: cents, mode: rmode) {
                    s += " (\(Money.rub(price)))"
                } else {
                    s += " (не действует)"
                }
            }
            return s
        }
        let list = rows.joined(separator: "; ")
        if ownTiers { return "Опт категории «\(name)» (\(list)) не действует: у товара свои оптовые цены." }
        return "Действует опт категории «\(name)»: \(list). Чтобы задать свои цены, добавьте ступени выше."
    }
}
