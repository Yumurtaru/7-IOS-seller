import SwiftUI

// ============================================================================
//  Клиенты (RFM) — GET /api/seller/clients?search=&segment= (bare array, до 500).
//  Сегменты сервера: loyal (≤30 дн) / at_risk (≤90 дн) / churned (>90 дн).
// ============================================================================

enum ClientSegments {
    /// АY: те же подписи, что в кабинете и на Android; со сводкой сервера — с числом.
    static let chips: [(String?, String)] = [
        (nil, "Все"), ("loyal", "Постоянные"), ("at_risk", "Под угрозой ухода"), ("churned", "Ушедшие"),
    ]
    static func label(_ s: String?) -> String {
        switch s {
        case "loyal": return "Постоянный"
        case "at_risk": return "Под угрозой ухода"
        case "churned": return "Ушёл"
        default: return s ?? "—"
        }
    }
    static func color(_ s: String?) -> Color {
        switch s {
        case "loyal": return Brand.green
        case "at_risk": return Brand.amber
        case "churned": return Brand.red
        default: return Brand.muted
        }
    }
}

@MainActor
final class ClientsViewModel: ObservableObject {
    @Published var items: [ClientSummary] = []
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var search = ""
    @Published var segment: String? {
        didSet { if segment != oldValue && !applyingServerState { items = []; state = .loading; loadGen += 1; Task { await load() } } }
    }

    /// АY: сводка сегментов (nil — старый сервер); есть — сервер знает и sort/dir.
    @Published var segments: ClientSegmentsStats?
    @Published var sort: ClientSort = .spent {
        didSet { if sort != oldValue && !applyingServerState { items = []; state = .loading; loadGen += 1; Task { await load() } } }
    }

    private var searchTask: Task<Void, Never>?
    /// ВА: выбор приведён к тому, что сервер вернул в meta, — список этого ответа уже
    /// соответствует ему, перечитывать не нужно (иначе вышел бы пустой результат/цикл).
    private var applyingServerState = false

    func loadSegments() async {
        let s = await API.shared.clientSegments()
        segments = s
        // Сайт откатили — сортировку снимаем: список шёл бы «по сумме» под другой подписью.
        if s == nil && sort != .spent { sort = .spent }
    }

    func load() async {
        // Сортировка выбрана — сначала убеждаемся, что сервер её ещё знает
        // (сводка сегментов отвечает): иначе список «по сумме» шёл бы под другой подписью.
        if sort != .spent && segments != nil {
            let s = await API.shared.clientSegments()
            if s == nil { segments = nil; sort = .spent; return }   // didSet sort перечитает
            segments = s
        }
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        do {
            let sq = segments != nil ? sort.query : nil
            let (fresh, meta) = try await API.shared.clientsPage(search: search, segment: segment,
                                                                 sort: sq?.sort, dir: sq?.dir)
            guard myGen == loadGen else { return }
            // ВА (сайт А618): meta ответа — что сервер применил на самом деле. Не совпало с
            // отправленным — выбор в UI становится таким, как вернул сервер; строки этого
            // ответа остаются (они уже соответствуют ему). Нет ключей meta — как раньше.
            if let fix = Ba.clientsFix(meta: meta, sentSegment: segment, sentSort: sq?.sort, sentDir: sq?.dir) {
                applyingServerState = true
                if fix.changeSegment { segment = fix.segment }
                if fix.changeSort { sort = ClientSort.from(sort: fix.sort, dir: fix.dir) }
                applyingServerState = false
            }
            items = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Дебаунс поиска 400 мс — не дёргаем сервер на каждую букву.
    func searchChanged() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await load()
        }
    }
}

/// АY: сортировка списка клиентов (sellerClientsRows: spent|orders|last|avg|name|first).
enum ClientSort: String, CaseIterable, Identifiable {
    case spent, orders, lastRecent, lastOld, avg, name, first
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spent:      return "По сумме покупок"
        case .orders:     return "По числу заказов"
        case .lastRecent: return "Недавно заказывали"
        case .lastOld:    return "Давно не заказывали"
        case .avg:        return "По среднему чеку"
        case .name:       return "По имени"
        case .first:      return "Сначала новые клиенты"
        }
    }
    /// ВА: сортировка по ответу сервера (meta.sort + meta.dir). Неизвестное сочетание — «по сумме»
    /// (его сервер отдаёт по умолчанию). dir нет — направление по умолчанию для сортировки.
    static func from(sort: String?, dir: String?) -> ClientSort {
        switch sort {
        case "orders": return .orders
        case "last": return dir == "asc" ? .lastOld : .lastRecent
        case "avg": return .avg
        case "name": return .name
        case "first": return .first
        default: return .spent
        }
    }
    /// .spent — без параметров, как раньше (сервер сам сортирует по сумме).
    var query: (sort: String, dir: String)? {
        switch self {
        case .spent:      return nil
        case .orders:     return ("orders", "desc")
        case .lastRecent: return ("last", "desc")
        case .lastOld:    return ("last", "asc")
        case .avg:        return ("avg", "desc")
        case .name:       return ("name", "asc")
        case .first:      return ("first", "desc")
        }
    }
}

