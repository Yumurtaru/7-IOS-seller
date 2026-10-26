import SwiftUI
import Charts

// ============================================================================
//  Аналитика — GET /api/seller/analytics?period=7days|30days|quarter|year:
//  метрики (с изменением к прошлому периоду), выручка по дням, тепловая карта
//  день×час (WEEKDAY: 0=Пн…6=Вс), топ-10, донат способов получения, воронка
//  created→accepted→done, новые vs повторные. Отрисовка — Swift Charts +
//  нативная сетка теплокарты. Ссылки: топ-позиции, прогноз, отчёты.
// ============================================================================

@MainActor
final class AnalyticsViewModel: ObservableObject {
    @Published var data: AnalyticsData?
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var period = "30days" {
        didSet { if period != oldValue { Task { await load() } } }
    }

    // Паритет с Android: «Сегодня» — период today сервера (periodSince в
    // seller_analytics.php); общий список и для «Отчётов», и для «Топ-позиций».
    static let periods: [(String, String)] = [
        ("today", "Сегодня"), ("7days", "7 дней"), ("30days", "30 дней"), ("quarter", "Квартал"), ("year", "Год"),
    ]

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if data == nil { state = .loading }
        do {
            let fresh = try await API.shared.analytics(period: period)
            guard myGen == loadGen else { return }
            data = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

struct AnalyticsView: View {
    @StateObject private var vm = AnalyticsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Период", selection: $vm.period) {
                    ForEach(AnalyticsViewModel.periods, id: \.0) { value, title in
                        Text(title).tag(value)
                    }
                }
                .pickerStyle(.segmented)

                if let d = vm.data {
                    if let m = d.metrics { metricsCard(m) }
                    revenueChart(d)
                    heatmapCard(d)
                    funnelCard(d)
                    donutCard(d)
                    sourcesCard(d)
                    topCard(d)
                    linksCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Аналитика")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "chart.xyaxis.line", emptyTitle: "Нет данных",
                   retry: { Task { await vm.load() } })
        // Возврат с «Топ-позиций», «Прогноза» или «Отчёта» заново тянул всю
        // тяжёлую аналитику периода. Грузим, только если ещё не загружено
        // (или прошлая загрузка оборвалась); свежие цифры — жестом вниз.
        .task { if vm.state != .loaded { await vm.load() } }
    }

