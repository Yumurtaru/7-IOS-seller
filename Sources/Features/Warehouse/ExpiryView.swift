import SwiftUI

// ============================================================================
//  Сроки годности — GET /api/seller/warehouse/expiry?days= (партии Батча 3).
//  Просроченные и «скоро истекает», сводка стоимости под риском.
// ============================================================================

@MainActor
final class ExpiryViewModel: ObservableObject {
    @Published var report: ExpiryReport?
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var days = 14

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if report == nil { state = .loading }
        do {
            let fresh = try await API.shared.warehouseExpiry(days: days)
            guard myGen == loadGen else { return }
            report = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

struct ExpiryView: View {
    @StateObject private var vm = ExpiryViewModel()

    private let windows = [7, 14, 30, 60]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                windowPicker
                if let s = vm.report?.summary { summaryCard(s) }
                itemsList
            }
            .padding(16)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Сроки годности")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: (vm.report?.items ?? []).isEmpty,
                   emptyIcon: "checkmark.seal", emptyTitle: "Просроченного нет",
                   emptySubtitle: "В окне \(vm.days) дн. партии с истекающим сроком не найдены",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }

    private var windowPicker: some View {
        HStack(spacing: 8) {
            ForEach(windows, id: \.self) { d in
                FilterChip(title: "\(d) дн.", selected: vm.days == d) {
                    // Другое окно — старые партии и сводку убираем: при сбое загрузки
                    // под чипом «60 дн.» оставались цифры «7 дн.», как будто это они.
                    if vm.days != d { vm.report = nil }
                    vm.days = d
                    Task { await vm.load() }
                }
            }
            Spacer()
        }
    }

    private func summaryCard(_ s: ExpirySummary) -> some View {
        SectionCard {
            HStack(spacing: 0) {
                metric("Просрочено", "\(s.expired ?? 0)", Brand.red)
                metric("Истекает", "\(s.soon ?? 0)", Brand.amber)
                metric("Под риском", Money.rub(s.atRiskValue), Brand.text)
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.headline).foregroundColor(color)
                .minimumScaleFactor(0.7).lineLimit(1)
            Text(title).font(.caption2).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var itemsList: some View {
        let items = vm.report?.items ?? []
        if !items.isEmpty {
            SectionCard(title: "Партии") {
                ForEach(items) { b in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(b.name ?? "—")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text)
                                .lineLimit(2)
                            Spacer()
                            badge(b)
                        }
                        HStack {
                            Text(QtyFmt.qty(b.qty) + " " + (b.unit ?? "") + (b.warehouse.map { " · " + $0 } ?? ""))
                                .font(.caption).foregroundColor(Brand.muted)
                            Spacer()
                            Text(Money.rub((b.qty ?? 0) * (b.cost ?? 0)))
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                    .padding(.vertical, 4)
                    if b.id != items.last?.id { Divider().overlay(Brand.border) }
                }
            }
        }
    }

    private func badge(_ b: ExpiryBatch) -> some View {
        let days = b.daysLeft ?? 0
        if b.expired == true || days < 0 {
            return StatusBadge(text: "просрочено", color: Brand.red)
        }
        if days == 0 {
            return StatusBadge(text: "сегодня", color: Brand.red)
        }
        // «через 1 дн.» / «через 2 дн.» — пишем число с правильной формой слова.
        let left = RuPlural.count(days, "день", "дня", "дней")
        return StatusBadge(text: "истекает через " + left, color: days <= 3 ? Brand.amber : Brand.muted)
    }
}