struct ClientsView: View {
    @StateObject private var vm = ClientsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            chips
            List {
                ForEach(vm.items) { client in
                    NavigationLink {
                        ClientDetailView(clientId: client.clientId, askReason: vm.segments != nil,
                                         onChanged: { Task { await vm.load(); await vm.loadSegments() } })
                    } label: {
                        ClientRow(client: client)
                    }
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable {
                await vm.loadSegments()
                await vm.load()
            }
            // Пустой ответ на поиск или сегмент читался как «Клиентов пока нет» —
            // будто клиентов у магазина нет вовсе. Под фильтром — «Никого не нашли».
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "person.2",
                       emptyTitle: isFiltered ? "Никого не нашли" : "Клиентов пока нет",
                       emptySubtitle: isFiltered ? "Измените запрос или выберите сегмент «Все»"
                                                 : "Здесь появятся все, кто оформлял заказы",
                       retry: { Task { await vm.load(); await vm.loadSegments() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Клиенты")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $vm.search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Имя, телефон или email")
        .onChange(of: vm.search) { _ in vm.searchChanged() }
        // АY: сортировка — только когда сервер её знает (есть сводка сегментов).
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.segments != nil {
                    Menu {
                        Picker("Сортировка", selection: $vm.sort) {
                            ForEach(ClientSort.allCases) { s in Text(s.title).tag(s) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Сортировка")
                }
            }
        }
        // Возврат из карточки клиента заново тянул весь список (до 500 строк),
        // хотя после бонуса и чёрного списка его уже перечитывает onChanged.
        .task {
            if vm.state != .loaded {
                await vm.load()
                await vm.loadSegments()
            }
        }
    }

    private var isFiltered: Bool {
        !vm.search.trimmingCharacters(in: .whitespaces).isEmpty || vm.segment != nil
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let stats = vm.segments {
                    // АY: сводка сервера — подписи с числом клиентов.
                    ForEach(ClientSegments.chips, id: \.1) { value, title in
                        FilterChip(title: stats.count(value).map { "\(title) (\($0))" } ?? title,
                                   selected: vm.segment == value) {
                            vm.segment = value
                        }
                    }
                } else {
                    ForEach(ClientSegments.chips, id: \.1) { value, title in
                        FilterChip(title: title, selected: vm.segment == value) {
                            vm.segment = value
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

struct ClientRow: View {
    let client: ClientSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(client.name ?? "Без имени")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.text)
                if client.blacklisted == true {
                    StatusBadge(text: "ЧС", color: Brand.red)
                }
                Spacer()
                StatusBadge(text: ClientSegments.label(client.segment),
                            color: ClientSegments.color(client.segment))
            }
            // паритет с Android: телефон и почта клиента прямо в списке.
            let contacts = joinedNonEmpty([client.phone, client.email], separator: " · ")
            if !contacts.isEmpty {
                Text(contacts).font(.caption).foregroundColor(Brand.muted).lineLimit(1)
            }
            HStack(spacing: 8) {
                // «1 заказов», «2 заказов» — склоняем.
                Text(Self.ordersText(client.ordersCount ?? 0))
                Text(Money.rub(client.totalSpent))
                if let bonus = client.bonusBalance, bonus > 0 {
                    Text("бонусы: \(Money.rub(bonus))")
                }
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
            if let last = client.lastOrder {
                Text("Последний заказ: \(DateFmt.short(last))")
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 3)
    }

    private static func ordersText(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "\(n) заказов" }
        if m10 == 1 { return "\(n) заказ" }
        if m10 >= 2 && m10 <= 4 { return "\(n) заказа" }
        return "\(n) заказов"
    }
}
