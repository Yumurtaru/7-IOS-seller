import SwiftUI

// ============================================================================
//  Тех. карты — из чего и в каком количестве готовится блюдо. Раздела не было.
//
//  Карта привязывается не только к товару, но и к модификатору (добавка тоже
//  расходует сырьё) — сервер различает их параметром type: product|modifier.
//
//  Брутто — сколько взяли со склада, нетто — сколько осталось в блюде после
//  очистки и потерь. Списывается брутто, себестоимость считается по нему же.
// ============================================================================

@MainActor
final class TechCardsViewModel: ObservableObject {
    @Published var products: [ComboPickProduct] = []
    @Published var modifiers: [TCModifier] = []
    @Published var state: LoadState = .idle

    func load() async {
        if products.isEmpty && modifiers.isEmpty { state = .loading }
        do {
            async let p = API.shared.comboPickProducts()
            async let m = API.shared.tcModifiers()
            products = try await p
            modifiers = try await m
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct TechCardsView: View {
    @StateObject private var vm = TechCardsViewModel()
    @State private var tab = 0
    @State private var open: TechCardTarget?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Блюда").tag(0)
                Text("Модификаторы").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)

            List {
                if tab == 0 {
                    ForEach(filteredProducts) { p in
                        Button {
                            open = TechCardTarget(type: "product", entityId: p.pickId, title: p.name ?? "Блюдо")
                        } label: {
                            HStack {
                                Text(p.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                                Spacer()
                                Text(Money.rub(p.price)).font(.caption).foregroundColor(Brand.muted)
                            }
                        }
                        .listRowBackground(Brand.card)
                    }
                } else {
                    ForEach(filteredModifiers) { m in
                        Button {
                            open = TechCardTarget(type: "modifier", entityId: m.id, title: m.name ?? "Модификатор")
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                                    Text([m.productName, m.groupName].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2).foregroundColor(Brand.muted)
                                }
                                Spacer()
                                if m.hasCard { StatusBadge(text: "есть карта", color: Brand.green) }
                            }
                        }
                        .listRowBackground(Brand.card)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $query, prompt: "Поиск")
            .refreshable { await vm.load() }
            // Голое «Список пуст» у нового кафе не объясняло, откуда берутся
            // блюда; поиск без совпадений давал просто белый экран.
            .listState(vm.state, isEmpty: tab == 0 ? filteredProducts.isEmpty : filteredModifiers.isEmpty,
                       emptyIcon: "doc.plaintext", emptyTitle: emptyTitle, emptySubtitle: emptySubtitle,
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Тех. карты")
        .navigationBarTitleDisplayMode(.inline)
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.load() } }
        .sheet(item: $open) { target in
            NavigationStack { TechCardEditView(target: target) }
        }
    }

    private var emptyTitle: String {
        if !query.isEmpty { return "Ничего не найдено" }
        return tab == 0 ? "Блюд пока нет" : "Модификаторов пока нет"
    }

    private var emptySubtitle: String? {
        if !query.isEmpty { return nil }
        return tab == 0
            ? "Тех. карта привязывается к блюду. Сначала добавьте блюда во вкладке «Меню»."
            : "Добавки и соусы заводятся в «Ещё → Модификаторы» — потом им можно задать расход сырья."
    }

    private var filteredProducts: [ComboPickProduct] {
        guard !query.isEmpty else { return vm.products }
        return vm.products.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }

    private var filteredModifiers: [TCModifier] {
        guard !query.isEmpty else { return vm.modifiers }
        return vm.modifiers.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }
}

struct TechCardTarget: Identifiable {
    let type: String        // product | modifier
    let entityId: Int
    let title: String
    var id: String { "\(type)-\(entityId)" }
}

// ── Редактор карты ───────────────────────────────────────────────────────────

@MainActor
final class TechCardEditViewModel: ObservableObject {
    @Published var items: [TechCardDraft] = []
    @Published var ingredients: [Ingredient] = []
    @Published var yieldWeight = ""
    @Published var portions = ""
    @Published var cookingTime = ""
    @Published var process = ""
    /// Описание карты из кабинета сайта. В приложении не правится, но сервер
    /// стирает его, если не прислать при сохранении, — храним и отдаём обратно.
    private var cardDescription: String?
    @Published var state: LoadState = .idle
    @Published var saving = false
    @Published var error: String?

