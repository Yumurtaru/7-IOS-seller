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
    func create(name: String, sortOrder: Int?, parentId: Int, wholesale: [String: Any]? = nil) async -> String? {
        guard !busy else { return "" }   // двойной тап создавал две категории
        busy = true; defer { busy = false }
        do {
            _ = try await API.shared.createCategory(name: name, parentId: parentId > 0 ? parentId : nil,
                                                    sortOrder: sortOrder, wholesale: wholesale)
            await load()
            return nil
        } catch { return error.localizedDescription }
    }

    /// parent: nil — не менялся (ключ не уходит); 0 — «Нет» (JSON null); >0 — id родителя.
    func rename(_ c: ProductCategory, name: String, sortOrder: Int, parent: Int?,
                wholesale: [String: Any]? = nil) async -> String? {
        guard !busy else { return "" }   // двойной тап — один запрос
        busy = true; defer { busy = false }
        do {
            try await API.shared.updateCategory(id: c.categoryId, name: name, sortOrder: sortOrder,
                                                setParent: parent != nil, parentId: (parent ?? 0) > 0 ? parent : nil,
                                                wholesale: wholesale)
            await load()
            return nil
        } catch { return error.localizedDescription }
    }

    /// А1331: сервер знает про опт категорий (прислал wholesale хотя бы у одной) — в форме новой категории секция есть.
    var serverHasWholesale: Bool { items.contains { $0.wholesale != nil } }

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

    /// А1331: правило опта меняет только сотрудник с правом «Цены» (иначе сервер отвечает 403).
    private var canEditWholesale: Bool { Session.shared.can("products.price") }

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
                                  busy: vm.busy,
                                  wholesale: vm.serverHasWholesale ? CategoryWholesale(mode: "inherit", tiers: []) : nil,
                                  canPrice: canEditWholesale) { name, sort, par, ws in
                    // паритет с Android: порядок у новой категории по умолчанию не задан.
                    await vm.create(name: name, sortOrder: sort, parentId: par ?? parent, wholesale: ws)
                }
            case .edit(let c):
                CategoryEditSheet(title: "Категория", name: c.name ?? "", sortOrder: c.sortOrder ?? 0,
                                  initialParent: max(0, c.parentId ?? 0),
                                  parentOptions: vm.parentOptions(excluding: c.categoryId),
                                  hasChildren: vm.hasChildren(c.categoryId), busy: vm.busy,
                                  wholesale: c.wholesale, canPrice: canEditWholesale) { name, sort, par, ws in
                    await vm.rename(c, name: name, sortOrder: sort ?? (c.sortOrder ?? 0), parent: par, wholesale: ws)
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
                    if let wl = CategoryWholesaleLogic.badge(c.wholesale) {
                        Text(verbatim: wl).font(.caption2.weight(.semibold))
                            .foregroundColor(c.wholesale?.mode == "rule" ? Brand.green : Brand.muted)
                    }
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
    /// Четвёртый аргумент — ключ wholesale (А1331): nil, если секцию не меняли.
    let onSave: (String, Int?, Int?, [String: Any]?) async -> String?
    /// А1331: опт категории от сервера (nil — старый сервер: секцию не показываем) и право «Цены».
    let wholesale: CategoryWholesale?
    let canPrice: Bool
    private let initialWsMode: String
    private let initialWsKeys: [String]
    private let initialWsStep: Int
    private let initialWsRMode: String
    /// Сервер прислал rounding — при сохранении правила шлём его всегда (не сбрасываем).
    private let serverSentRounding: Bool

    @State private var parentId: Int
    @State private var fieldError: String?
    @State private var wsMode: String
    @State private var wsRows: [CategoryWholesaleLogic.Row]
    @State private var wsStep: Int
    @State private var wsRMode: String
    @State private var wsProbe = ""
    @Environment(\.dismiss) private var dismiss

    init(title: String, name: String, sortOrder: Int?, initialParent: Int,
         parentOptions: [ProductCategory], hasChildren: Bool, busy: Bool,
         wholesale: CategoryWholesale?, canPrice: Bool,
         onSave: @escaping (String, Int?, Int?, [String: Any]?) async -> String?) {
        self.title = title
        _name = State(initialValue: name)
        _sortOrder = State(initialValue: sortOrder)
        self.initialParent = initialParent
        self.parentOptions = parentOptions
        self.hasChildren = hasChildren
        self.busy = busy
        self.onSave = onSave
        _parentId = State(initialValue: initialParent)
        self.wholesale = wholesale
        self.canPrice = canPrice
        let m = CategoryWholesaleLogic.mode(from: wholesale)
        let r = CategoryWholesaleLogic.rows(from: wholesale)
        initialWsMode = m
        initialWsKeys = r.map { $0.key }
        _wsMode = State(initialValue: m)
        _wsRows = State(initialValue: r)
        let st = CategoryWholesaleLogic.stepCents(wholesale?.rounding)
        let rm = CategoryWholesaleLogic.roundMode(wholesale?.rounding)
        initialWsStep = st
        initialWsRMode = rm
        serverSentRounding = wholesale?.rounding != nil
        _wsStep = State(initialValue: st)
        _wsRMode = State(initialValue: rm)
    }

    // ── А1331: опт категории ────────────────────────────────────────────────
    /// Секция видна, если сервер знает опт категории; без права «Цены» — только для чтения (как в кабинете и Android).
    private var showWholesale: Bool { wholesale != nil }

    /// Поле ступени по id строки: ForEach($wsRows) с удалением внутри падал на iOS 15–16 («Index out of range»).
    private func wsBinding(_ id: UUID, _ kp: WritableKeyPath<CategoryWholesaleLogic.Row, String>) -> Binding<String> {
        Binding(
            get: { wsRows.first(where: { $0.id == id })?[keyPath: kp] ?? "" },
            set: { v in
                if let i = wsRows.firstIndex(where: { $0.id == id }) { wsRows[i][keyPath: kp] = v }
            }
        )
    }

    private var wsChanged: Bool {
        if wsMode != initialWsMode { return true }
        guard wsMode == CategoryWholesaleLogic.modeRule else { return false }
        return wsRows.map { $0.key } != initialWsKeys || wsRoundingChanged
    }

    private var wsRoundingChanged: Bool {
        wsStep != initialWsStep || (wsStep > 1 && wsRMode != initialWsRMode)
    }

    /// Шаг: смена с «до копеек» на больший сразу ставит способ по умолчанию «вниз» (как в кабинете).
    private var wsStepBinding: Binding<Int> {
        Binding(
            get: { wsStep },
            set: { v in
                if wsStep == 1 && v > 1 { wsRMode = CategoryWholesaleLogic.modeDown }
                wsStep = v
            }
        )
    }

    /// Округление в запросе: шлём, если правило уже было с rounding или его меняли.
    private var wsRoundingPayload: (cents: Int, mode: String)? {
        guard serverSentRounding || wsRoundingChanged else { return nil }
        return (wsStep, wsStep > 1 ? wsRMode : CategoryWholesaleLogic.modeNearest)
    }

    /// Строки «Проверить на цене» (пусто — цена не введена или ступени не разобрались).
    private var wsProbeLines: [String] {
        guard let r = Money.strict(wsProbe), r > 0 else { return [] }
        return CategoryWholesaleLogic.probeLines(rows: wsRows, retail: r, stepCents: wsStep,
                                                 mode: wsStep > 1 ? wsRMode : CategoryWholesaleLogic.modeNearest)
    }

    /// А1432: округление цены ступени и пример на цене.
    @ViewBuilder
    private var wsRoundingControls: some View {
        Picker("Округлять цену", selection: wsStepBinding) {
            ForEach(0..<CategoryWholesaleLogic.stepOptions.count, id: \.self) { i in
                Text(CategoryWholesaleLogic.stepOptions[i].title).tag(CategoryWholesaleLogic.stepOptions[i].cents)
            }
        }
        if wsStep > 1 {
            Picker("Способ округления", selection: $wsRMode) {
                ForEach(0..<CategoryWholesaleLogic.roundModeOptions.count, id: \.self) { i in
                    Text(CategoryWholesaleLogic.roundModeOptions[i].title).tag(CategoryWholesaleLogic.roundModeOptions[i].mode)
                }
            }
        }
        TextField("Проверить на цене, ₽", text: $wsProbe).keyboardType(.decimalPad)
        ForEach(wsProbeLines, id: \.self) { line in
            Text(verbatim: line).font(.footnote).foregroundColor(Brand.muted)
        }
    }

    /// Ошибка ступеней — только когда выбран режим «Скидка от количества».
    private var wsError: String? {
        wsMode == CategoryWholesaleLogic.modeRule ? CategoryWholesaleLogic.validate(rows: wsRows) : nil
    }

    private var isSub: Bool { parentId > 0 }

    private var wsFooterText: String {
        if wsMode == CategoryWholesaleLogic.modeOff {
            return "У товаров этой подкатегории опта не будет (кроме своих оптовых цен в карточке товара)."
        }
        if wsMode == CategoryWholesaleLogic.modeRule {
            return "Цена ступени = цена товара минус скидка. Для товаров со своими оптовыми ценами действуют их цены. Штучным товарам порог округляется вверх до целого."
        }
        return isSub ? "Действует скидка родительской категории (если она задана)."
                     : "Опта нет. Свои оптовые цены можно задать в карточке товара."
    }

    private var wholesaleSection: some View {
        Section {
            Picker("Оптовая скидка", selection: $wsMode) {
                Text(isSub ? "Как у родительской категории" : "Нет опта").tag(CategoryWholesaleLogic.modeInherit)
                Text("Скидка от количества").tag(CategoryWholesaleLogic.modeRule)
                if isSub { Text("Без опта (даже если у родительской есть)").tag(CategoryWholesaleLogic.modeOff) }
            }
            .disabled(!canPrice)
            if wsMode == CategoryWholesaleLogic.modeRule {
                ForEach(wsRows) { row in
                    HStack(spacing: 6) {
                        Text("от")
                        TextField("10", text: wsBinding(row.id, \.qty)).keyboardType(.decimalPad)
                            .multilineTextAlignment(.center).frame(width: 64)
                        Text("— скидка")
                        TextField("5", text: wsBinding(row.id, \.pct)).keyboardType(.decimalPad)
                            .multilineTextAlignment(.center).frame(width: 56)
                        Text("%")
                        Spacer(minLength: 0)
                        Button {
                            let rid = row.id
                            wsRows.removeAll { $0.id == rid }
                        } label: {
                            Image(systemName: "trash").foregroundColor(Brand.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Убрать ступень")
                    }
                    .font(.subheadline)
                    .disabled(!canPrice)
                }
                if canPrice && wsRows.count < CategoryWholesaleLogic.maxTiers {
                    Button("+ Ещё ступень") { wsRows.append(CategoryWholesaleLogic.Row()) }
                        .buttonStyle(.borderless)
                }
                wsRoundingControls.disabled(!canPrice)
            }
        } header: {
            Text("Оптовая скидка для товаров категории")
        } footer: {
            if !canPrice {
                Text(verbatim: "Менять оптовую скидку может сотрудник с правом «Цены».")
            } else if wsChanged, let e = wsError {
                Text(verbatim: e).foregroundColor(.red)
            } else {
                Text(verbatim: wsFooterText)
            }
        }
        .listRowBackground(Brand.card)
        .onChange(of: wsMode) { m in
            if m == CategoryWholesaleLogic.modeRule && wsRows.isEmpty { wsRows = [CategoryWholesaleLogic.Row()] }
        }
        .onChange(of: parentId) { pid in
            // «Без опта» есть только у подкатегории; у верхнего уровня — «Нет опта».
            if pid <= 0 && wsMode == CategoryWholesaleLogic.modeOff { wsMode = CategoryWholesaleLogic.modeInherit }
        }
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
                if showWholesale { wholesaleSection }
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
                        // wholesale уходит, только если секцию меняли (и есть право «Цены»).
                        let ws: [String: Any]? = (showWholesale && canPrice && wsChanged)
                            ? CategoryWholesaleLogic.payload(mode: wsMode, rows: wsRows, rounding: wsRoundingPayload) : nil
                        Task {
                            fieldError = nil
                            let err = await onSave(trimmed, sort, par, ws)
                            if let err { fieldError = err } else { dismiss() }
                        }
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || (showWholesale && canPrice && wsChanged && wsError != nil))
                }
            }
        }
    }
}
