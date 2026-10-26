import SwiftUI

// ============================================================================
//  Ингредиенты — сырьё для тех. карт и складских документов ресторана.
//  Раздела в приложении не было.
//
//  Остаток (stock_qty) здесь только показывается: меняют его документы
//  склада, а не эта форма. Поэтому в редактировании его нет — иначе цифра
//  разошлась бы с движениями.
// ============================================================================

@MainActor
final class IngredientsViewModel: ObservableObject {
    @Published var items: [Ingredient] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var busy = false

    func load() async {
        if items.isEmpty { state = .loading }
        do { items = try await API.shared.ingredients(); state = .loaded }
        catch is CancellationError {}
        catch { state = .failed(error.localizedDescription) }
    }

    func create(name: String, unit: String, minQty: Decimal, price: Decimal, category: String?) async -> Bool {
        guard !busy else { return false }   // двойной тап создавал два ингредиента
        busy = true; defer { busy = false }
        do {
            _ = try await API.shared.createIngredient(name: name, unit: unit, minQty: minQty,
                                                      pricePerUnit: price, category: category)
            await load()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func delete(_ i: Ingredient) async {
        do { try await API.shared.deleteIngredient(id: i.ingredientId); await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct IngredientsView: View {
    @StateObject private var vm = IngredientsViewModel()
    @State private var creating = false
    @State private var query = ""
    /// Паритет с Android: удаление ингредиента — с вопросом (он может быть в тех. картах).
    @State private var deleting: Ingredient?

    private var filtered: [Ingredient] {
        guard !query.isEmpty else { return vm.items }
        return vm.items.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            ForEach(filtered) { i in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.name ?? "—").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                        Text("\(qty(i.stockQty)) \(i.unit ?? "") · \(Money.rub(i.pricePerUnit)) за \(i.unit ?? "ед")")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                    Spacer()
                    // Ниже минимума — самое важное, что видно в этом списке.
                    if i.isLow {
                        StatusBadge(text: "мало", color: Brand.red)
                    }
                }
                // Без полного свайпа: длинный жест удалял ингредиент тех. карт
                // без вопроса — только нажатием кнопки.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { deleting = i } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .searchable(text: $query, prompt: "Поиск ингредиента")
        .navigationTitle("Ингредиенты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await vm.load() }
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.load() } }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "leaf", emptyTitle: "Ингредиентов нет",
                   emptySubtitle: "Из ингредиентов собираются тех. карты блюд",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $creating) {
            IngredientCreateSheet(busy: vm.busy) { name, unit, minQty, price, category in
                await vm.create(name: name, unit: unit, minQty: minQty, price: price, category: category)
            }
            .errorAlert($vm.error)
        }
        .confirmationDialog(
            "Удалить «\(deleting?.name ?? "ингредиент")»?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { ing in
            Button("Удалить", role: .destructive) {
                deleting = nil
                Task { await vm.delete(ing) }
            }
            Button("Отмена", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("Проверьте, что он больше не нужен в тех. картах блюд.")
        }
        .alert("Не получилось", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("Понятно", role: .cancel) { vm.error = nil }
        } message: { Text(vm.error ?? "") }
    }

    /// Общий форматтер вместо нового NumberFormatter на каждую строку списка.
    private func qty(_ v: Decimal?) -> String {
        QtyFmt.qty(v)
    }
}

private struct IngredientCreateSheet: View {
    let busy: Bool
    let onCreate: (String, String, Decimal, Decimal, String?) async -> Bool

    @State private var name = ""
    @State private var unit = "г"
    @State private var minQty = "0"
    @State private var price = "0"
    @State private var category = ""
    @Environment(\.dismiss) private var dismiss

    private static let units = ["г", "кг", "мл", "л", "шт", "уп"]

    /// То же условие, что гасит «Создать» (кроме пустого названия).
    private var numbersInvalid: Bool {
        let mq = minQty.trimmingCharacters(in: .whitespaces)
        let pr = price.trimmingCharacters(in: .whitespaces)
        if !mq.isEmpty && Money.strict(minQty, maxFraction: 3) == nil { return true }
        return !pr.isEmpty && Money.strict(price) == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                    Picker("Единица", selection: $unit) {
                        ForEach(Self.units, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Категория (по желанию)", text: $category)
                }
                .listRowBackground(Brand.card)

                Section {
                    TextField("Минимальный остаток", text: $minQty).keyboardType(.decimalPad)
                    TextField("Цена за единицу", text: $price).keyboardType(.decimalPad)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        // «Создать» гасла при опечатке в числе молча — пишем причину.
                        if numbersInvalid {
                            Text("Минимальный остаток и цена — числа, например 500 или 0,5")
                                .foregroundColor(Brand.red)
                        }
                        Text("Остаток меняется документами склада, здесь его задать нельзя.")
                    }
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Новый ингредиент")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        // Строго: «1 500» раньше давало цену 1 ₽.
                        let mq = Money.strict(minQty, maxFraction: 3) ?? 0
                        let pr = Money.strict(price) ?? 0
                        Task {
                            let ok = await onCreate(name.trimmingCharacters(in: .whitespaces), unit, mq, pr,
                                                    category.isEmpty ? nil : category)
                            if ok { dismiss() }
                        }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (!minQty.trimmingCharacters(in: .whitespaces).isEmpty && Money.strict(minQty, maxFraction: 3) == nil)
                              || (!price.trimmingCharacters(in: .whitespaces).isEmpty && Money.strict(price) == nil))
                }
            }
        }
    }
}
