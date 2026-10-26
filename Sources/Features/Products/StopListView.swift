import SwiftUI

// ============================================================================
//  Стоп-лист — GET/POST/DELETE /api/seller/stop-list.
//  Постановка на стоп (товар целиком) с причиной и таймером until_minutes,
//  снятие — DELETE (сервер сам возвращает доступность позиции).
// ============================================================================

@MainActor
final class StopListViewModel: ObservableObject {
    @Published var items: [StopListItem] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    // Добавление
    @Published var products: [ProductSummary] = []
    @Published var searching = false
    /// Поиск товара не удался (нет сети). Раньше список просто пустел, и
    /// казалось, что такого товара нет — блюдо так и не ставили на стоп.
    @Published var searchError: String?

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.stopList()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Последний введённый запрос: поздний ответ на «мол» не должен затирать «молоко».
    private var lastQuery = ""

    func searchProducts(_ q: String) async {
        lastQuery = q
        searching = true
        var found: [ProductSummary] = []
        var failure: String?
        do {
            found = try await API.shared.products(category: nil, status: nil, q: q, page: 1).items
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
        guard q == lastQuery else { return }
        products = found
        searchError = failure
        searching = false
    }

    /// Поиск с задержкой: раньше каждая буква слала запрос всего каталога
    /// (на «молоко» — шесть подряд), и на слабой сети ответы шли в очередь.
    private var searchTask: Task<Void, Never>?
    func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        lastQuery = q          // ответ на прежний текст уже не применится
        searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.searchProducts(q)
        }
    }

    private var adding = false

    func addToStop(productId: Int, reason: String?, untilMinutes: Int?) async -> Bool {
        // Двойной тап «Поставить на стоп» — второй запрос получал ошибку.
        guard !adding else { return false }
        adding = true
        defer { adding = false }
        error = nil
        do {
            _ = try await API.shared.addToStopList(productId: productId, modifierId: nil,
                                                   reason: reason, untilMinutes: untilMinutes)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Позиции, снятие которых уже в пути: повторный свайп «Вернуть» слал
    /// второй DELETE, и поверх успешного снятия появлялась ошибка «не найдено».
    private var removingIds: Set<Int> = []

    func remove(_ item: StopListItem) async {
        guard !removingIds.contains(item.itemId) else { return }
        removingIds.insert(item.itemId)
        defer { removingIds.remove(item.itemId) }
        error = nil
        do {
            try await API.shared.removeFromStopList(id: item.itemId)
            items.removeAll { $0.itemId == item.itemId }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct StopListView: View {
    @StateObject private var vm = StopListViewModel()
    @State private var showAdd = false

    var body: some View {
        List {
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
            }
            ForEach(vm.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.modifierName ?? item.productName ?? "Позиция")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(Brand.text)
                    if item.modifierId != nil, let pname = item.productName {
                        Text("Модификатор товара «\(pname)»").font(.caption).foregroundColor(Brand.muted)
                    }
                    // паритет с Android: кто поставил на стоп (by_name сервера).
                    if let who = item.byName, !who.isEmpty {
                        Text("поставил: " + who).font(.caption).foregroundColor(Brand.muted)
                    }
                    HStack(spacing: 8) {
                        if let reason = item.reason, !reason.isEmpty {
                            Text(reason).font(.caption).foregroundColor(Brand.muted)
                        }
                        if let until = item.until, !until.isEmpty {
                            StatusBadge(text: "до \(DateFmt.short(until))", color: Brand.amber)
                        }
                        Spacer()
                        Text(DateFmt.short(item.createdAt)).font(.caption2).foregroundColor(Brand.muted)
                    }
                }
                .listRowBackground(Brand.card)
                .swipeActions(edge: .trailing) {
                    Button {
                        Task { await vm.remove(item) }
                    } label: {
                        Label("Вернуть", systemImage: "arrow.uturn.backward")
                    }
                    .tint(Brand.green)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Стоп-лист")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "nosign", emptyTitle: "Стоп-лист пуст",
                   emptySubtitle: "Все позиции в продаже",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $showAdd) {
            AddToStopSheet(vm: vm)
                .errorAlert($vm.error)
        }
        .task { await vm.load() }
    }
}

struct AddToStopSheet: View {
    @ObservedObject var vm: StopListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: ProductSummary?
    @State private var reason = ""
    @State private var duration = 0   // минуты; 0 = бессрочно

    // «До завтра» раньше было ровно 1440 минут: блюдо, снятое в 22:00, не
    // продавалось и весь следующий день до 22:00. Теперь «До конца дня» —
    // до полуночи по Москве (время сервера), а сутки — отдельным пунктом.
    private let durations: [(Int, String)] = [
        (0, "Бессрочно"), (60, "1 час"), (180, "3 часа"), (-1, "До конца дня"), (1440, "Сутки"),
    ]

    /// Минут до ближайшей полуночи по Москве (не меньше 1).
    private static func minutesToMoscowMidnight(_ now: Date = Date()) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return max(1, Int((next.timeIntervalSince(now) / 60).rounded(.up)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Товар") {
                    TextField("Поиск товара", text: $query)
                        .onChange(of: query) { q in
                            vm.scheduleSearch(q)   // с задержкой, не на каждую букву
                        }
                    if vm.searching { ProgressView() }
                    if let err = vm.searchError, !vm.searching {
                        Button { Task { await vm.searchProducts(query) } } label: {
                            Text("Не удалось найти: \(err) · Повторить")
                                .font(.footnote).foregroundColor(Brand.red)
                        }
                    }
                    ForEach(vm.products.prefix(8)) { p in
                        Button {
                            selected = p
                        } label: {
                            HStack {
                                Text(p.name ?? "—").foregroundColor(Brand.text)
                                Spacer()
                                if selected?.productId == p.productId {
                                    Image(systemName: "checkmark").foregroundColor(Brand.accent)
                                }
                            }
                        }
                    }
                }
                Section("Параметры") {
                    TextField("Причина (необязательно)", text: $reason)
                    Picker("Срок", selection: $duration) {
                        ForEach(durations, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                }
                Section {
                    Button {
                        guard let p = selected else { return }
                        Task {
                            if await vm.addToStop(productId: p.productId,
                                                  reason: reason.isEmpty ? nil : reason,
                                                  untilMinutes: duration < 0 ? Self.minutesToMoscowMidnight()
                                                                : (duration > 0 ? duration : nil)) {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack { Spacer(); Text("Поставить на стоп").bold(); Spacer() }
                    }
                    .disabled(selected == nil)
                } footer: {
                    // Кнопка серая, пока товар не отмечен галочкой, — без подсказки
                    // казалось, что «Поставить на стоп» не работает.
                    if selected == nil {
                        Text("Выберите товар в списке выше — нажмите на его название.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("На стоп")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
            }
            .task { await vm.searchProducts("") }
        }
    }
}
