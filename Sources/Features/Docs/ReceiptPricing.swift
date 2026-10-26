import Foundation

// ============================================================================
//  Волна А99: расчёты приёмки и переоценки — те же правила, что у сервера
//  (retailFromPurchase в core/helpers.php, rcvRound в routes/seller_receipt.php)
//  и у веб-кабинета (seller-receipt.js). Здесь только чистая математика без
//  SwiftUI и сети — так же устроен ReceiptMath в приложении для Android.
//
//  Деньги — Decimal. PHP round() считает «половину» от точного десятичного
//  значения (50 × 1,13 = 56,5 → 57); NSDecimalRound(.plain) по точному Decimal
//  даёт тот же ответ, и ценник не расходится с кассой.
// ============================================================================

enum ReceiptMath {
    /// Округление переоценки и наценки в приходе — как ROUNDING кабинета.
    static let rounding: [(String, String)] = [
        ("none", "Без округления"), ("integer", "До рубля"), ("0.10", "До 10 коп."),
        ("0.50", "До 50 коп."), ("end9", "Окончание на 9"),
    ]
    /// Округление у наценки категории — сервер принимает только эти три.
    static let categoryRounding: [(String, String)] = [
        ("integer", "До рубля"), ("0.10", "До 10 коп."), ("0.50", "До 50 коп."),
    ]
    /// Правила переоценки — как RV_MODES кабинета.
    static let revalModes: [(String, String)] = [
        ("percent", "Изменить на %"), ("delta", "Изменить на сумму, ₽"), ("set", "Установить цену, ₽"),
        ("markup_cost", "Наценка на закупку, %"), ("category", "По наценке категории"),
    ]

    /// Округление до scale знаков, половина — от нуля (как PHP round).
    static func round(_ v: Decimal, _ scale: Int) -> Decimal {
        var src = v
        var out = Decimal()
        NSDecimalRound(&out, &src, scale, .plain)
        return out
    }

    /// Розничная из закупочной по наценке категории (retailFromPurchase сервера).
    static func retailFromPurchase(_ purchase: Decimal, markup: Decimal?, mode: String?) -> Decimal {
        guard purchase > 0 else { return 0 }
        let x = purchase * (1 + (markup ?? 0) / 100)
        switch mode {
        case "0.10": return round(x * 10, 0) / 10
        case "0.50": return round(x * 2, 0) / 2
        default: return round(x, 0)
        }
    }

    /// Округление цены: none | integer | 0.10 | 0.50 | end9 (rcvRound сервера).
    static func roundBy(_ p: Decimal, _ mode: String?) -> Decimal {
        guard p > 0 else { return 0 }
        switch mode {
        case "integer": return round(p, 0)
        case "0.10": return round(p * 10, 0) / 10
        case "0.50": return round(p * 2, 0) / 2
        case "end9":
            // Ближайшая цена на …9: 72,60 → 69, 75 → 79, 10 → 9 (как rcvRound).
            let n = NSDecimalNumber(decimal: round(p, 0)).intValue
            let down = n - ((n % 10) + 1) % 10
            let up = down + 10
            let best = (down > 0 && (p - Decimal(down)) < (Decimal(up) - p)) ? down : up
            return Decimal(best)
        default: return round(p, 2)
        }
    }

    /// Цена по наценке, % от базы, с округлением. nil — нет базы.
    static func byMarkup(_ base: Decimal, _ markup: Decimal, _ mode: String?) -> Decimal? {
        guard base > 0 else { return nil }
        return roundBy(base * (1 + markup / 100), mode)
    }

    /// Наценка цены к базе в процентах, nil — базы нет.
    static func markupPercent(_ price: Decimal, _ base: Decimal) -> Decimal? {
        guard base > 0, price > 0 else { return nil }
        return (price / base - 1) * 100
    }

    /// Изменение к прошлому в процентах: (новое / старое − 1) × 100.
    static func changePercent(_ now: Decimal, _ before: Decimal) -> Decimal? {
        guard before > 0 else { return nil }
        return (now / before - 1) * 100
    }

    /// Одна цифра после запятой, без лишних нулей: «12,5», «30», «-4».
    static func oneDecimal(_ v: Decimal) -> String {
        NSDecimalNumber(decimal: round(v, 1)).stringValue.replacingOccurrences(of: ".", with: ",")
    }

    /// «+12,5%» / «-4%» — как pct() кабинета.
    static func pct(_ v: Decimal) -> String { (v > 0 ? "+" : "") + oneDecimal(v) + "%" }

