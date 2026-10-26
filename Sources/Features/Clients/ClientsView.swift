import SwiftUI

// ============================================================================
//  Клиенты (RFM) — GET /api/seller/clients?search=&segment= (bare array, до 500).
//  Сегменты сервера: loyal (≤30 дн) / at_risk (≤90 дн) / churned (>90 дн).
// ============================================================================

enum ClientSegments {
    static let chips: [(String?, String)] = [
        (nil, "Все"), ("loyal", "Лояльные"), ("at_risk", "Уходят"), ("churned", "Потеряны"),
    ]
    static func label(_ s: String?) -> String {
        switch s {
        case "loyal": return "Лояльный"
        case "at_risk": return "Под риском"
        case "churned": return "Потерян"
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
        didSet { if segment != oldValue { items = []; state = .loading; loadGen += 1; Task { await load() } } }
    }

    private var searchTask: Task<Void, Never>?

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        do {
            let fresh = try await API.shared.clients(search: search, segment: segment)
            guard myGen == loadGen else { return }
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

struct ClientsView: View {
    @StateObject private var vm = ClientsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            chips
            List {
                ForEach(vm.items) { client in
                    NavigationLink {
                        ClientDetailView(clientId: client.clientId, onChanged: { Task { await vm.load() } })
                    } label: {
                        ClientRow(client: client)
                    }
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            // Пустой ответ на поиск или сегмент читался как «Клиентов пока нет» —
            // будто клиентов у магазина нет вовсе. Под фильтром — «Никого не нашли».
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "person.2",
                       emptyTitle: isFiltered ? "Никого не нашли" : "Клиентов пока нет",
                       emptySubtitle: isFiltered ? "Измените запрос или выберите сегмент «Все»"
                                                 : "Здесь появятся все, кто оформлял заказы",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Клиенты")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $vm.search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Имя, телефон или email")
        .onChange(of: vm.search) { _ in vm.searchChanged() }
        // Возврат из карточки клиента заново тянул весь список (до 500 строк),
        // хотя после бонуса и чёрного списка его уже перечитывает onChanged.
        .task { if vm.state != .loaded { await vm.load() } }
    }

    private var isFiltered: Bool {
        !vm.search.trimmingCharacters(in: .whitespaces).isEmpty || vm.segment != nil
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ClientSegments.chips, id: \.1) { value, title in
                    FilterChip(title: title, selected: vm.segment == value) {
                        vm.segment = value
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
