import SwiftUI

// ============================================================================
//  Настройки склада — GET/PUT /api/seller/warehouse/settings (auto_writeoff)
//  + склады: GET/POST /api/seller/warehouses, DELETE /api/seller/warehouses/{id}.
//  Складские документы (приход/списание/инвентаризация) — в веб-кабинете.
// ============================================================================

@MainActor
final class WarehouseSettingsViewModel: ObservableObject {
    @Published var autoWriteoff = false
    @Published var warehouses: [WarehouseInfo] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var saving = false

    func load() async {
        if warehouses.isEmpty { state = .loading }
        do {
            async let s = API.shared.warehouseSettings()
            async let w = API.shared.warehouses()
            autoWriteoff = try await s.autoWriteoff ?? false
            warehouses = try await w
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func saveAutoWriteoff(_ on: Bool) async {
        error = nil
        saving = true
        defer { saving = false }
        do {
            try await API.shared.saveWarehouseSettings(autoWriteoff: on)
            autoWriteoff = on
        } catch {
            self.error = error.localizedDescription
            autoWriteoff = !on   // откат тумблера
        }
    }

    func addWarehouse(name: String, address: String?, isDefault: Bool) async -> Bool {
        error = nil
        do {
            _ = try await API.shared.createWarehouse(name: name, address: address, isDefault: isDefault)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteWarehouse(_ w: WarehouseInfo) async {
        error = nil
        do {
            try await API.shared.deleteWarehouse(id: w.warehouseId)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct WarehouseSettingsView: View {
    @StateObject private var vm = WarehouseSettingsViewModel()
    @State private var showAdd = false
    /// Паритет с Android: удаление склада — только после вопроса.
    @State private var deleteTarget: WarehouseInfo?

    var body: some View {
        List {
            Section("Списание при продаже") {
                Toggle(isOn: Binding(
                    get: { vm.autoWriteoff },
                    set: { newValue in Task { await vm.saveAutoWriteoff(newValue) } }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Автосписание остатков")
                            .font(.subheadline.weight(.semibold))
                        Text("Остаток товара уменьшается при выполнении заказа")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .tint(Brand.green)
                // Право «Настраивать склады»: без него тумблер щёлкал, сервер
                // отвечал 403, и он молча возвращался назад.
                .disabled(vm.saving || !Session.shared.can("warehouse.settings"))
                if !Session.shared.can("warehouse.settings") {
                    Text("Менять может сотрудник с правом «Настраивать склады» или владелец.")
                        .font(.caption).foregroundColor(Brand.muted)
                }
            }
            .listRowBackground(Brand.card)

            Section("Склады") {
                // У нового магазина складов ещё нет — раздел был пустым без
                // объяснения. Основной склад сервер заводит сам при первом движении.
                if vm.warehouses.isEmpty && vm.state == .loaded {
                    Text("Складов пока нет. «Основной склад» появится сам при первом движении остатков (приход, продажа); вручную добавляют только дополнительные склады.")
                        .font(.caption).foregroundColor(Brand.muted)
                }
                ForEach(vm.warehouses) { w in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(w.name ?? "Склад")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text)
                            if let a = w.address, !a.isEmpty {
                                Text(a).font(.caption).foregroundColor(Brand.muted)
                            }
                        }
                        Spacer()
                        if w.isDefault == true {
                            StatusBadge(text: "основной", color: Brand.green)
                        }
                    }
                    // Без полного свайпа: длинный жест удалял склад без вопроса —
                    // только нажатием кнопки.
                    .swipeActions(allowsFullSwipe: false) {
                        // Удаление склада — то же право, что и создание (иначе 403).
                        if w.isDefault != true && Session.shared.can("warehouse.settings") {
                            Button(role: .destructive) {
                                // Паритет с Android: сначала спрашиваем (там окно
                                // подтверждения), кнопка свайпа удаляла сразу.
                                deleteTarget = w
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
                // Создание складов и авто-списание — право «Настраивать склады»
                // внутри раздела «Остатки и склады».
                if Session.shared.can("warehouse.settings") {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Добавить склад", systemImage: "plus")
                    }
                }
            }
            .listRowBackground(Brand.card)

            Section {
                Link(destination: URL(string: "https://yumurta.ru/seller/documents.php")!) {
                    Label("Складские документы — в веб-кабинете", systemImage: "safari")
                }
            } footer: {
                // Документы склада теперь есть и в приложении («Ещё → Документы склада»,
                // как на Android) — прежний текст отправлял только в кабинет и на кассу.
                Text("Приходы, списания, перемещения и инвентаризации — в разделе «Документы склада», в веб-кабинете и на кассе.")
            }
            .listRowBackground(Brand.card)

            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                    .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Настройки склада")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        // Не загрузилось — показываем ошибку и «Повторить», а не выключенное
        // «Автосписание» и пустой список складов, как будто это правда.
        .listState(vm.state, isEmpty: { if case .failed = vm.state { return true }; return false }(),
                   emptyIcon: "gearshape", emptyTitle: "",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $showAdd) {
            AddWarehouseSheet(vm: vm)
        }
        .confirmationDialog(
            "Удалить склад?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { w in
            Button("Удалить «\(w.name ?? "Склад")»", role: .destructive) {
                deleteTarget = nil
                Task { await vm.deleteWarehouse(w) }
            }
            Button("Отмена", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("Склад пропадёт из выбора в документах, закупках и фильтре остатков.")
        }
        .task { await vm.load() }
    }
}

private struct AddWarehouseSheet: View {
    @ObservedObject var vm: WarehouseSettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var isDefault = false
    @State private var isSubmitting = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Новый склад") {
                    TextField("Название", text: $name)
                    TextField("Адрес (необязательно)", text: $address)
                    Toggle("Сделать основным", isOn: $isDefault).tint(Brand.green)
                }
                if let err = localError {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer(); if isSubmitting { ProgressView() } else { Text("Создать").bold() }; Spacer() }
                    }
                    .disabled(isSubmitting || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Добавить склад")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
        }
    }

    @MainActor private func submit() async {
        guard !isSubmitting else { return }   // двойной тап создавал два склада
        isSubmitting = true
        localError = nil
        let addr = address.trimmingCharacters(in: .whitespaces)
        let ok = await vm.addWarehouse(name: name.trimmingCharacters(in: .whitespaces),
                                       address: addr.isEmpty ? nil : addr,
                                       isDefault: isDefault)
        isSubmitting = false
        if ok { dismiss() } else { localError = vm.error }
    }
}
