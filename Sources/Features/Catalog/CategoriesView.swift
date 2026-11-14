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
            if state == .loading { state = .idle }   // отмена: спиннер не должен висеть
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// sortOrder nil — порядок не задан: сервер ставит категорию в конец уровня.
    /// Возвращает nil при успехе, иначе текст ошибки сервера (показывается в форме,
    /// у поля «Родительская категория»; 422 по parent_id приходит текстом сервера).
    func create(name: String, sortOrder: Int?, parentId: Int) async -> String? {
        guard !busy else { return "" }   // двойной тап создавал две категории
        busy = true; defer { busy = false }
        do {
            _ = try await API.shared.createCategory(name: name, parentId: parentId > 0 ? parentId : nil,
                                                    sortOrder: sortOrder)
            await load()
            return nil
        } catch { return error.localizedDescription }
    }

    /// parent: nil — не менялся (ключ не уходит); 0 — «Нет» (JSON null); >0 — id родителя.
    func rename(_ c: ProductCategory, name: String, sortOrder: Int, parent: Int?) async -> String? {
        guard !busy else { return "" }   // двойной тап — один запрос
        busy = true; defer { busy = false }
        do {
            try await API.shared.updateCategory(id: c.categoryId, name: name, sortOrder: sortOrder,
                                                setParent: parent != nil, parentId: (parent ?? 0) > 0 ? parent : nil)
            await load()
            return nil
        } catch { return error.localizedDescription }
    }

    /// Категории верхнего уровня (кроме самой редактируемой) — варианты родителя.
    func parentOptions(excluding id: Int) -> [ProductCategory] {
        items.filter { ($0.parentId ?? 0) <= 0 && $0.categoryId != id }.sorted(by: Self.before)
    }

    func hasChildren(_ id: Int) -> Bool {
        id > 0 && items.contains { ($0.parentId ?? 0) == id }
    }

    func childCount(_ id: Int) -> Int {
        items.filter { ($0.parentId ?? 0) == id }.count
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
        guard !busy else { return }   // второе «Удалить» после успешного давало ошибку «не найдена»
        busy = true; defer { busy = false }
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

enum CategorySheet: Identifiable {
    case create(parent: Int)
    case edit(ProductCategory)
    case cover(ProductCategory)

    var id: String {
        switch self {
        case .create(let p): return "create-\(p)"
        case .edit(let c): return "edit-\(c.categoryId)"
        case .cover(let c): return "cover-\(c.categoryId)"
        }
    }
}

struct CategoriesView: View {
    @StateObject private var vm = CategoriesViewModel()
    /// Один .sheet(item:) на экран: два .sheet на одной вью не работают.
    @State private var sheet: CategorySheet?
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
                Button { sheet = .create(parent: 0) } label: { Image(systemName: "plus") }
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
        .sheet(item: $sheet) { sh in
            switch sh {
            case .create(let parent):
                CategoryEditSheet(title: parent > 0 ? "Новая подкатегория" : "Новая категория",
                                  name: "", sortOrder: nil, initialParent: parent,
                                  parentOptions: vm.parentOptions(excluding: 0), hasChildren: false,
                                  busy: vm.busy) { name, sort, par in
                    // паритет с Android: порядок у новой категории по умолчанию не задан.
                    await vm.create(name: name, sortOrder: sort, parentId: par ?? parent)
                }
            case .edit(let c):
                CategoryEditSheet(title: "Категория", name: c.name ?? "", sortOrder: c.sortOrder ?? 0,
                                  initialParent: max(0, c.parentId ?? 0),
                                  parentOptions: vm.parentOptions(excluding: c.categoryId),
                                  hasChildren: vm.hasChildren(c.categoryId), busy: vm.busy) { name, sort, par in
                    await vm.rename(c, name: name, sortOrder: sort ?? (c.sortOrder ?? 0), parent: par)
                }
            case .cover(let c):
                CategoryCoverSheet(category: c) { Task { await vm.load() } }
            }
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
        } message: { c in
            Text("Товары останутся в каталоге — они просто окажутся без категории."
                 + (vm.childCount(c.categoryId) > 0 ? " Подкатегории станут категориями верхнего уровня." : ""))
        }
    }

    private func categoryRow(_ row: CategoryTreeRow) -> some View {
        let c = row.cat
        let dim = c.isActive == false || row.parentHidden
        return HStack(spacing: 10) {
            // Касание по миниатюре — обложка категории (камера, галерея, убрать).
            Button { sheet = .cover(c) } label: {
                RemoteImage(path: c.image, size: 40, cornerRadius: 8, placeholderIcon: "folder")
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white, Brand.accent)
                            .offset(x: 4, y: 4)
                    }
            }
            .opacity(dim ? 0.55 : 1)
            .accessibilityLabel("Обложка категории")
            HStack(spacing: 12) {
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
            .onTapGesture { sheet = .edit(c) }
            if row.depth == 0 {
                Button { sheet = .create(parent: c.categoryId) } label: {
                    Image(systemName: "folder.badge.plus").frame(width: 32, height: 32)
                }
                .tint(Brand.accent)
                .disabled(vm.busy)
                .accessibilityLabel("Добавить подкатегорию")
            }
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
            Button { sheet = .cover(c) } label: { Label("Обложка", systemImage: "photo") }
                .tint(Brand.accent)
            if row.depth == 0 {
                Button { sheet = .create(parent: c.categoryId) } label: {
                    Label("Подкатегория", systemImage: "folder.badge.plus")
                }
                .tint(Brand.green)
            }
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
    let initialParent: Int
    let parentOptions: [ProductCategory]
    let hasChildren: Bool
    let busy: Bool
    /// (название, порядок, родитель). Родитель: nil — не менялся; 0 — «Нет»; >0 — id.
    /// Возвращает nil при успехе или текст ошибки сервера.
    let onSave: (String, Int?, Int?) async -> String?

    @State private var parentId: Int
    @State private var fieldError: String?
    @Environment(\.dismiss) private var dismiss

    init(title: String, name: String, sortOrder: Int?, initialParent: Int,
         parentOptions: [ProductCategory], hasChildren: Bool, busy: Bool,
         onSave: @escaping (String, Int?, Int?) async -> String?) {
        self.title = title
        _name = State(initialValue: name)
        _sortOrder = State(initialValue: sortOrder)
        self.initialParent = initialParent
        self.parentOptions = parentOptions
        self.hasChildren = hasChildren
        self.busy = busy
        self.onSave = onSave
        _parentId = State(initialValue: initialParent)
    }

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
                Section {
                    Picker("Родительская категория", selection: $parentId) {
                        Text("Нет (верхний уровень)").tag(0)
                        ForEach(parentOptions) { p in
                            Text(p.name ?? "—").tag(p.categoryId)
                        }
                    }
                    .disabled(hasChildren)
                } footer: {
                    if let e = fieldError, !e.isEmpty {
                        Text(e).foregroundColor(.red)
                    } else if hasChildren {
                        Text("У категории есть подкатегории — она может быть только верхнего уровня")
                    }
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
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        let sort = sortOrder
                        // parent_id уходит, только если изменился.
                        let par: Int? = parentId == initialParent ? nil : parentId
                        Task {
                            fieldError = nil
                            let err = await onSave(trimmed, sort, par)
                            if let err { fieldError = err } else { dismiss() }
                        }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
