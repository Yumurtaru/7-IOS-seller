import SwiftUI

// ============================================================================
//  Категории — создание, переименование, порядок, включение/выключение,
//  удаление. Раздела в приложении не было: товар заводился, но разложить его
//  по категориям можно было только в вебе.
//
//  Удаление категории на сервере НЕ удаляет товары: им проставляется
//  category_id = NULL. Так и предупреждаем — иначе кнопка выглядит страшнее,
//  чем есть.
// ============================================================================

@MainActor
final class CategoriesViewModel: ObservableObject {
    @Published var items: [ProductCategory] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var busy = false

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.catalogCategories()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// sortOrder nil — порядок не задан: сервер ставит категорию в конец уровня.
    func create(name: String, sortOrder: Int?) async -> Bool {
        guard !busy else { return false }   // двойной тап создавал две категории
        busy = true; defer { busy = false }
        do {
            _ = try await API.shared.createCategory(name: name, sortOrder: sortOrder)
            await load()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func rename(_ c: ProductCategory, name: String, sortOrder: Int) async -> Bool {
        guard !busy else { return false }   // двойной тап — один запрос
        busy = true; defer { busy = false }
        do {
            try await API.shared.updateCategory(id: c.categoryId, name: name, sortOrder: sortOrder)
            await load()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func toggle(_ c: ProductCategory) async {
        guard !busy else { return }   // двойной тап по «глазу» переключал туда-обратно
        busy = true; defer { busy = false }
        do {
            try await API.shared.updateCategory(id: c.categoryId, isActive: !(c.isActive ?? true))
            await load()
        } catch { self.error = error.localizedDescription }
    }

    // ── А65: порядок как в витрине ───────────────────────────────────────

    /// Дерево в порядке витрины — как catTreeSort на сервере: внутри уровня
    /// sort_order, name, id; подкатегории сразу за родителем. Плоский список
    /// по sort_order перемешивал уровни.
    var tree: [CategoryTreeRow] {
        let sorted = items.sorted(by: Self.before)
        var ids = Set<Int>()
        for c in sorted { ids.insert(c.categoryId) }
        var kids: [Int: [ProductCategory]] = [:]
        var roots: [ProductCategory] = []
        for c in sorted {
            let pid = c.parentId ?? 0
            if pid > 0 && pid != c.categoryId && ids.contains(pid) {
                kids[pid, default: []].append(c)
            } else {
                roots.append(c)
            }
        }
        var out: [CategoryTreeRow] = []
        var seen = Set<Int>()
        func walk(_ c: ProductCategory, _ depth: Int, _ parentKey: Int, _ hidden: Bool) {
            let cid = c.categoryId
            if seen.contains(cid) || depth > 10 { return }   // защита от петли в parent_id
            seen.insert(cid)
            out.append(CategoryTreeRow(cat: c, depth: depth, parentKey: parentKey, parentHidden: hidden))
            let childHidden = hidden || c.isActive == false
            for k in kids[cid] ?? [] { walk(k, depth + 1, cid, childHidden) }
        }
        // Уровень корня — настоящий parent_id: категория с пропавшим родителем
        // стоит среди корней, но в reorder с ними не уходит (там один уровень).
        for r in roots { walk(r, 0, max(0, r.parentId ?? 0), false) }
        for c in sorted where !seen.contains(c.categoryId) {
            out.append(CategoryTreeRow(cat: c, depth: 0, parentKey: max(0, c.parentId ?? 0), parentHidden: false))
        }
        // Первая/последняя в своём уровне — у них гаснет стрелка ↑ или ↓.
        var lastByKey: [Int: Int] = [:]
        for i in out.indices {
            let key = out[i].parentKey
            if lastByKey[key] == nil { out[i].isFirst = true }
            lastByKey[key] = i
        }
        for (_, i) in lastByKey { out[i].isLast = true }
        return out
    }

    private static func before(_ a: ProductCategory, _ b: ProductCategory) -> Bool {
        let sa = a.sortOrder ?? 0
        let sb = b.sortOrder ?? 0
        if sa != sb { return sa < sb }
        let na = a.name ?? ""
        let nb = b.name ?? ""
        if na != nb { return na < nb }
        return a.categoryId < b.categoryId
    }

    /// Сдвиг на одну позицию среди соседей: POST /api/seller/categories/reorder
    /// с полным порядком этого уровня, затем перечитываем список.
    func move(_ row: CategoryTreeRow, up: Bool) async {
        guard !busy else { return }
        var ids: [Int] = []
        for r in tree where r.parentKey == row.parentKey { ids.append(r.cat.categoryId) }
        guard let i = ids.firstIndex(of: row.cat.categoryId) else { return }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < ids.count else { return }
        ids.swapAt(i, j)
        let order = ids
        busy = true; defer { busy = false }
        do {
            try await API.shared.reorderCategories(ids: order)
        } catch { self.error = error.localizedDescription }
        await load()   // и после ошибки: порядок мог смениться с другого устройства
    }

    func delete(_ c: ProductCategory) async {
        do {
            try await API.shared.deleteCategory(id: c.categoryId)
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

/// Строка дерева категорий: уровень вложенности, родитель (0 — корень) и
/// «скрыта вместе с родительской» — клиенту не видна, даже если включена сама.
struct CategoryTreeRow: Identifiable {
    let cat: ProductCategory
    let depth: Int
    let parentKey: Int
    let parentHidden: Bool
    var isFirst = false
    var isLast = false
    var id: Int { cat.categoryId }
}

struct CategoriesView: View {
    @StateObject private var vm = CategoriesViewModel()
    @State private var editing: ProductCategory?
    @State private var creating = false
    /// паритет с Android: удаление категории — только после вопроса.
    @State private var deleting: ProductCategory?

    var body: some View {
        List {
            // А65: дерево в порядке витрины, стрелки ↑/↓ и «глаз» прямо в строке.
            Section {
                ForEach(vm.tree) { row in
                    categoryRow(row)
                }
            } footer: {
                if !vm.items.isEmpty {
                    Text("Стрелки меняют порядок внутри уровня — в таком порядке категории видят клиенты. Скрытая категория и её подкатегории клиентам не видны.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Категории")
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
                   emptyIcon: "folder", emptyTitle: "Категорий нет",
                   emptySubtitle: "Добавьте категорию, чтобы разложить товары по разделам витрины",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $creating) {
            // паритет с Android: порядок у новой категории по умолчанию не задан — раньше
            // всегда уходил 0, и категория вставала первой, а не в конец (seller_products.php).
            CategoryEditSheet(title: "Новая категория", name: "", sortOrder: nil, busy: vm.busy) { name, sort in
                await vm.create(name: name, sortOrder: sort)
            }
            .errorAlert($vm.error)
        }
        .sheet(item: $editing) { c in
            CategoryEditSheet(title: "Категория", name: c.name ?? "", sortOrder: c.sortOrder ?? 0, busy: vm.busy) { name, sort in
                await vm.rename(c, name: name, sortOrder: sort ?? (c.sortOrder ?? 0))
            }
            .errorAlert($vm.error)
        }
        .alert("Не получилось", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("Понятно", role: .cancel) { vm.error = nil }
        } message: { Text(vm.error ?? "") }
        // паритет с Android: раньше «Удалить» в свайпе удаляло категорию сразу, без вопроса.
        .confirmationDialog(
            "Удалить категорию «\(deleting?.name ?? "")»?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { c in
            Button("Удалить", role: .destructive) {
                deleting = nil
                Task { await vm.delete(c) }
            }
            Button("Отмена", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("Товары останутся в каталоге — они просто окажутся без категории.")
        }
    }

    private func categoryRow(_ row: CategoryTreeRow) -> some View {
        let c = row.cat
        let dim = c.isActive == false || row.parentHidden
        return HStack(spacing: 10) {
            HStack(spacing: 12) {
                RemoteImage(path: c.image, size: 40, cornerRadius: 8, placeholderIcon: "folder")
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.name ?? "—").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                    Text("порядок: \(c.sortOrder ?? 0)").font(.caption2).foregroundColor(Brand.muted)
                    // Выключенная — бледная и с подписью; её подкатегории
                    // клиенту тоже не видны, даже если включены сами.
                    if c.isActive == false {
                        Text("скрыта от клиентов").font(.caption2.weight(.semibold)).foregroundColor(Brand.amber)
                    } else if row.parentHidden {
                        Text("скрыта вместе с родительской").font(.caption2.weight(.semibold)).foregroundColor(Brand.amber)
                    }
                }
            }
            .opacity(dim ? 0.55 : 1)
            // Тап по названию — правка. Не на всей строке: нажатие на
            // выключенную стрелку (первая/последняя) «проваливалось» в строку
            // и открывало правку.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { editing = c }
            Button {
                Task { await vm.toggle(c) }
            } label: {
                Image(systemName: c.isActive == false ? "eye.slash" : "eye")
                    .frame(width: 32, height: 32)
            }
            .tint(c.isActive == false ? Brand.muted : Brand.green)
            .disabled(vm.busy)
            if !(row.isFirst && row.isLast) {
                moveButtons(row)
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading, CGFloat(row.depth) * 18)
        // Без полного свайпа: длинный жест сразу удалял категорию, и все её
        // товары оставались без раздела — только кнопкой.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deleting = c
            } label: { Label("Удалить", systemImage: "trash") }
            Button {
                Task { await vm.toggle(c) }
            } label: {
                Label(c.isActive == false ? "Показать" : "Скрыть",
                      systemImage: c.isActive == false ? "eye" : "eye.slash")
            }
            .tint(Brand.amber)
        }
        .listRowBackground(Brand.card)
    }

    /// Сдвиг на одну позицию среди соседей того же уровня.
    private func moveButtons(_ row: CategoryTreeRow) -> some View {
        VStack(spacing: 2) {
            Button {
                Task { await vm.move(row, up: true) }
            } label: {
                Image(systemName: "chevron.up").frame(width: 32, height: 22)
            }
            .disabled(row.isFirst || vm.busy)
            Button {
                Task { await vm.move(row, up: false) }
            } label: {
                Image(systemName: "chevron.down").frame(width: 32, height: 22)
            }
            .disabled(row.isLast || vm.busy)
        }
        .tint(Brand.accent)
    }
}

private struct CategoryEditSheet: View {
    let title: String
    @State var name: String
    @State var sortOrder: Int?
    let busy: Bool
    let onSave: (String, Int?) async -> Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name)
                    Stepper(sortOrder.map { "Порядок: \($0)" } ?? "Порядок: в конце",
                            value: Binding(get: { sortOrder ?? 0 }, set: { sortOrder = $0 }),
                            in: 0...999)
                } footer: {
                    Text("Порядок задаёт место категории в витрине: чем меньше число, тем выше."
                         + (sortOrder == nil ? " Не задан — встанет после расставленных категорий." : ""))
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task { if await onSave(name.trimmingCharacters(in: .whitespaces), sortOrder) { dismiss() } }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
