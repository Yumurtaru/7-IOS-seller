import SwiftUI

// ============================================================================
//  АY (сайт А616): новые отчёты аналитики — простые списки.
//   • ABC/XYZ-анализ — GET /api/seller/analytics/abc?period=30days|quarter|year
//   • «Возвращаются ли покупатели» — GET /api/seller/analytics/cohorts
//   • «Покупают вместе» — GET /api/seller/analytics/basket (пары от 10 заказов за 90 дней)
//  Право — как у раздела «Аналитика». Старый сервер ручек не знает (404/405) —
//  экран пишет «Доступно после обновления сайта», а не ошибку.
// ============================================================================

// ── Модели ───────────────────────────────────────────────────────────────────
struct AbcReport: Decodable {
    var period: String?
    @LenientInt var weeks: Int?
    @LenientDecimal var total: Decimal?
    @SRList var items: [AbcItem]
    enum CodingKeys: String, CodingKey { case period, weeks, total, items }
}

struct AbcItem: Decodable {
    @LenientInt var productId: Int?
    var name: String?
    @LenientDecimal var rev: Decimal?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var sharePct: Decimal?
    var abc: String?
    var xyz: String?
    enum CodingKeys: String, CodingKey {
        case name, rev, qty, abc, xyz
        case productId = "product_id"
        case sharePct = "share_pct"
    }
}

struct CohortsReport: Decodable {
    @SRList var cohorts: [CohortRow]
    @LenientInt var clients: Int?
    @LenientDecimal var repeatPct: Decimal?
    @LenientDecimal var avgGapDays: Decimal?
    enum CodingKeys: String, CodingKey {
        case cohorts, clients
        case repeatPct = "repeat_pct"
        case avgGapDays = "avg_gap_days"
    }
}

struct CohortRow: Decodable {
    var month: String?
    @LenientInt var size: Int?
    /// {"1": n, …} — сколько из пришедших в этом месяце купили через k месяцев.
    @SRIntMap var retained: [String: Int]?
    enum CodingKeys: String, CodingKey { case month, size, retained }

    /// Месяцы по порядку: 1, 2, 3…
    var retainedSorted: [(Int, Int)] {
        (retained ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } }.sorted { $0.0 < $1.0 }
    }
}

struct BasketReport: Decodable {
    @LenientInt var orders: Int?
    @SRList var pairs: [BasketPair]
    enum CodingKeys: String, CodingKey { case orders, pairs }
}

struct BasketPair: Decodable {
    var a: String?
    var b: String?
    @LenientInt var orders: Int?
    @LenientDecimal var supportPct: Decimal?
    @LenientDecimal var lift: Decimal?
    enum CodingKeys: String, CodingKey {
        case a, b, orders, lift
        case supportPct = "support_pct"
    }
}

extension API {
    func analyticsAbc(period: String) async throws -> AbcReport {
        try await getDetailed("api/seller/analytics/abc", query: ["period": period], as: AbcReport.self)
    }
    func analyticsCohorts() async throws -> CohortsReport {
        try await getDetailed("api/seller/analytics/cohorts", as: CohortsReport.self)
    }
    func analyticsBasket() async throws -> BasketReport {
        try await getDetailed("api/seller/analytics/basket", as: BasketReport.self)
    }
}

/// Общая загрузка отчёта: 404/405 старого сервера — «нет ручки», а не ошибка.
@MainActor
final class AnalyticsExtraModel<T>: ObservableObject {
    @Published var data: T?
    @Published var state: LoadState = .idle
    @Published var unavailable = false
    private var gen = 0

