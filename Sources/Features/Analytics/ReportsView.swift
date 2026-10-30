import SwiftUI

// ============================================================================
//  Сводный отчёт — GET /api/seller/reports?period=: итоги периода, выручка
//  по категориям, списанные комиссии/сервисные сборы (order_commissions).
// ============================================================================

@MainActor
final class ReportsViewModel: ObservableObject {
    @Published var data: ReportsData?
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var period = "30days" {
        didSet { if period != oldValue { Task { await load() } } }
    }

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if data == nil { state = .loading }
        do {
            let fresh = try await API.shared.reports(period: period)
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

struct ReportsView: View {
    @StateObject private var vm = ReportsViewModel()

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
                    totalsCard(d)
                    commissionCard(d)
                    categoriesCard(d)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Отчёты")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "doc.text", emptyTitle: "Нет данных",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }

    @ViewBuilder
    private func totalsCard(_ d: ReportsData) -> some View {
        if let t = d.totals {
            SectionCard(title: "Итоги периода") {
                InfoRow(label: "Заказов", value: "\(t.orders ?? 0)")
                InfoRow(label: "Выручка", value: Money.rub(t.revenue))
                InfoRow(label: "Средний чек", value: Money.rub(t.avgCheck))
            }
        }
    }

    @ViewBuilder
    private func commissionCard(_ d: ReportsData) -> some View {
        if let c = d.commission {
            SectionCard(title: "Комиссии маркетплейса") {
                // commission.hidden: нет права «Финансы» — сервер прислал нули, а не суммы.
                if c.hidden == true {
                    Text("Комиссии видит владелец или сотрудник с правом «Финансы»")
                        .font(.subheadline).foregroundColor(Brand.muted)
                } else {
                    InfoRow(label: "Комиссия", value: Money.rub(c.comm))
                    InfoRow(label: "Сервисный сбор", value: Money.rub(c.fee))
                    InfoRow(label: "Заказов со списанием", value: "\(c.cnt ?? 0)")
                }
            }
        }
    }

    @ViewBuilder
    private func categoriesCard(_ d: ReportsData) -> some View {
        let rows = d.byCategory ?? []
        SectionCard(title: "Выручка по категориям") {
            if rows.isEmpty {
                Text("Нет продаж за период").font(.subheadline).foregroundColor(Brand.muted)
            } else {
                let maxRev = rows.compactMap { $0.rev }.max() ?? 1
                // По порядку, а не по названию: у строки без категории id был
                // новым UUID на каждую перерисовку, а две одноимённые категории
                // давали одинаковый id — SwiftUI путал и дублировал строки.
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.category ?? "Без категории")
                                .font(.subheadline).foregroundColor(Brand.text).lineLimit(1)
                            Spacer()
                            Text(Money.rub(row.rev))
                                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Brand.chip)
                                Capsule().fill(Brand.accent)
                                    .frame(width: geo.size.width * barFraction(row.rev, max: maxRev))
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func barFraction(_ value: Decimal?, max: Decimal) -> CGFloat {
        guard let v = value, max > 0 else { return 0 }
        return CGFloat(truncating: NSDecimalNumber(decimal: v)) / CGFloat(truncating: NSDecimalNumber(decimal: max))
    }
}
