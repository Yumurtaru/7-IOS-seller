import SwiftUI

// ============================================================================
//  Прогноз спроса — GET /api/seller/analytics/forecast (до 100 позиций):
//  взвешенная скользящая средняя (0.6×последняя неделя + 0.4×средняя за 28 дн)
//  + тренд неделя-к-неделе. Считает сервер — клиент только показывает.
// ============================================================================

@MainActor
final class ForecastViewModel: ObservableObject {
    @Published var items: [ForecastRow] = []
    @Published var state: LoadState = .idle

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.analyticsForecast()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct ForecastView: View {
    @StateObject private var vm = ForecastViewModel()

    var body: some View {
        List {
            Section {
                Text("Сколько приготовить или закупить на следующие 7 дней — по продажам за 4 недели с учётом тренда.")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                    .listRowBackground(Color.clear)
            }
            Section {
                ForEach(vm.items) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.name ?? "—")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.text)
                                .lineLimit(1)
                            Spacer()
                            StatusBadge(text: "≈ \(row.forecast7 ?? 0) шт",
                                        color: Brand.accent)
                        }
                        HStack(spacing: 10) {
                            Text("за 7 дн: \(row.sold7 ?? 0)")
                            Text("до этого: \(row.soldPrev7 ?? 0)")
                            trendBadge(row.trendPct ?? 0)
                        }
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                        // АY (сайт А616): завтра, остаток (null — не ведётся) и сколько докупить.
                        if row.forecast1Qty != nil || row.stockQty != nil || row.toBuy != nil {
                            HStack(spacing: 10) {
                                if let f1 = row.forecast1Qty { Text("Завтра ≈ \(QtyFmt.qty(f1))") }
                                if let st = row.stockQty { Text("Остаток: \(QtyFmt.qty(st))") }
                                if let tb = row.toBuy {
                                    Text("Докупить: \(QtyFmt.qty(tb))")
                                        .foregroundColor(tb > 0 ? Brand.amber : Brand.muted)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(Brand.muted)
                        }
                    }
                    .padding(.vertical, 3)
                    .listRowBackground(Brand.card)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "chart.line.uptrend.xyaxis",
                   emptyTitle: "Недостаточно данных",
                   emptySubtitle: "Прогноз появится после первых продаж",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Прогноз спроса")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    @ViewBuilder
    private func trendBadge(_ pct: Int) -> some View {
        if pct != 0 {
            Label("\(pct > 0 ? "+" : "")\(pct)%",
                  systemImage: pct > 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(pct > 0 ? Brand.green : Brand.red)
        }
    }
}
