import SwiftUI

// ============================================================================
//  Волна А82 — общее для «Отчёта по продажам», «Контроля потерь» и двух блоков
//  дашборда: цвета и подписи как в кабинете (seller-sales-report.js), период,
//  разбор отказов (403/404 — прятать молча), доступность разделов в «Ещё»,
//  простые диаграммы на SwiftUI-фигурах (полоса долей, кольцо, шкала, столбцы).
// ============================================================================

/// А88: ссылка «Как это считается» на статью базы знаний сайта (path — «help/…»),
/// открывается в Safari. Общая для «Отчёта по продажам», «Контроля потерь» и расчётов с курьерами.
struct HelpLink: View {
    let path: String
    var title: String = "Как это считается"

    var body: some View {
        if let url = URL(string: API.base + "/" + path) {
            Link(destination: url) {
                Label(title, systemImage: "questionmark.circle").font(.footnote)
            }
            .foregroundColor(Brand.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum SR {
    // ── Цвета (COLORS и LEVEL_C кабинета) ──────────────────────────────────
    static func hex(_ v: UInt) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
    /// Наличные — зелёный, карта — синий, QR — фиолетовый, онлайн — оранжевый,
    /// прочее — серый, ждёт оплаты — светло-серый.
    static func methodColor(_ code: String?) -> Color {
        switch code {
        case "cash": return hex(0x16A34A)
        case "card": return hex(0x2563EB)
        case "sbp": return hex(0x7C3AED)
        case "online": return hex(0xF59E0B)
        case "pending": return hex(0xCBD5E1)
        default: return hex(0x94A3B8)
        }
    }
    static func levelColor(_ level: String?) -> Color {
        switch level {
        case "low": return hex(0x16A34A)
        case "medium": return hex(0xF59E0B)
        case "high": return hex(0xDC2626)
        default: return Brand.muted
        }
    }
    static let critical = hex(0xDC2626)
    static let warning = hex(0xF59E0B)
    /// Бейдж «Внимание» — темнее заливки столбцов: на светлом фоне текст читается.
    static let warningBadge = hex(0xD97706)
    static let hours = hex(0xFF5C00)

    /// Бейдж уровня операции (SEV кабинета).
    static func severity(_ s: String?) -> (String, Color) {
        switch s {
        case "critical": return ("Критично", critical)
        case "warning": return ("Внимание", warningBadge)
        default: return ("Инфо", Brand.muted)
        }
    }

    // ── Числа ───────────────────────────────────────────────────────────────
    /// Сумма до рубля (rub кабинета): «1 234 ₽».
    static func rub(_ v: Decimal?) -> String {
        var src = v ?? 0
        var out = Decimal()
        NSDecimalRound(&out, &src, 0, .plain)
        return Money.rub(out)
    }
    static func double(_ v: Decimal?) -> Double {
        NSDecimalNumber(decimal: v ?? 0).doubleValue
    }
    private static let pctFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ru_RU")
        f.groupingSeparator = "\u{202F}"
        f.decimalSeparator = ","
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 1
        return f
    }()
    static func number(_ v: Double) -> String {
        pctFormatter.string(from: NSNumber(value: v)) ?? String(v)
    }
    /// Стрелка изменения к прошлому периоду: «▲ 12,5%» / «▼ 3%»; null — пусто.
    static func pctText(_ v: Double?) -> Text? {
        guard let v, v.isFinite else { return nil }
        let up = v >= 0
        return Text((up ? "▲ " : "▼ ") + number(abs(v)) + "%")
            .fontWeight(.semibold)
            .foregroundColor(up ? Brand.green : Brand.red)
    }
    /// «2026-10-15» → «15.10» (подписи столбцов).
    static func dShort(_ s: String?) -> String {
        guard let s, s.count >= 10 else { return s ?? "" }
        let chars = Array(s)
        return String(chars[8...9]) + "." + String(chars[5...6])
    }

    // ── Период (у обеих ручек одинаковый) ──────────────────────────────────
    static let periods: [(String, String)] = [
        ("today", "Сегодня"), ("yesterday", "Вчера"), ("7days", "7 дней"), ("30days", "30 дней"),
        ("month", "Этот месяц"), ("prev_month", "Прошлый месяц"), ("custom", "Период…"),
    ]

    // ── Отказы ──────────────────────────────────────────────────────────────
    enum Outcome<T> {
        case ok(T)
        /// 403 (нет права) или 404 (старый сервер) — блок и пункт не показываем.
        case hidden(String)
        case failed(String)
        case cancelled
    }

    static func fetch<T>(_ op: () async throws -> T) async -> Outcome<T> {
        do {
            return .ok(try await op())
        } catch is CancellationError {
            return .cancelled
        } catch let e as APIDetailedError {
            // Прячем только настоящие 403 и 404 (getDetailed даёт статус и у ответа
            // без JSON). 429, 413, 400 — обычная ошибка, а не «раздела нет».
            if e.status == 403 || e.status == 404 { return .hidden(e.message) }
            return .failed(e.message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

// ── Доступность разделов (пункты «Ещё») ─────────────────────────────────────
/// Пункты «Отчёт по продажам» и «Контроль потерь» видны, только когда сервер
/// ответил на ручку: на старом сервере (404) и без права (403) их нет. Ответы
/// дашборда тоже отмечаются здесь, поэтому отдельная проверка нужна редко.
@MainActor
final class SalesReportFeature: ObservableObject {
    static let shared = SalesReportFeature()
    @Published private(set) var sales = false
    @Published private(set) var loss = false

    private var shop: Int?
    private var salesAt: Date?
    private var lossAt: Date?
    private var probingSales = false
    private var probingLoss = false

    private init() {}

    private func adopt(_ id: Int) {
        guard shop != id else { return }
        shop = id
        sales = false; loss = false
        salesAt = nil; lossAt = nil
    }

    private static func fresh(_ at: Date?) -> Bool {
        guard let at else { return false }
        return Date().timeIntervalSince(at) < 600
    }

    func note(sales ok: Bool, shop id: Int?) {
        guard let id, id == Session.shared.activeShopId else { return }
        adopt(id)
        sales = ok
        salesAt = Date()
    }

    func note(loss ok: Bool, shop id: Int?) {
        guard let id, id == Session.shared.activeShopId else { return }
        adopt(id)
        loss = ok
        lossAt = Date()
    }

    func refresh(shopId: Int?) async {
        guard let sid = shopId else { sales = false; loss = false; return }
        adopt(sid)
        let session = Session.shared
        if !session.can("analytics") {
            sales = false
        } else if !Self.fresh(salesAt) && !probingSales {
            probingSales = true
            // Проверка пункта меню — без повторов.
            let r = await SR.fetch { try await API.shared.salesReport(["period": "today"], retries: 0) }
            probingSales = false
            switch r {
            case .ok: note(sales: true, shop: sid)
            case .hidden: note(sales: false, shop: sid)
            default: break   // сеть мигнула — спросим в следующий раз
            }
        }
        if !session.can("security") {
            loss = false
        } else if !Self.fresh(lossAt) && !probingLoss {
            probingLoss = true
            let r = await SR.fetch { try await API.shared.lossControl(["brief": "1", "period": "today"], retries: 0) }
            probingLoss = false
            switch r {
            case .ok: note(loss: true, shop: sid)
            case .hidden: note(loss: false, shop: sid)
            default: break
            }
        }
    }
}

// ── Выбор периода ───────────────────────────────────────────────────────────
struct SRPeriodSel: Equatable {
    var code: String
    /// Свой период: даты пустые, пока их не выбрали (как на сайте и в Android —
    /// без подстановки «последних 7 дней»).
    var from: Date?
    var to: Date?

    /// period=… или from/to (включительно) — как у сайта. nil — свой период,
    /// а обе даты ещё не выбраны: запрос не шлём.
    var query: [String: String]? {
        guard code == "custom" else { return ["period": code] }
        guard let f = from, let t = to else { return nil }
        return ["from": DateFmt.ymd(f), "to": DateFmt.ymd(max(f, t))]
    }
}

struct SRPeriodBar: View {
    @Binding var sel: SRPeriodSel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SR.periods, id: \.0) { code, title in
                        FilterChip(title: title, selected: sel.code == code) { sel.code = code }
                    }
                }
            }
            if sel.code == "custom" {
                VStack(spacing: 6) {
                    dateRow("С", value: sel.from, range: Date.distantPast...Date()) { sel.from = $0 }
                    dateRow("По", value: sel.to, range: (sel.from ?? Date.distantPast)...Date.distantFuture) { sel.to = $0 }
                }
                .padding(12)
                .background(Brand.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}

extension SRPeriodBar {
    /// Строка даты: пока не выбрана — кнопка «Выбрать» (ставит сегодня, дальше
    /// дату меняют в календаре); выбрана — обычный DatePicker.
    @ViewBuilder
    fileprivate func dateRow(_ title: String, value: Date?, range: ClosedRange<Date>,
                             set: @escaping (Date) -> Void) -> some View {
        HStack {
            Text(title).foregroundColor(Brand.text)
            Spacer()
            if let v = value {
                DatePicker(title, selection: Binding(get: { v }, set: set), in: range, displayedComponents: .date)
                    .labelsHidden()
            } else {
                Button("Выбрать") { set(min(max(Date(), range.lowerBound), range.upperBound)) }
                    .foregroundColor(Brand.accent)
            }
        }
    }
}

// ── Плитка показателя (metric кабинета: подпись, значение, пояснение) ───────
struct SRMetricTile: View {
    let label: String
    let value: String
    var sub: Text? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(Brand.muted)
            Text(value)
                .font(.headline)
                .foregroundColor(Brand.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let sub {
                sub.font(.caption2).foregroundColor(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(12)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Квадратик цвета способа (легенда).
struct SRSwatch: View {
    let color: Color
    var size: CGFloat = 10
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3)
            .fill(color)
            .frame(width: size, height: size)
    }
}

// ── Полоса долей по способам ────────────────────────────────────────────────
struct SRShareBar: View {
    /// (сумма, цвет) — только положительные.
    let parts: [(Double, Color)]
    var height: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let total = max(parts.reduce(0) { $0 + max($1.0, 0) }, 0.0001)
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle()
                        .fill(p.1)
                        .frame(width: geo.size.width * CGFloat(max(p.0, 0) / total))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Brand.chip)
        .clipShape(Capsule())
        .accessibilityHidden(true)   // суммы — текстом рядом
    }
}

// ── Кольцевая диаграмма ─────────────────────────────────────────────────────
struct SRDonut: View {
    let parts: [(Double, Color)]
    var lineWidth: CGFloat = 26

    var body: some View {
        let total = parts.reduce(0) { $0 + max($1.0, 0) }
        ZStack {
            Circle().stroke(Brand.chip, lineWidth: lineWidth)
            if total > 0 {
                ForEach(Array(segments(total).enumerated()), id: \.offset) { _, s in
                    Circle()
                        .trim(from: s.0, to: s.1)
                        .stroke(s.2, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }

    private func segments(_ total: Double) -> [(CGFloat, CGFloat, Color)] {
        var out: [(CGFloat, CGFloat, Color)] = []
        var acc = 0.0
        for p in parts where p.0 > 0 {
            let a = acc / total
            acc += p.0
            out.append((CGFloat(a), CGFloat(acc / total), p.1))
        }
        return out
    }
}

// ── Полукруглая шкала индекса риска (gauge кабинета) ────────────────────────
private struct SRHalfArc: Shape {
    var fraction: Double
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let r = max(min(rect.width / 2, rect.height) - lineWidth / 2, 1)
        let c = CGPoint(x: rect.midX, y: rect.maxY - lineWidth / 2)
        let f = max(0, min(1, fraction))
        // От левого края через верх направо (в координатах SwiftUI — clockwise: false).
        p.addArc(center: c, radius: r, startAngle: .degrees(180), endAngle: .degrees(180 + 180 * f), clockwise: false)
        return p
    }
}

struct SRGauge: View {
    let index: Int?
    let level: String?
    var width: CGFloat = 200

    var body: some View {
        let v = max(0, min(100, index ?? 0))
        let lw = width * 0.08
        ZStack(alignment: .bottom) {
            SRHalfArc(fraction: 1, lineWidth: lw)
                .stroke(SR.hex(0xE5E7EB), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            if v > 0 {
                SRHalfArc(fraction: Double(v) / 100, lineWidth: lw)
                    .stroke(SR.levelColor(level), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            }
            Text("\(index ?? 0)")
                .font(.system(size: width * 0.17, weight: .heavy))
                .foregroundColor(SR.levelColor(level))
                .padding(.bottom, lw * 0.6)
        }
        .frame(width: width, height: width * 0.56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(index ?? 0)"))
    }
}

// ── Столбцы (по дням со стопкой способов, по часам, динамика) ──────────────
struct SRBarColumn {
    let label: String
    /// Сегменты снизу вверх.
    let parts: [(Double, Color)]
    /// Для VoiceOver: подпись и суммы.
    let accessibility: String
}

struct SRBars: View {
    let columns: [SRBarColumn]
    var height: CGFloat = 150
    /// Сколько подписей оси показывать (остальные пустые — не налезают).
    var maxLabels: Int = 7

    var body: some View {
        let maxValue = max(columns.map { $0.parts.reduce(0) { $0 + max($1.0, 0) } }.max() ?? 0, 0.0001)
        let step = max(1, Int((Double(columns.count) / Double(max(maxLabels, 1))).rounded(.up)))
        // Год по дням — 366 столбцов: зазоры съели бы всю ширину.
        let gap: CGFloat = columns.count > 60 ? 0 : (columns.count > 31 ? 1 : 3)
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                    let total = col.parts.reduce(0) { $0 + max($1.0, 0) }
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ForEach(Array(col.parts.reversed().enumerated()), id: \.offset) { _, p in
                            if p.0 > 0 {
                                Rectangle()
                                    .fill(p.1)
                                    .frame(height: height * CGFloat(p.0 / maxValue))
                            }
                        }
                        if total <= 0 {
                            Rectangle().fill(Brand.chip).frame(height: 1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(col.accessibility))
                }
            }
            HStack(spacing: gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { i, col in
                    Text(i % step == 0 ? col.label : "")
                        .font(.system(size: 8))
                        .foregroundColor(Brand.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
    }
}

/// Легенда: квадратик + подпись.
struct SRLegend: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(spacing: 4) {
                    SRSwatch(color: it.1, size: 8)
                    Text(it.0).font(.caption2).foregroundColor(Brand.muted)
                }
            }
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
//  Дашборд: «Оплаты» (period=today) и «Контроль потерь» (brief=1, 7 дней)
// ════════════════════════════════════════════════════════════════════════════

@MainActor
final class SalesDashboardModel: ObservableObject {
    @Published private(set) var sales: SalesReport?
    @Published private(set) var loss: LossControl?
    /// Номер запроса: ответ прежней загрузки, пришедший позже новой, не рисуем.
    private var gen = 0
    /// Когда начали последнюю загрузку и для какой организации. Контроль потерь
    /// тяжёлый (разбор журнала): при каждом показе вкладки и возврате из фона не
    /// шлём — не чаще раза в 5 минут; «потянуть вниз» (force) — всегда.
    private var lastAt = Date.distantPast
    private var lastShop: Int?
    private var inFlight = false

    func load(force: Bool = false) async {
        let session = Session.shared
        let shop = session.activeShopId
        if !force {
            guard !inFlight, shop != lastShop || Date().timeIntervalSince(lastAt) >= 300 else { return }
        }
        gen += 1
        let my = gen
        lastAt = Date()
        lastShop = shop
        inFlight = true
        defer { if my == gen { inFlight = false } }
        let canSales = session.can("analytics")
        let canLoss = session.can("security")
        // Без права блок не запрашиваем вовсе (403 ещё и перечитывает /me).
        if !canSales { sales = nil }
        if !canLoss { loss = nil }
        async let s = Self.fetchSales(canSales)
        async let l = Self.fetchLoss(canLoss)
        let (sr, lr) = await (s, l)
        guard my == gen, shop == session.activeShopId else { return }
        // Ушли с экрана посреди запроса или сбой — следующий показ спросит снова.
        if Self.unfinished(sr) || Self.unfinished(lr) { lastAt = .distantPast }
        let feature = SalesReportFeature.shared
        switch sr {
        case .ok(let d)?: sales = d; feature.note(sales: true, shop: shop)
        case .hidden?: sales = nil; feature.note(sales: false, shop: shop)
        default: break   // сбой сети — оставляем прежние цифры
        }
        switch lr {
        case .ok(let d)?: loss = d; feature.note(loss: true, shop: shop)
        case .hidden?: loss = nil; feature.note(loss: false, shop: shop)
        default: break
        }
    }

    private static func unfinished<T>(_ r: SR.Outcome<T>?) -> Bool {
        switch r {
        case .failed?, .cancelled?: return true
        default: return false
        }
    }

    // Без повторов (retries: 0): тяжёлую ручку при 5xx не дёргаем трижды.
    nonisolated private static func fetchSales(_ can: Bool) async -> SR.Outcome<SalesReport>? {
        guard can else { return nil }
        return await SR.fetch { try await API.shared.salesReport(["period": "today"], retries: 0) }
    }

    nonisolated private static func fetchLoss(_ can: Bool) async -> SR.Outcome<LossControl>? {
        guard can else { return nil }
        return await SR.fetch { try await API.shared.lossControl(["brief": "1", "period": "7days"], retries: 0) }
    }
}

struct SalesDashboardBlocks: View {
    @ObservedObject var model: SalesDashboardModel

    var body: some View {
        if let s = model.sales {
            NavigationLink { SalesReportView() } label: { paymentsCard(s) }
                .buttonStyle(.plain)
        }
        // Журнал не включён — блок не показываем (как на сайте).
        if let l = model.loss, l.enabled != false {
            NavigationLink { LossControlView() } label: { lossCard(l) }
                .buttonStyle(.plain)
        }
    }

    // ── Оплаты ─────────────────────────────────────────────────────────────
    private func paymentsCard(_ d: SalesReport) -> some View {
        let paid = d.methods.filter { ($0.amount ?? 0) > 0 }
        let shown = d.methods.filter { ($0.amount ?? 0) > 0 || ["cash", "card", "sbp"].contains($0.code ?? "") }
        let title = d.period?.label.map { "Оплаты · " + $0 } ?? "Оплаты"
        return SectionCard(title: title) {
            SRShareBar(parts: paid.map { (SR.double($0.amount), SR.methodColor($0.code)) })
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            SRSwatch(color: SR.methodColor(m.code), size: 8)
                            Text(m.label ?? m.code ?? "—").font(.caption).foregroundColor(Brand.muted)
                        }
                        Text(SR.rub(m.amount))
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(Brand.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            (Text("Наличными по чекам (за вычетом возвратов): ")
                + Text(SR.rub(d.summary?.cashNet)).fontWeight(.bold)
                + Text(" · возвраты " + SR.rub(d.summary?.returns))
                + Text(" · полный отчёт →").foregroundColor(Brand.accent))
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
    }

    // ── Контроль потерь ────────────────────────────────────────────────────
    private func lossCard(_ d: LossControl) -> some View {
        let title = d.period?.label.map { "Контроль потерь · " + $0 } ?? "Контроль потерь"
        return SectionCard(title: title) {
            HStack(spacing: 12) {
                SRGauge(index: d.index, level: d.level, width: 120)
                VStack(alignment: .leading, spacing: 4) {
                    Text(d.levelLabel ?? "")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(SR.levelColor(d.level))
                    (Text("Критичных: ") + Text("\(d.counts?.critical ?? 0)").fontWeight(.bold)
                        + Text(" · внимание: ") + Text("\(d.counts?.warning ?? 0)").fontWeight(.bold))
                        .font(.subheadline)
                        .foregroundColor(Brand.text)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(d.top.prefix(3).enumerated()), id: \.offset) { _, i in
                let sev = SR.severity(i.severity)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    StatusBadge(text: i.title ?? sev.0, color: sev.1)
                    // Нулевую сумму не пишем (паритет с Android).
                    Text(joinedNonEmpty([i.actor, i.amount.flatMap { $0 != 0 ? SR.rub($0) : nil }], separator: " · "))
                        .font(.subheadline)
                        .foregroundColor(Brand.text)
                        .lineLimit(2)
                }
            }
            Text("Все операции →")
                .font(.caption)
                .foregroundColor(Brand.accent)
        }
    }
}
