import SwiftUI

// ============================================================================
//  Наборы (комбо) — раздела в приложении не было.
//
//  Важно про модель сервера: отдельной сущности «набор» нет. Набор — это
//  обычный товар, у которого появились строки в combo_items. Поэтому:
//   • создать пустой набор нельзя — сначала выбираем товар-набор из каталога
//     и кладём в него первую позицию;
//   • удалив все позиции, мы «расформируем» набор — товар останется товаром.
//  Это ровно то, что делает веб-панель, и менять поведение на клиенте нельзя.
// ============================================================================

@MainActor
final class CombosViewModel: ObservableObject {
    @Published var combos: [ComboSummary] = []
    @Published var products: [ComboPickProduct] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    func load() async {
        if combos.isEmpty { state = .loading }
        do {
            async let c = API.shared.combos()
            async let p = API.shared.comboPickProducts()
            combos = try await c
            products = try await p
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// Что открыто в шторке состава. Отдельный тип, а не ComboSummary:
/// набором может стать товар, которого в списке наборов ещё нет.
struct ComboTarget: Identifiable {
    let id: Int
    let name: String
    let price: Decimal?
}

struct CombosView: View {
    @StateObject private var vm = CombosViewModel()
    @State private var openCombo: ComboTarget?
    @State private var picking = false
    /// Выбранный в первой шторке товар. Вторую шторку открываем, когда первая
    /// закрылась: обе сразу SwiftUI не показывает, и «+» не создавал набор.
    @State private var pendingCombo: ComboTarget?

    var body: some View {
        List {
            ForEach(vm.combos) { combo in
                Button {
                    openCombo = ComboTarget(id: combo.comboId, name: combo.name ?? "Набор", price: combo.price)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(combo.name ?? "—").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                            Text("позиций: \(combo.itemsCount ?? 0)").font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        Text(Money.rub(combo.price)).font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                    }
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Наборы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { picking = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await vm.load() }
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.load() } }
        .listState(vm.state, isEmpty: vm.combos.isEmpty,
                   emptyIcon: "square.stack.3d.up", emptyTitle: "Наборов нет",
                   emptySubtitle: "Набор — это товар, в который вложены другие товары. Выберите товар и добавьте в него состав.",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $picking, onDismiss: {
            if let p = pendingCombo { pendingCombo = nil; openCombo = p }
        }) {
            // Набором может стать любой товар — сначала выбираем, какой.
            ComboProductPicker(title: "Какой товар сделать набором?", products: vm.products) { product in
                pendingCombo = ComboTarget(id: product.pickId, name: product.name ?? "Набор", price: product.price)
                picking = false
            }
        }
        .sheet(item: $openCombo) { target in
            NavigationStack {
                ComboItemsView(target: target, products: vm.products) { Task { await vm.load() } }
            }
        }
    }
}

// ── Состав набора ────────────────────────────────────────────────────────────

@MainActor
final class ComboItemsViewModel: ObservableObject {
    @Published var items: [ComboItem] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    /// Идёт изменение состава: количество считается от показанного, и два
    /// быстрых «+» давали 2, а не 3.
    @Published var busy = false

    func load(comboId: Int) async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.comboItems(comboId: comboId)
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func setItem(comboId: Int, productId: Int, qty: Int) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            try await API.shared.setComboItem(comboId: comboId, productId: productId, qty: qty)
            await load(comboId: comboId)
        } catch { self.error = error.localizedDescription }
    }

    func remove(_ item: ComboItem, comboId: Int) async {
        do {
            try await API.shared.deleteComboItem(itemId: item.itemId)
            await load(comboId: comboId)
        } catch { self.error = error.localizedDescription }
    }
}

struct ComboItemsView: View {
    let target: ComboTarget
    let products: [ComboPickProduct]
    var onChange: () -> Void = {}

    @StateObject private var vm = ComboItemsViewModel()
    @State private var adding = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                InfoRow(label: "Цена набора", value: Money.rub(target.price))
            } footer: {
                Text("Цену набора задаёт сам товар — измените её в карточке товара.")
            }
            .listRowBackground(Brand.card)

            Section("Состав") {
                ForEach(vm.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                            Text(Money.rub(item.price)).font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        // Количество меняем тем же POST, что и добавление:
                        // сервер сам решает по паре (набор, товар).
                        Stepper("× \(item.qty ?? 1)", value: Binding(
                            get: { item.qty ?? 1 },
                            set: { newQty in
                                Task { await vm.setItem(comboId: target.id,
                                                        productId: item.productId ?? 0,
                                                        qty: max(1, newQty)) }
                            }
                        ), in: 1...99)
                        .labelsHidden()
                        .disabled(vm.busy)
                        Text("× \(item.qty ?? 1)").font(.caption).foregroundColor(Brand.muted)
                    }
                    // Без полного свайпа: длинный жест сразу убирал позицию, а
                    // последняя убранная позиция расформировывает весь набор.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { await vm.remove(item, comboId: target.id); onChange() }
                        } label: { Label("Убрать", systemImage: "trash") }
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(target.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                // Пока меняется количество, добавление ждёт: иначе выбранный
                // товар молча не добавлялся (запрос отсекался защитой).
                Button { adding = true } label: { Image(systemName: "plus") }
                    .disabled(vm.busy)
            }
        }
        .task { await vm.load(comboId: target.id) }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "square.stack.3d.up", emptyTitle: "Состав пуст",
                   emptySubtitle: "Добавьте товары, из которых собран набор",
                   retry: { Task { await vm.load(comboId: target.id) } })
        .sheet(isPresented: $adding) {
            ComboProductPicker(title: "Добавить в набор",
                               products: products.filter { $0.pickId != target.id }) { product in
                adding = false
                Task { await vm.setItem(comboId: target.id, productId: product.pickId, qty: 1); onChange() }
            }
        }
        .alert("Не получилось", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("Понятно", role: .cancel) { vm.error = nil }
        } message: { Text(vm.error ?? "") }
    }
}

// ── Выбор товара ─────────────────────────────────────────────────────────────

struct ComboProductPicker: View {
    let title: String
    let products: [ComboPickProduct]
    let onPick: (ComboPickProduct) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [ComboPickProduct] {
        guard !query.isEmpty else { return products }
        return products.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { p in
                Button {
                    onPick(p)
                    dismiss()
                } label: {
                    HStack {
                        Text(p.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                        Spacer()
                        Text(Money.rub(p.price)).font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .listRowBackground(Brand.card)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Поиск товара")
            // Пустой лист без слов выглядел как сломанная кнопка «+».
            .overlay {
                if filtered.isEmpty {
                    EmptyState(icon: "magnifyingglass",
                               title: query.isEmpty ? "Товаров нет" : "Ничего не найдено",
                               subtitle: query.isEmpty ? "Сначала добавьте товары в каталог или обновите экран" : nil)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}
