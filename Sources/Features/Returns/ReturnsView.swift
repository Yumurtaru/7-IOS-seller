import SwiftUI
import Combine

// ============================================================================
//  Возвраты — GET /api/seller/returns?status=&search= (bare array, до 200),
//  деталь, approve (бонусы/ручной + сумма), reject с причиной.
//  ВА (сайт А618): поиск (номер заказа, клиент, телефон) — поле видно, только если в
//  ответе есть meta.search; старый сервер ключа не даёт — поля нет.
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

    /// Набранный поиск. Запрос уходит через 400 мс после последней буквы (как в заказах).
    @Published var search = "" {
        didSet { if search != oldValue && !suppressSearch { scheduleSearch() } }
    }
    /// Поиск, с которым загружен список (?search=); "" — без поиска.
    @Published private(set) var appliedSearch = ""
    /// В последнем ответе есть meta.search — сервер поиск знает, поле показываем.
    @Published private(set) var searchShown = false
    /// Поиск отправили, а ключа нет (сайт откатили): плашка, поле скрыто, список перечитан без поиска.
    @Published private(set) var searchUnavailable = false
    private var searchTask: Task<Void, Never>?
    private var suppressSearch = false
    var isSearching: Bool { !appliedSearch.isEmpty && !searchUnavailable }

    static let statusChips: [(String?, String)] = [
        ("pending", "Ожидают"), (nil, "Все"), ("approved", "Одобрены"),
        ("refunded", "Возвращены"), ("closed", "Выплачены"), ("rejected", "Отклонены"),
    ]

    /// Поиск на сервере: ждём паузу в наборе, затем список с ?search=. Отменяется только
    /// ожидание паузы; сам запрос идёт отдельной задачей (устаревший ответ отсекает loadGen).
    private func scheduleSearch() {
        searchTask?.cancel()
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if term == appliedSearch {
            if state == .loading && items.isEmpty { Task { await load() } }
            return
        }
        searchTask = Task { [weak self] in
            if !term.isEmpty { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled, let self = self else { return }
            self.appliedSearch = term
            self.items = []
            self.state = .loading
            self.loadGen += 1
            Task { await self.load() }
        }
    }

    /// keepNotice: перечитывание сразу после отката поиска — плашка остаётся; иначе сбрасывается.
    func load(keepNotice: Bool = false) async {
        if !keepNotice { searchUnavailable = false }
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        let sentSearch: String? = appliedSearch.isEmpty ? nil : appliedSearch
        do {
            let (fresh, meta) = try await API.shared.returnsPage(status: statusFilter, search: sentSearch)
            guard myGen == loadGen else { return }
            // ВА: ключ meta.search — признак поиска на сервере. Пропал при отправленном поиске
            // (сайт откатили) — плашка, поле скрыть, перечитать без поиска, не выдавая список за найденное.
            let hasKey = Ba.hasKey(meta, "search")
            searchShown = hasKey
            if Ba.searchMissing(sent: sentSearch, meta: meta) {
                searchUnavailable = true
                searchTask?.cancel()
                suppressSearch = true
                search = ""
                suppressSearch = false
                appliedSearch = ""
                items = []
                state = .loading
                Task { await load(keepNotice: true) }
                return
            }
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
            if vm.searchShown { searchField }
            chips
            if vm.searchUnavailable {
                ServerNoticeBar(text: Ba.returnsSearchUnavailable)
            }
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
                       emptyIcon: vm.isSearching ? "magnifyingglass" : "arrow.uturn.left.circle",
                       emptyTitle: vm.isSearching ? "По запросу «\(vm.appliedSearch)» возвратов не найдено" : "Возвратов нет",
                       emptySubtitle: vm.isSearching ? "Проверьте номер заказа, имя или телефон." : nil,
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

    /// Поле поиска (номер заказа, клиент, телефон). Не .searchable: поле должно появляться
    /// и пропадать по признаку сервера, а экран живёт внутри чужого NavigationStack.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Brand.muted)
            TextField(Ba.searchPlaceholder, text: $vm.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !vm.search.isEmpty {
                Button { vm.search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Brand.muted)
                }
                .accessibilityLabel("Очистить поиск")
            }
        }
        .padding(10)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 16)
        .padding(.top, 8)
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
                Text("Заказ \(returnOrderLabel(number: ret.orderNumber, orderId: ret.orderId))")
                    .layoutPriority(1)
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
