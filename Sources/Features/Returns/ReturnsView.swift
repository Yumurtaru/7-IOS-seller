import SwiftUI
import Combine

// ============================================================================
//  Возвраты — GET /api/seller/returns?status= (bare array, до 200),
//  деталь, approve (бонусы/ручной + сумма), reject с причиной.
// ============================================================================

@MainActor
final class ReturnsViewModel: ObservableObject {
    @Published var items: [ReturnSummary] = []
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var statusFilter: String? = "pending" {
        didSet { if statusFilter != oldValue { items = []; state = .loading; loadGen += 1; Task { await load() } } }
    }

    static let statusChips: [(String?, String)] = [
        ("pending", "Ожидают"), (nil, "Все"), ("approved", "Одобрены"),
        ("refunded", "Возвращены"), ("closed", "Выплачены"), ("rejected", "Отклонены"),
    ]

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        do {
            let fresh = try await API.shared.returns(status: statusFilter)
            guard myGen == loadGen else { return }
            items = fresh
            state = .loaded
            // Бейдж «возвраты ждут» берётся из /shops — обновляем его вместе со списком.
            Task { await Session.shared.refreshShops() }
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

struct ReturnsView: View {
    @EnvironmentObject var router: DeepLinkRouter
    @StateObject private var vm = ReturnsViewModel()
    @State private var pushedReturnId: Int?

    var body: some View {
        VStack(spacing: 0) {
            chips
            List {
                ForEach(vm.items) { ret in
                    NavigationLink {
                        ReturnDetailView(returnId: ret.returnId, onChanged: { Task { await vm.load() } })
                    } label: {
                        ReturnRow(ret: ret)
                    }
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "arrow.uturn.left.circle", emptyTitle: "Возвратов нет",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Возвраты")
        .navigationBarTitleDisplayMode(.inline)
        // deep link из push «новый возврат»
        .navigationDestination(isPresented: Binding(
            get: { pushedReturnId != nil },
            set: { if !$0 { pushedReturnId = nil } }
        )) {
            if let id = pushedReturnId {
                ReturnDetailView(returnId: id, onChanged: { Task { await vm.load() } })
                    .id(id)
            }
        }
        .onReceive(router.$openReturnId.receive(on: DispatchQueue.main)) { id in
            guard let id = id else { return }
            pushedReturnId = id
            router.openReturnId = nil
            // Push о новой заявке при уже открытом списке: деталь открывалась,
            // а в списке под ней заявки не было до «потянуть вниз».
            Task { await vm.load() }
        }
        .task { await vm.load() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReturnsViewModel.statusChips, id: \.1) { value, title in
                    FilterChip(title: title, selected: vm.statusFilter == value) {
                        vm.statusFilter = value
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

struct ReturnRow: View {
    let ret: ReturnSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Возврат #\(ret.returnId)")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.text)
                StatusBadge(text: ReturnLabels.status(ret.status), color: ReturnLabels.color(ret.status))
                Spacer()
                Text(Money.rub(ret.refundAmount))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.text)
            }
            HStack(spacing: 8) {
                Text("Заказ №\(ret.orderId ?? 0)")
                Text(ret.type == "partial" ? "Частичный" : "Полный")
                if let client = ret.client, !client.isEmpty { Text(client) }
                // паритет с Android: причина возврата видна прямо в списке.
                if let code = ret.reasonCode, !code.isEmpty { Text(ReturnLabels.reason(code)) }
            }
            .lineLimit(1)
            .font(.caption)
            .foregroundColor(Brand.muted)
            Text(DateFmt.short(ret.createdAt))
                .font(.caption2)
                .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 3)
    }
}
