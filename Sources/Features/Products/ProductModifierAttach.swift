import SwiftUI

// ============================================================================
//  Группы добавок товара: привязать готовую группу магазина и отвязать группу
//  от ЭТОГО товара.
//    POST   /api/seller/products/{id}/modifier-groups/{gid}/attach  → {attached:true}
//    DELETE /api/seller/products/{id}/modifier-groups/{gid}/detach  → {detached:true}
//  Отвязка не трогает саму группу — она остаётся у других товаров (в отличие
//  от DELETE /modifier-groups/{id} в разделе «Модификаторы»).
//  403 (чужая группа / нет права «Менять цены») — показываем текст сервера.
// ============================================================================

extension ProductEditViewModel {
    private func reloadProductModifiers(_ id: Int) async {
        if let fresh = try? await API.shared.productModifiers(productId: id) { modifierGroups = fresh }
    }

    func attachModifierGroup(_ g: ModifierGroup) async -> Bool {
        guard let id = productId, !modBusy else { return false }
        modBusy = true; defer { modBusy = false }
        modNotice = nil
        do {
            try await API.shared.attachModifierGroup(productId: id, groupId: g.groupId)
            await reloadProductModifiers(id)
            modNotice = "Группа «\(g.name ?? "Группа")» добавлена к товару"
            return true
        } catch is CancellationError {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func detachModifierGroup(_ g: ModifierGroup) async {
        guard let id = productId, !modBusy else { return }
        modBusy = true; defer { modBusy = false }
        modNotice = nil
        do {
            try await API.shared.detachModifierGroup(productId: id, groupId: g.groupId)
            await reloadProductModifiers(id)
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// «Отвязать от товара» под каждой привязанной группой.
struct ProductModifierDetachButton: View {
    @ObservedObject var vm: ProductEditViewModel
    let group: ModifierGroup
    @State private var confirm = false

    var body: some View {
        Button(role: .destructive) { confirm = true } label: {
            Text("Отвязать от товара").font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(vm.modBusy)
        .confirmationDialog(
            "Убрать группу «\(group.name ?? "Группа")» из этого товара? Сама группа останется и у других товаров",
            isPresented: $confirm,
            titleVisibility: .visible
        ) {
            Button("Отвязать от товара", role: .destructive) {
                Task { await vm.detachModifierGroup(group) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }
}

/// «Добавить готовую группу» + лист выбора (свой .sheet — не мешает листам карточки).
struct ProductModifierAttachButton: View {
    @ObservedObject var vm: ProductEditViewModel
    @State private var showSheet = false

    var body: some View {
        Button { showSheet = true } label: {
            Label("Добавить готовую группу", systemImage: "plus.circle").font(.subheadline)
        }
        .disabled(vm.modBusy)
        .sheet(isPresented: $showSheet) {
            ProductModifierAttachSheet(vm: vm)
        }
    }
}

private struct ProductModifierAttachSheet: View {
    @ObservedObject var vm: ProductEditViewModel
    @State private var all: [ModifierGroup] = []
    @State private var state: LoadState = .idle
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    /// Группы магазина кроме уже привязанных к товару.
    private var available: [ModifierGroup] {
        let taken = Set(vm.modifierGroups.map { $0.groupId })
        return all.filter { !taken.contains($0.groupId) }
    }

    private var shown: [ModifierGroup] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return available }
        return available.filter { ($0.name ?? "").lowercased().contains(q) }
    }

    private func load() async {
        if all.isEmpty { state = .loading }
        do {
            all = try await API.shared.modifierGroups()
            state = .loaded
        } catch is CancellationError {
            if state == .loading { state = .idle }   // отмена: спиннер не должен висеть
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func rule(_ g: ModifierGroup) -> String {
        var s = g.isMultiple ? "несколько" : "один из"
        if g.isRequired == true { s += ", обязательная" }
        return s
    }

    var body: some View {
        NavigationStack {
            list
                .navigationTitle("Готовая группа")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                }
                .errorAlert($vm.error)
        }
    }

    @ViewBuilder
    private var list: some View {
        if available.count > 10 {
            baseList.searchable(text: $query)
        } else {
            baseList
        }
    }

    private var baseList: some View {
        List {
            ForEach(shown) { g in
                Button {
                    Task { if await vm.attachModifierGroup(g) { dismiss() } }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name ?? "Группа").font(.subheadline).foregroundColor(Brand.text)
                            Text(rule(g)).font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        Text("добавок: \((g.options ?? []).count)").font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .disabled(vm.modBusy)
                .listRowBackground(Brand.card)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .task { if state != .loaded { await load() } }
        .listState(state, isEmpty: state == .loaded && available.isEmpty,
                   emptyIcon: "slider.horizontal.3", emptyTitle: "Других групп нет — создайте новую",
                   retry: { Task { await load() } })
    }
}
