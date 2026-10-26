import SwiftUI

// ============================================================================
//  Топ-позиции — GET /api/seller/analytics/top-products?period= (до 50):
//  продажи, выручка, возвраты и % возвратов по каждой позиции.
// ============================================================================

@MainActor
final class TopProductsViewModel: ObservableObject {
    @Published var items: [TopProductRow] = []
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
        if items.isEmpty { state = .loading }
        do {
            let fresh = try await API.shared.topProducts(period: period)
            guard myGen == loadGen else { return }
            items = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

struct TopProductsView: View {
    @StateObject private var vm = TopProductsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Период", selection: $vm.period) {
                ForEach(AnalyticsViewModel.periods, id: \.0) { value, title in
                    Text(title).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            List {
                ForEach(vm.items) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.name ?? "—")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.text)
                                .lineLimit(1)
                            Spacer()
                            Text(Money.rub(row.rev))
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(Brand.text)
                        }
                        HStack(spacing: 8) {
                            if let cat = row.category, !cat.isEmpty { Text(cat) }
                            // Весовой товар: «2,5» кг было «×2» — дробную часть отрезало.
                            // «Продано» — за вычетом возвратов, как график «Топ-10» в
                            // аналитике (сервер: qty_net = qty − ret, top-products в
                            // seller_analytics.php). Голое qty расходилось с графиком.
                            Text("продано ×\(QtyFmt.qty(Self.netQty(row)))")
                            if let pct = row.returnPct, pct > 0 {
                                Text("возвраты \(NSDecimalNumber(decimal: pct).doubleValue, specifier: "%.1f")%")
                                    .foregroundColor(Brand.red)
                            }
                        }
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "list.number", emptyTitle: "Нет продаж за период",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Топ-позиции")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    /// Отпущено минус возвращено, не ниже нуля.
    private static func netQty(_ row: TopProductRow) -> Decimal {
        let net = (row.qty ?? 0) - (row.ret ?? 0)
        return net > 0 ? net : 0
    }
}