    /// Значение для поля ввода денег: «120», «99,9».
    static func moneyInput(_ v: Decimal) -> String {
        NSDecimalNumber(decimal: round(v, 2)).stringValue.replacingOccurrences(of: ".", with: ",")
    }

    /// Разница меньше копейки — цена та же.
    static func samePrice(_ a: Decimal, _ b: Decimal) -> Bool {
        let d = a - b
        return (d < 0 ? -d : d) < Decimal(string: "0.005")!
    }

    /// Откуда розничная цена строки прихода.
    enum Src { case na, locked, manual, fixed, auto, pending, none }

    struct Retail {
        let price: Decimal?
        let src: Src
        let old: Decimal?
    }

    /// Новая розничная цена строки прихода — retailOf() кабинета.
    static func retailOf(isProduct: Bool, retailOn: Bool, mayPrice: Bool, hasInfo: Bool,
                         old: Decimal?, retailManual: Bool, markup: Decimal?, roundingMode: String?,
                         manual: Decimal?, purchase: Decimal) -> Retail {
        if !isProduct || !retailOn { return Retail(price: nil, src: .na, old: nil) }
        if !mayPrice { return Retail(price: old, src: .locked, old: old) }
        if let m = manual, m > 0 { return Retail(price: m, src: .manual, old: old) }
        if hasInfo && retailManual { return Retail(price: old, src: .fixed, old: old) }
        if hasInfo, let mk = markup, purchase > 0 {
            return Retail(price: retailFromPurchase(purchase, markup: mk, mode: roundingMode), src: .auto, old: old)
        }
        if hasInfo && markup != nil { return Retail(price: old, src: .pending, old: old) }
        return Retail(price: old, src: .none, old: old)
    }

    /// Розница совпала с той, что сервер сам поставит по наценке категории —
    /// тогда её не передаём (иначе товар стал бы «с ручной ценой»).
    static func sameAsAuto(retailManual: Bool, markup: Decimal?, roundingMode: String?,
                           purchase: Decimal, price: Decimal) -> Bool {
        guard !retailManual, let mk = markup, purchase > 0 else { return false }
        return samePrice(retailFromPurchase(round(purchase, 2), markup: mk, mode: roundingMode), price)
    }

    /// Подпись источника розничной цены — тексты кабинета.
    static func srcText(_ src: Src, markup: Decimal?) -> String {
        let mk = markup.map { oneDecimal($0) + "%" } ?? ""
        switch src {
        case .manual: return "вручную"
        case .auto: return "по категории " + mk
        case .fixed: return "ручная цена товара"
        case .pending: return "наценка категории " + mk + " — введите закупку"
        case .none: return "наценка категории не задана"
        case .locked: return "нет права «Менять цены»"
        case .na: return ""
        }
    }

    /// Резкое изменение закупки (от 20 %) — подсказка «проверьте накладную».
    static func isJump(_ purchase: Decimal, last: Decimal?) -> Bool {
        guard let last, last > 0, purchase > 0, let ch = changePercent(purchase, last) else { return false }
        return (ch < 0 ? -ch : ch) >= 20
    }

    /// «2026-10-20» или «2026-10-20 14:05:00» → «20.10.2026». Иное — как есть.
    static func ruDate(_ raw: String?) -> String {
        let t = (raw ?? "").trimmingCharacters(in: .whitespaces)
        let c = Array(t)
        guard c.count >= 10, c[4] == "-", c[7] == "-" else { return t }
        return String(c[8...9]) + "." + String(c[5...6]) + "." + String(c[0...3])
    }

    /// «Накладная № 1245 от 20.10.2026»; ни номера, ни даты — nil.
    static func supplierDocText(no: String?, date: String?) -> String? {
        let n = (no ?? "").trimmingCharacters(in: .whitespaces)
        let rawDate = (date ?? "").trimmingCharacters(in: .whitespaces)
        let d = (rawDate.isEmpty || rawDate.hasPrefix("0000")) ? "" : ruDate(rawDate)
        if n.isEmpty && d.isEmpty { return nil }
        return "Накладная" + (n.isEmpty ? "" : " № \(n)") + (d.isEmpty ? "" : " от \(d)")
    }

    /// Разбор числа из поля: пробелы убираем, запятая — точка; со знаком по желанию.
    static func parse(_ s: String, maxFraction: Int = 2, allowNegative: Bool = false) -> Decimal? {
        var t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        var negative = false
        if allowNegative, t.hasPrefix("-") { negative = true; t.removeFirst() }
        guard let v = Money.strict(t, maxFraction: maxFraction) else { return nil }
        return negative ? -v : v
    }
}
