import SwiftUI

// ============================================================================
//  Мелкие элементы раздела «Жильё», общие для всех его экранов.
// ============================================================================

/// Статусная плашка (номер на витрине, готовность, статус брони).
struct LodgingPill: View {
    let text: String
    var color: Color = Brand.muted

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

/// Кнопка действия в карточке — как в «Записях» (BookingsView).
struct LodgingActionButton: View {
    let title: String
    var color: Color = Brand.accent
    var textColor: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(color)
                .foregroundColor(textColor)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

enum LodgingFormat {
    /// Григорианский календарь для дат сервера. С Calendar.current на телефоне,
    /// где выбран буддийский или японский календарь, год выходил «2569» —
    /// клетки календаря не находили своих цен, а массовая правка уходила
    /// с несуществующими датами.
    /// Один на всё приложение: раньше новый Calendar создавался на каждый вызов —
    /// сетка месяца звала его ~200 раз за перерисовку. autoupdatingCurrent —
    /// смена пояса телефона подхватывается, как и раньше с .current.
    static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .autoupdatingCurrent
        return c
    }()

    /// «2026-09-28» → «28.09».
    static func dayMonth(_ iso: String?) -> String {
        guard let s = iso, s.count >= 10 else { return iso ?? "—" }
        let p = s.prefix(10).split(separator: "-")
        guard p.count == 3 else { return s }
        return "\(p[2]).\(p[1])"
    }

    /// «2026-09-28» → «28.09.2026».
    static func fullDate(_ iso: String?) -> String {
        guard let s = iso, s.count >= 10 else { return iso ?? "—" }
        let p = s.prefix(10).split(separator: "-")
        guard p.count == 3 else { return s }
        return "\(p[2]).\(p[1]).\(p[0])"
    }

    static func nights(_ n: Int?) -> String {
        let v = n ?? 0
        let mod100 = v % 100, mod10 = v % 10
        if mod100 >= 11 && mod100 <= 14 { return "\(v) ночей" }
        if mod10 == 1 { return "\(v) ночь" }
        if mod10 >= 2 && mod10 <= 4 { return "\(v) ночи" }
        return "\(v) ночей"
    }

    static func guests(_ adults: Int?, _ children: Int?) -> String {
        var parts = ["\(adults ?? 1) взр."]
        if (children ?? 0) > 0 { parts.append("\(children ?? 0) реб.") }
        return parts.joined(separator: ", ")
    }

    /// Цвет статуса брони — как на сайте.
    static func statusColor(_ status: String?) -> Color {
        switch status ?? "" {
        case "hold", "pending": return Brand.amber
        case "confirmed": return Brand.accent
        case "checked_in": return Brand.green
        case "checked_out": return Brand.muted
        case "cancelled", "no_show": return Brand.red
        default: return Brand.muted
        }
    }

    static func statusTitle(_ b: LodgingBooking) -> String {
        if let l = b.statusLabel, !l.isEmpty { return l }
        switch b.status ?? "" {
        // Подписи повторяют Lodging::statusLabel: сервер их присылает всегда,
        // это лишь запас на случай пустого status_label.
        case "hold": return "Держим"
        case "pending": return "Ждёт подтверждения"
        case "confirmed": return "Подтверждена"
        case "checked_in": return "Гость заехал"
        case "checked_out": return "Гость выехал"
        case "cancelled": return "Отменена"
        case "no_show": return "Незаезд"
        default: return b.status ?? "—"
        }
    }

    /// «2026-09-01» для сервера.
    static func iso(_ date: Date) -> String {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    static func monthTitle(_ date: Date) -> String {
        let names = ["январь", "февраль", "март", "апрель", "май", "июнь",
                     "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
        let c = gregorian.dateComponents([.year, .month], from: date)
        let m = max(1, min(12, c.month ?? 1))
        return "\(names[m - 1]) \(c.year ?? 2026)"
    }

    static func rooms(_ n: Int?) -> String {
        let v = n ?? 1
        let mod100 = v % 100, mod10 = v % 10
        if mod100 >= 11 && mod100 <= 14 { return "\(v) номеров" }
        if mod10 == 1 { return "\(v) номер" }
        if mod10 >= 2 && mod10 <= 4 { return "\(v) номера" }
        return "\(v) номеров"
    }

    /// Процент без лишнего «.0»: 12.5 → «12,5», 30 → «30».
    static func pct(_ v: Double?) -> String {
        let d = v ?? 0
        if d == d.rounded() { return String(Int(d)) }
        var t = String(format: "%.2f", d)
        while t.hasSuffix("0") { t.removeLast() }
        return t.replacingOccurrences(of: ".", with: ",")
    }

    /// «14:00» → Date для DatePicker. Свободный ввод времени сервер молча
    /// заменял значением по умолчанию (Lodging::time требует ровно «ЧЧ:ММ»),
    /// поэтому время выбирается колесом, а не печатается.
    static func timeDate(_ s: String?, fallbackHour: Int) -> Date {
        let parts = (s ?? "").split(separator: ":")
        let h = parts.count >= 1 ? Int(parts[0]) ?? fallbackHour : fallbackHour
        let m = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        return Calendar.current.date(bySettingHour: min(23, max(0, h)), minute: min(59, max(0, m)), second: 0, of: Date()) ?? Date()
    }

    /// Date → «ЧЧ:ММ» для сервера.
    static func timeString(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Коротко для клетки календаря: 3500 → «3.5к».
    static func shortPrice(_ v: Decimal?) -> String {
        guard let v = v else { return "—" }
        let d = NSDecimalNumber(decimal: v).doubleValue
        if d <= 0 { return "—" }
        if d < 1000 { return String(Int(d)) }
        let k = d / 1000
        // Запятая — десятичный разделитель в русском интерфейсе.
        return k == k.rounded() ? "\(Int(k))к" : String(format: "%.1fк", k).replacingOccurrences(of: ".", with: ",")
    }
}