    /// Себестоимость по брутто — считаем на клиенте, чтобы было видно сразу.
    var cost: Decimal {
        items.reduce(0) { sum, item in
            let price = ingredients.first { $0.ingredientId == item.ingredientId }?.pricePerUnit ?? 0
            return sum + item.qtyGross * price
        }
    }

    func load(target: TechCardTarget) async {
        state = .loading
        do {
            async let card = API.shared.techCard(type: target.type, entityId: target.entityId)
            async let ing = API.shared.ingredients()
            let res = try await card
            ingredients = try await ing
            yieldWeight = res.techCard?.yieldWeight.map { "\($0)" } ?? ""
            portions = res.techCard?.portions.map(String.init) ?? ""
            cookingTime = res.techCard?.cookingTimeMin.map(String.init) ?? ""
            process = res.techCard?.process ?? ""
            cardDescription = res.techCard?.description
            items = (res.items ?? []).map {
                TechCardDraft(ingredientId: $0.ingredientId ?? 0,
                              name: $0.name ?? "—",
                              unit: $0.unit ?? "",
                              qtyGross: $0.qtyGross ?? 0,
                              qtyNet: $0.qtyNet ?? 0)
            }
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func add(_ ing: Ingredient) {
        guard !items.contains(where: { $0.ingredientId == ing.ingredientId }) else { return }
        items.append(TechCardDraft(ingredientId: ing.ingredientId, name: ing.name ?? "—",
                                   unit: ing.unit ?? "", qtyGross: 0, qtyNet: 0))
    }

    func save(target: TechCardTarget) async -> Bool {
        guard !saving else { return false }   // двойной тап — один запрос
        // Карта не загрузилась (или ещё грузится) — форма пустая. Сохранение
        // отправило бы пустой состав и стёрло бы настоящую тех. карту.
        guard state == .loaded else {
            error = "Тех. карта ещё не загружена — сохранить нельзя"
            return false
        }
        // Паритет с Android и сервером: строку выбрасывают, только если и брутто, и
        // нетто ≤ 0 (seller_warehouse.php); списание идёт по брутто, а при нуле — по
        // нетто (helpers.php), поэтому строка только с нетто — законная.
        if let z = items.first(where: { $0.qtyGross <= 0 && $0.qtyNet <= 0 }) {
            error = "Укажите брутто у «\(z.name)» или уберите строку — с нулём она не сохранится"
            return false
        }
        // Выход «250,5» раньше уходил с запятой (сервер читал 250), «4 » порции — пропадали.
        let yw = yieldWeight.trimmingCharacters(in: .whitespaces)
        let p = portions.filter { !$0.isWhitespace }, ct = cookingTime.filter { !$0.isWhitespace }
        guard yw.isEmpty || Money.strict(yw, maxFraction: 3) != nil else { error = "Выход — число, например 250 или 0,5"; return false }
        guard p.isEmpty || Int(p) != nil else { error = "Порций — целое число"; return false }
        guard ct.isEmpty || Int(ct) != nil else { error = "Время — целое число минут"; return false }
        saving = true; defer { saving = false }
        do {
            try await API.shared.saveTechCard(
                type: target.type, entityId: target.entityId,
                yieldWeight: Money.strict(yw, maxFraction: 3).map { "\($0)" }, portions: Int(p),
                cookingTimeMin: Int(ct), process: process, description: cardDescription, items: items
            )
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct TechCardEditView: View {
    let target: TechCardTarget
    @StateObject private var vm = TechCardEditViewModel()
    @State private var picking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Состав") {
                ForEach($vm.items) { $item in
                    VStack(alignment: .leading, spacing: 6) {
                        // Без единицы строка кончалась висящей запятой: «Мука, ».
                        Text(joinedNonEmpty([item.name, item.unit], separator: ", "))
                            .font(.subheadline).foregroundColor(Brand.text)
                        HStack(spacing: 8) {
                            numberField("Брутто", value: $item.qtyGross)
                            numberField("Нетто", value: $item.qtyNet)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    // Как в документах склада: строка ForEach($…) с полем в фокусе,
                    // удалённая в том же кадре, роняла SwiftUI (Index out of range).
                    // Сначала снимаем фокус, удаляем по id в следующем кадре.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    let ids = Set(offsets.map { vm.items[$0].id })
                    DispatchQueue.main.async { vm.items.removeAll { ids.contains($0.id) } }
                }

                Button { picking = true } label: {
                    Label("Добавить ингредиент", systemImage: "plus.circle")
                }
            }
            .listRowBackground(Brand.card)

            Section("Выход и приготовление") {
                TextField("Выход, г", text: $vm.yieldWeight)
                TextField("Порций", text: $vm.portions).keyboardType(.numberPad)
                TextField("Время, мин", text: $vm.cookingTime).keyboardType(.numberPad)
                TextField("Технология", text: $vm.process, axis: .vertical)
            }
            .listRowBackground(Brand.card)

            Section {
                // Считаем по брутто: со склада уходит именно оно.
                InfoRow(label: "Себестоимость", value: Money.rub(vm.cost))
            } footer: {
                Text("Брутто — сколько взяли со склада, нетто — сколько осталось в блюде после очистки. Списывается брутто.")
            }
            .listRowBackground(Brand.card)
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(target.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") {
                    Task { if await vm.save(target: target) { dismiss() } }
                }
                .disabled(vm.saving || vm.state != .loaded)
            }
        }
        // Загрузка и её ошибка видны: раньше при сбое сети открывалась пустая
        // форма без слова об ошибке, и «Сохранить» затирало карту пустым составом.
        .overlay {
            if case .failed(let msg) = vm.state {
                ErrorBanner(message: msg) { Task { await vm.load(target: target) } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Brand.bg)
            } else if vm.state == .loading {
                ProgressView().controlSize(.large)
            }
        }
        .task { await vm.load(target: target) }
        // Карта открыта листом: случайный свайп вниз закрывал её и стирал
        // набранный состав и граммовки. Есть строки — закрыть только «Закрыть».
        .interactiveDismissDisabled(!vm.items.isEmpty || vm.saving)
        .sheet(isPresented: $picking) {
            IngredientPickerSheet(ingredients: vm.ingredients) { ing in
                vm.add(ing)
                picking = false
            }
        }
        .alert("Не получилось", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("Понятно", role: .cancel) { vm.error = nil }
        } message: { Text(vm.error ?? "") }
    }

    /// Своё поле с текстом (DecimalInputField): раньше «1,5» кг превращалось
    /// в 15 — запятая пропадала при каждом нажатии.
    private func numberField(_ title: String, value: Binding<Decimal>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(Brand.muted)
            DecimalInputField(title: title, value: value)
        }
    }
}

private struct IngredientPickerSheet: View {
    let ingredients: [Ingredient]
    let onPick: (Ingredient) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    private var filtered: [Ingredient] {
        guard !query.isEmpty else { return ingredients }
        return ingredients.filter { ($0.name ?? "").localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { i in
                Button { onPick(i); dismiss() } label: {
                    HStack {
                        Text(i.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                        Spacer()
                        Text(i.unit ?? "").font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .listRowBackground(Brand.card)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Поиск ингредиента")
            // Без ингредиентов лист был пустым и «Добавить ингредиент» казался сломанным.
            .overlay {
                if filtered.isEmpty {
                    EmptyState(icon: "leaf",
                               title: query.isEmpty ? "Ингредиентов нет" : "Ничего не найдено",
                               subtitle: query.isEmpty ? "Заведите их в разделе «Ещё → Ингредиенты»" : nil)
                }
            }
            .navigationTitle("Ингредиент")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }
}