    func load(_ op: @escaping () async throws -> T) async {
        gen += 1
        let myGen = gen
        if data == nil { state = .loading }
        do {
            let fresh = try await op()
            guard myGen == gen else { return }
            data = fresh
            unavailable = false
            state = .loaded
        } catch is CancellationError {
        } catch let e as APIDetailedError where e.status == 404 || e.status == 405 {
            guard myGen == gen else { return }
            data = nil
            unavailable = true
            state = .loaded
        } catch {
            guard myGen == gen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

enum AnalyticsExtraText {
    static let unavailable = "Доступно после обновления сайта"
}

// ── ABC/XYZ ──────────────────────────────────────────────────────────────────
struct AbcAnalysisView: View {
    @StateObject private var vm = AnalyticsExtraModel<AbcReport>()
    @State private var period = "quarter"

    private static let periods: [(String, String)] = [("30days", "30 дней"), ("quarter", "Квартал"), ("year", "Год")]

    var body: some View {
        List {
            Section {
                Picker("Период", selection: $period) {
                    ForEach(Self.periods, id: \.0) { value, title in Text(title).tag(value) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                if !vm.unavailable {
                    Text("A — 80% выручки, B — следующие 15%, C — остальное. X — продажи ровные, Y — колеблются, Z — непредсказуемы.")
                        .font(.caption).foregroundColor(Brand.muted)
                        .listRowBackground(Color.clear)
                }
            }
            if let items = vm.data?.items, !items.isEmpty {
                Section {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        HStack(spacing: 10) {
                            StatusBadge(text: (it.abc ?? "—") + (it.xyz ?? ""), color: Self.color(it.abc))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.name ?? "—").font(.subheadline).foregroundColor(Brand.text).lineLimit(2)
                                Text("доля " + QtyFmt.percent(it.sharePct) + " · продано " + QtyFmt.qty(it.qty))
                                    .font(.caption2).foregroundColor(Brand.muted)
                            }
                            Spacer()
                            Text(Money.rub(it.rev)).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                        }
                        .listRowBackground(Brand.card)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("ABC/XYZ-анализ")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .listState(vm.state, isEmpty: vm.data?.items.isEmpty ?? true,
                   emptyIcon: "square.grid.3x3",
                   emptyTitle: vm.unavailable ? AnalyticsExtraText.unavailable : "Нет продаж за период",
                   retry: { Task { await reload() } })
        .onChange(of: period) { _ in Task { await reload() } }
        .task { if vm.state != .loaded { await reload() } }
    }

    private func reload() async {
        let p = period
        await vm.load { try await API.shared.analyticsAbc(period: p) }
    }

    private static func color(_ abc: String?) -> Color {
        switch abc {
        case "A": return Brand.green
        case "B": return Brand.amber
        default: return Brand.muted
        }
    }
}

// ── Когорты ──────────────────────────────────────────────────────────────────
struct CohortsView: View {
    @StateObject private var vm = AnalyticsExtraModel<CohortsReport>()

    var body: some View {
        List {
            if let d = vm.data {
                Section {
                    InfoRow(label: "Покупателей", value: "\(d.clients ?? 0)")
                    InfoRow(label: "Покупают повторно", value: QtyFmt.percent(d.repeatPct))
                    if let gap = d.avgGapDays {
                        InfoRow(label: "В среднем между заказами", value: QtyFmt.qty(gap) + " дн.")
                    }
                }
                .listRowBackground(Brand.card)
                if !d.cohorts.isEmpty {
                    Section("По месяцу первого заказа") {
                        ForEach(Array(d.cohorts.enumerated()), id: \.offset) { _, c in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(Self.monthTitle(c.month)).font(.subheadline.weight(.semibold))
                                        .foregroundColor(Brand.text)
                                    Spacer()
                                    Text("новых: \(c.size ?? 0)").font(.caption).foregroundColor(Brand.muted)
                                }
                                let ret = c.retainedSorted
                                if !ret.isEmpty {
                                    Text(ret.map { "\($0.0) мес: \($0.1)" }.joined(separator: " · "))
                                        .font(.caption2).foregroundColor(Brand.muted)
                                }
                            }
                            .listRowBackground(Brand.card)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Возвращаются ли покупатели")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load { try await API.shared.analyticsCohorts() } }
        .listState(vm.state, isEmpty: vm.data == nil || (vm.data?.clients ?? 0) == 0,
                   emptyIcon: "arrow.triangle.2.circlepath",
                   emptyTitle: vm.unavailable ? AnalyticsExtraText.unavailable : "Пока нет покупателей с аккаунтом",
                   retry: { Task { await vm.load { try await API.shared.analyticsCohorts() } } })
        .task { if vm.state != .loaded { await vm.load { try await API.shared.analyticsCohorts() } } }
    }

    private static let monthIn: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let monthOut: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "LLLL yyyy"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    /// «2026-05» → «май 2026».
    static func monthTitle(_ s: String?) -> String {
        guard let s, let d = monthIn.date(from: s) else { return s ?? "—" }
        return monthOut.string(from: d)
    }
}

// ── Покупают вместе ──────────────────────────────────────────────────────────
struct BasketView: View {
    @StateObject private var vm = AnalyticsExtraModel<BasketReport>()

    var body: some View {
        List {
            Section {
                Text("Пары позиций, которые чаще всего берут в одном заказе, — за 90 дней.")
                    .font(.caption).foregroundColor(Brand.muted)
                    .listRowBackground(Color.clear)
            }
            if let pairs = vm.data?.pairs, !pairs.isEmpty {
                Section {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 3) {
                            Text((p.a ?? "—") + " + " + (p.b ?? "—"))
                                .font(.subheadline).foregroundColor(Brand.text)
                            Text("вместе в заказах: \(p.orders ?? 0)")
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        .listRowBackground(Brand.card)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Покупают вместе")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load { try await API.shared.analyticsBasket() } }
        .listState(vm.state, isEmpty: vm.data?.pairs.isEmpty ?? true,
                   emptyIcon: "cart",
                   emptyTitle: vm.unavailable ? AnalyticsExtraText.unavailable : emptyTitle,
                   retry: { Task { await vm.load { try await API.shared.analyticsBasket() } } })
        .task { if vm.state != .loaded { await vm.load { try await API.shared.analyticsBasket() } } }
    }

    private var emptyTitle: String {
        if let n = vm.data?.orders, n < 10 { return "Мало заказов для анализа — нужно от 10 за 90 дней" }
        return "Частых пар пока нет"
    }
}