    // ── Метрики ──────────────────────────────────────────────────────────────
    private func metricsCard(_ m: AnalyticsMetrics) -> some View {
        SectionCard(title: "Показатели") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Выручка").font(.caption).foregroundColor(Brand.muted)
                    Text(Money.rub(m.revenue)).font(.title3.weight(.bold)).foregroundColor(Brand.text)
                }
                Spacer()
                if let change = m.revenueChange {
                    let up = change >= 0
                    // Запятая и «−», как у денег рядом: было «+12.5%» / «-3.0%» с точкой.
                    let v = NSDecimalNumber(decimal: change).doubleValue
                    let pct = (up ? "+" : "−") + Self.oneDecimal(abs(v)) + "%"
                    Label(pct, systemImage: up ? "arrow.up.right" : "arrow.down.right")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(up ? Brand.green : Brand.red)
                }
            }
            HStack(spacing: 10) {
                metric("Заказы", "\(m.orders ?? 0)")
                metric("Ср. чек", Money.rub(m.avgCheck))
                metric("Клиенты", "\(m.clients ?? 0)")
            }
            HStack(spacing: 10) {
                // П-23.14: 0 у рейтинга и времени доставки = «нет данных», а не «0,0 ★»/«0 мин».
                let rating = NSDecimalNumber(decimal: m.avgRating ?? 0).doubleValue
                let delivery = m.avgDeliveryMin ?? 0
                // «4,5 ★», а не «4.5 ★».
                metric("Рейтинг", rating > 0 ? Self.oneDecimal(rating) + " ★" : "нет данных")
                metric("Доставка", delivery > 0 ? "\(delivery) мин" : "нет данных")
            }
        }
    }

    /// Одна цифра после запятой по-русски: 4.5 → «4,5». String(format:) без
    /// локали ставил точку, а суммы рядом — с запятой.
    private static func oneDecimal(_ v: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "ru_RU"), v)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption2).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Brand.chip)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // ── Выручка по дням ──────────────────────────────────────────────────────
    @ViewBuilder
    private func revenueChart(_ d: AnalyticsData) -> some View {
        let points = d.byDay ?? []
        SectionCard(title: "Выручка по дням") {
            if points.isEmpty {
                Text("Нет заказов за период").font(.subheadline).foregroundColor(Brand.muted)
            } else {
                Chart(points) { p in
                    LineMark(
                        x: .value("День", p.d ?? ""),
                        y: .value("Выручка", NSDecimalNumber(decimal: p.r ?? 0).doubleValue)
                    )
                    .foregroundStyle(Brand.accent)
                    .interpolationMethod(.catmullRom)
                    AreaMark(
                        x: .value("День", p.d ?? ""),
                        y: .value("Выручка", NSDecimalNumber(decimal: p.r ?? 0).doubleValue)
                    )
                    .foregroundStyle(Brand.accent.opacity(0.15).gradient)
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxis(.hidden)
                .frame(height: 150)
            }
        }
    }

    // ── Теплокарта день×час ──────────────────────────────────────────────────
    @ViewBuilder
    private func heatmapCard(_ d: AnalyticsData) -> some View {
        let heat = d.heatmap ?? []
        SectionCard(title: "Часы пиковой нагрузки") {
            if heat.isEmpty {
                Text("Недостаточно данных").font(.subheadline).foregroundColor(Brand.muted)
            } else {
                HeatmapGrid(points: heat)
            }
        }
    }

    // ── Воронка ──────────────────────────────────────────────────────────────
    @ViewBuilder
    private func funnelCard(_ d: AnalyticsData) -> some View {
        if let funnel = d.funnel {
            SectionCard(title: "Воронка заказов") {
                let max = Swift.max(funnel.created ?? 0, 1)
                funnelBar("Создано", funnel.created ?? 0, of: max, color: Brand.accent)
                funnelBar("Принято в работу", funnel.accepted ?? 0, of: max, color: Brand.amber)
                funnelBar("Выполнено", funnel.done ?? 0, of: max, color: Brand.green)
            }
        }
    }

    private func funnelBar(_ title: String, _ value: Int, of max: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundColor(Brand.muted)
                Spacer()
                Text("\(value)").font(.caption.weight(.bold)).foregroundColor(Brand.text)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.chip)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * CGFloat(value) / CGFloat(max))
                }
            }
            .frame(height: 10)
        }
        .padding(.vertical, 2)
    }

    // ── Способы получения ────────────────────────────────────────────────────
    @ViewBuilder
    private func donutCard(_ d: AnalyticsData) -> some View {
        let slices = d.donut ?? []
        if !slices.isEmpty {
            SectionCard(title: "Способы получения") {
                Chart(slices) { slice in
                    BarMark(
                        x: .value("Заказы", slice.c ?? 0),
                        y: .value("Тип", deliveryLabel(slice.t))
                    )
                    .foregroundStyle(Brand.accent.gradient)
                    .cornerRadius(4)
                    .annotation(position: .trailing) {
                        Text("\(slice.c ?? 0)").font(.caption2).foregroundColor(Brand.muted)
                    }
                }
                .frame(height: CGFloat(slices.count) * 44 + 20)
            }
        }
    }

    private func deliveryLabel(_ t: String?) -> String {
        switch t {
        case "delivery": return "Доставка"
        case "pickup": return "Самовывоз"
        case "dine_in": return "В зале"
        default: return t ?? "—"
        }
    }

    // ── Новые vs повторные ───────────────────────────────────────────────────
    @ViewBuilder
    private func sourcesCard(_ d: AnalyticsData) -> some View {
        let src = d.sources ?? []
        if !src.isEmpty {
            SectionCard(title: "Новые и повторные клиенты") {
                Chart {
                    ForEach(src) { p in
                        BarMark(x: .value("День", p.d ?? ""),
                                y: .value("Заказы", p.newC ?? 0))
                            .foregroundStyle(by: .value("Тип", "Новые"))
                        BarMark(x: .value("День", p.d ?? ""),
                                y: .value("Заказы", p.repC ?? 0))
                            .foregroundStyle(by: .value("Тип", "Повторные"))
                    }
                }
                .chartForegroundStyleScale(["Новые": Brand.accent, "Повторные": Brand.green])
                .chartXAxis(.hidden)
                .frame(height: 150)
            }
        }
    }

    // ── Топ-10 ───────────────────────────────────────────────────────────────
    @ViewBuilder
    private func topCard(_ d: AnalyticsData) -> some View {
        let top = d.top ?? []
        if !top.isEmpty {
            SectionCard(title: "Топ-10 позиций") {
                // По порядку, а не по названию: у двух позиций с одинаковым
                // именем id совпадал, и SwiftUI рисовал одну строку дважды.
                ForEach(Array(top.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.name ?? "—")
                            .font(.subheadline).foregroundColor(Brand.text).lineLimit(1)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(Money.rub(item.rev))
                                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                            // Весовой товар: 2,5 кг показывались как «×2» (обрезка до целого).
                            Text("×\(QtyFmt.qty(item.qty))")
                                .font(.caption2).foregroundColor(Brand.muted)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // ── Ссылки на детальные отчёты ───────────────────────────────────────────
    private var linksCard: some View {
        SectionCard {
            NavigationLink { TopProductsView() } label: {
                Label("Топ-позиции с возвратами", systemImage: "list.number")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Brand.border)
            NavigationLink { ForecastView() } label: {
                Label("Прогноз спроса на неделю", systemImage: "chart.line.uptrend.xyaxis")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(Brand.border)
            NavigationLink { ReportsView() } label: {
                Label("Сводный отчёт", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundColor(Brand.text)
    }
}

// ── Теплокарта 7×24 ───────────────────────────────────────────────────────────
struct HeatmapGrid: View {
    let points: [HeatPoint]

    private static let days = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    private var matrix: [[Int]] {
        var m = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for p in points {
            guard let dow = p.dow, let h = p.h, (0..<7).contains(dow), (0..<24).contains(h) else { continue }
            m[dow][h] = p.c ?? 0
        }
        return m
    }

    var body: some View {
        let m = matrix
        let maxValue = max(m.flatMap { $0 }.max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 2) {
                    Text(Self.days[day])
                        .font(.system(size: 9))
                        .foregroundColor(Brand.muted)
                        .frame(width: 20, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cellColor(m[day][hour], max: maxValue))
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            HStack(spacing: 2) {
                Spacer().frame(width: 20)
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? "\(hour)" : "")
                        .font(.system(size: 7))
                        .foregroundColor(Brand.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func cellColor(_ value: Int, max: Int) -> Color {
        guard value > 0 else { return Brand.chip }
        let intensity = 0.2 + 0.8 * Double(value) / Double(max)
        return Brand.accent.opacity(intensity)
    }
}
