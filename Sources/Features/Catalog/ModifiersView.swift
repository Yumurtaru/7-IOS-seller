import SwiftUI

// ============================================================================
//  Модификаторы — библиотека групп магазина (добавки, размеры, соусы).
//  Раздела в приложении не было.
//
//  Особенность сервера: группа создаётся ВСЕГДА при товаре
//  (POST /products/{id}/modifier-groups) — своего «создать группу без товара»
//  нет. Но после создания группа лежит в общей библиотеке магазина и её можно
//  прикрепить к другим товарам. Поэтому при создании просим выбрать товар и
//  честно объясняем, что группа будет доступна и остальным.
// ============================================================================

@MainActor
final class ModifiersViewModel: ObservableObject {
    @Published var groups: [ModifierGroup] = []
    @Published var products: [ComboPickProduct] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var busy = false

    func load() async {
        if groups.isEmpty { state = .loading }
        do {
            async let g = API.shared.modifierGroups()
            async let p = API.shared.comboPickProducts()
            groups = try await g
            products = try await p
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func createGroup(productId: Int, name: String, multiple: Bool, required: Bool,
                     minQty: Int, maxQty: Int?) async -> Bool {
        guard !busy else { return false }   // двойной тап создавал две группы
        busy = true; defer { busy = false }
        do {
            _ = try await API.shared.createModifierGroup(productId: productId, name: name,
                                                         multiple: multiple, required: required,
                                                         minQty: minQty, maxQty: maxQty)
            await load()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func deleteGroup(_ g: ModifierGroup) async {
        do { try await API.shared.deleteModifierGroup(id: g.groupId); await load() }
        catch { self.error = error.localizedDescription }
    }

    func addOption(group: ModifierGroup, name: String, price: Decimal) async -> Bool {
        guard !busy else { return false }   // двойной тап добавлял добавку дважды
        busy = true; defer { busy = false }
        do {
            _ = try await API.shared.addModifierOption(groupId: group.groupId, name: name, price: price)
            await load()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func deleteOption(_ o: ModifierOption) async {
        do { try await API.shared.deleteModifierOption(id: o.optionId); await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct ModifiersView: View {
    @StateObject private var vm = ModifiersViewModel()
    @State private var creating = false
    @State private var addOptionTo: ModifierGroup?
    @State private var groupToDelete: ModifierGroup?
    /// АY (сайт А616): правка варианта и группы без удаления.
    @State private var editOption: ModifierOption?
    @State private var editGroup: ModifierGroup?

    /// Цена модификатора — тоже цена: удалить группу, добавить или удалить вариант
    /// сервер даёт только с правом «Менять цены» (StaffAccess::actionPerms →
    /// products.price). Без него кнопки вели к 403 — не показываем их.
    private var canPrice: Bool { Session.shared.can("products.price") }
    /// Правка названия, наличия и правил группы — право раздела «Товары»
    /// (PUT /modifiers, /modifier-groups в StaffAccess — раздел products).
    private var canEdit: Bool { Session.shared.can("products") }

    var body: some View {
        List {
            ForEach(vm.groups) { g in
                Section {
                    ForEach(g.options ?? []) { o in
                        HStack {
                            Text(o.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                            Spacer()
                            // Бесплатная добавка: «0 ₽» выглядело как незаданная цена.
                            Text((o.price ?? 0) > 0 ? Money.rub(o.price) : "бесплатно")
                                .font(.caption).foregroundColor(Brand.muted)
                            // «нет» было непонятно; так же, как в карточке товара — «Стоп».
                            if o.isAvailable == false {
                                StatusBadge(text: "Стоп", color: Brand.red)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if canEdit { editOption = o } }
                        // Без полного свайпа: длинный жест удалял вариант без вопроса.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canPrice {
                                Button(role: .destructive) { Task { await vm.deleteOption(o) } } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                    if canPrice {
                        Button {
                            addOptionTo = g
                        } label: {
                            Label("Добавить вариант", systemImage: "plus.circle")
                                .font(.subheadline)
                        }
                    }
                } header: {
                    HStack {
                        Text(g.name ?? "Группа")
                        Spacer()
                        Text(groupRule(g)).font(.caption2).foregroundColor(Brand.muted)
                        if canEdit {
                            Button { editGroup = g } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Изменить группу")
                        }
                    }
                } footer: {
                    // Группа уходит со всеми вариантами и пропадает у товаров —
                    // одно касание мелкой подписи удаляло её без вопроса.
                    if canPrice {
                        Button(role: .destructive) {
                            groupToDelete = g
                        } label: {
                            Text("Удалить группу").font(.caption)
                        }
                    }
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Модификаторы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await vm.load() }
        .confirmationDialog(
            "Удалить группу «\(groupToDelete?.name ?? "Группа")»?",
            isPresented: Binding(get: { groupToDelete != nil }, set: { if !$0 { groupToDelete = nil } }),
            titleVisibility: .visible,
            presenting: groupToDelete
        ) { g in
            Button("Удалить группу", role: .destructive) {
                groupToDelete = nil
                Task { await vm.deleteGroup(g) }
            }
            Button("Отмена", role: .cancel) { groupToDelete = nil }
        } message: { _ in
            Text("Удалятся все варианты группы, у товаров она пропадёт.")
        }
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.load() } }
        .listState(vm.state, isEmpty: vm.groups.isEmpty,
                   emptyIcon: "slider.horizontal.3", emptyTitle: "Групп нет",
                   emptySubtitle: "Группы модификаторов — это добавки, размеры и соусы, которые клиент выбирает к товару",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $creating) {
            ModifierGroupCreateSheet(products: vm.products, busy: vm.busy) { pid, name, multiple, required, minQty, maxQty in
                await vm.createGroup(productId: pid, name: name, multiple: multiple,
                                     required: required, minQty: minQty, maxQty: maxQty)
            }
            .errorAlert($vm.error)
        }
        .sheet(item: $addOptionTo) { g in
            ModifierOptionSheet(groupName: g.name ?? "Группа", busy: vm.busy) { name, price in
                await vm.addOption(group: g, name: name, price: price)
            }
            .errorAlert($vm.error)
        }
        .sheet(item: $editOption) { o in
            ModifierOptionEditSheet(option: o, canPrice: canPrice) { changed in
                if changed { Task { await vm.load() } }
            }
        }
        .sheet(item: $editGroup) { g in
            ModifierGroupEditSheet(group: g) { changed in
                if changed { Task { await vm.load() } }
            }
        }
        .alert("Не получилось", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("Понятно", role: .cancel) { vm.error = nil }
        } message: { Text(vm.error ?? "") }
    }

    private func groupRule(_ g: ModifierGroup) -> String {
        var parts: [String] = [g.isMultiple ? "несколько" : "один"]
        if g.isRequired == true { parts.append("обязательно") }
        if let mx = g.maxQty, mx > 0 { parts.append("до \(mx)") }
        return parts.joined(separator: " · ")
    }
}

// ── Новая группа ─────────────────────────────────────────────────────────────

private struct ModifierGroupCreateSheet: View {
    let products: [ComboPickProduct]
    let busy: Bool
    let onCreate: (Int, String, Bool, Bool, Int, Int?) async -> Bool

    @State private var productId: Int?
    @State private var name = ""
    @State private var multiple = false
    @State private var required = false
    @State private var minQty = 0
    @State private var maxQty = 0
    @State private var picking = false
    @Environment(\.dismiss) private var dismiss

    private var productName: String {
        products.first { $0.pickId == productId }?.name ?? "Выберите товар"
    }

    /// Максимум задан (не «без ограничения») и меньше минимума.
    private var minMaxInvalid: Bool { maxQty > 0 && minQty > maxQty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { picking = true } label: {
                        HStack {
                            Text("Товар").foregroundColor(Brand.text)
                            Spacer()
                            Text(productName).foregroundColor(Brand.muted)
                        }
                    }
                } footer: {
                    Text("Сервер создаёт группу при товаре, но она попадёт в общую библиотеку — потом её можно прикрепить и к другим товарам.")
                }
                .listRowBackground(Brand.card)

                Section {
                    TextField("Название группы", text: $name)
                    Toggle("Можно выбрать несколько", isOn: $multiple)
                    Toggle("Обязательная группа", isOn: $required)
                    Stepper("Минимум: \(minQty)", value: $minQty, in: 0...20)
                    Stepper(maxQty == 0 ? "Максимум: без ограничения" : "Максимум: \(maxQty)",
                            value: $maxQty, in: 0...20)
                } footer: {
                    // Минимум больше максимума раньше уходил на сервер: группу,
                    // которую клиент не может выбрать правильно, создавали молча.
                    if minMaxInvalid {
                        Text("Минимум не может быть больше максимума").foregroundColor(Brand.red)
                    }
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Новая группа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        guard let pid = productId else { return }
                        Task {
                            let ok = await onCreate(pid, name.trimmingCharacters(in: .whitespaces),
                                                    multiple, required, minQty, maxQty == 0 ? nil : maxQty)
                            if ok { dismiss() }
                        }
                    }
                    .disabled(busy || productId == nil || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || minMaxInvalid)
                }
            }
            .sheet(isPresented: $picking) {
                ComboProductPicker(title: "Товар", products: products) { p in
                    productId = p.pickId
                    picking = false
                }
            }
        }
    }
}

// ── Новый вариант ────────────────────────────────────────────────────────────

private struct ModifierOptionSheet: View {
    let groupName: String
    let busy: Bool
    let onAdd: (String, Decimal) async -> Bool

    @State private var name = ""
    @State private var priceText = "0"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                    TextField("Цена", text: $priceText).keyboardType(.decimalPad)
                } header: {
                    Text(groupName)
                } footer: {
                    // «Добавить» гасла при неверной цене молча — казалось, кнопка сломана.
                    if !priceText.trimmingCharacters(in: .whitespaces).isEmpty && Money.strict(priceText) == nil {
                        Text("Цена — число, например 50 или 49,90").foregroundColor(Brand.red)
                    }
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Вариант")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        // Пустая цена — бесплатная добавка. Иначе — строгий разбор:
                        // «1 500» раньше сохранялось как 1 ₽, мусор — как 0 ₽.
                        let trimmed = priceText.trimmingCharacters(in: .whitespaces)
                        let price = trimmed.isEmpty ? 0 : (Money.strict(trimmed) ?? 0)
                        Task { if await onAdd(name.trimmingCharacters(in: .whitespaces), price) { dismiss() } }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (!priceText.trimmingCharacters(in: .whitespaces).isEmpty
                                  && Money.strict(priceText) == nil))
                }
            }
        }
    }
}
