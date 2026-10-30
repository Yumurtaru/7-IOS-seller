import SwiftUI

// ============================================================================
//  Товары — GET /api/seller/products?category=&status=&q=&page= (30/страница).
//  Поиск, фильтр категорий, тумблер наличия, быстрая цена, режим выбора
//  для bulk-действий (POST /api/seller/products/bulk), стоп-лист.
//  АY (сайт А616): чипы avail/stopped/nophoto/nocat/lowstock и сортировка
//  sort/dir — только когда сервер их знает (ProductsPage.knowsFilters).
// ============================================================================

/// АY: быстрые фильтры списка товаров (routes/seller_products.php, GET /api/seller/products).
enum ProductQuickFilter: String, CaseIterable, Identifiable {
    case avail, stopped, nophoto, nocat, lowstock
    var id: String { rawValue }
    var title: String {
        switch self {
        case .avail:    return "В наличии"
        case .stopped:  return "В стопе"
        case .nophoto:  return "Без фото"
        case .nocat:    return "Без категории"
        case .lowstock: return "Мало на складе"
        }
    }
    /// Параметр запроса: все — «=1» (avail=1 — в наличии).
    var query: [String: String] { [rawValue: "1"] }
}

/// АY: сортировка (sort=name|price|stock|new, dir=asc|desc); .catalog — как раньше.
enum ProductSort: String, CaseIterable, Identifiable {
    case catalog, name, priceAsc, priceDesc, stock, new
    var id: String { rawValue }
    var title: String {
        switch self {
        case .catalog:   return "Как в каталоге"
        case .name:      return "По названию"
        case .priceAsc:  return "Сначала дешёвые"
        case .priceDesc: return "Сначала дорогие"
        case .stock:     return "Меньше всего на складе"
        case .new:       return "Сначала новые"
        }
    }
    var query: [String: String] {
        switch self {
        case .catalog:   return [:]
        case .name:      return ["sort": "name", "dir": "asc"]
        case .priceAsc:  return ["sort": "price", "dir": "asc"]
        case .priceDesc: return ["sort": "price", "dir": "desc"]
        case .stock:     return ["sort": "stock", "dir": "asc"]
        case .new:       return ["sort": "new", "dir": "desc"]
        }
    }
}

@MainActor
final class ProductsViewModel: ObservableObject {
    @Published var items: [ProductSummary] = []
    @Published var categories: [SellerCategory] = []
    // Сразу .loading: пока грузились категории (до списка), экран в .idle
    // показывал «Товаров пока нет» и кнопку «Добавить первый товар» магазину с товарами.
    @Published var state: LoadState = .loading
    @Published var search = ""
    // Смена фильтра сразу убирает строки прежнего и гасит его запросы (как в
    // заказах): раньше товары прежней категории стояли под новым чипом, а при
    // сбое загрузки — так и оставались под ним.
    @Published var categoryFilter: Int? {
        didSet {
            if categoryFilter != oldValue {
                if categoryFilter != nil && quickFilter == .nocat { quickFilter = nil }
                items = []; state = .loading; gen += 1; Task { await reload() }
            }
        }
    }
    @Published var statusFilter: String? {
        didSet { if statusFilter != oldValue { items = []; state = .loading; gen += 1; Task { await reload() } } }
    }
    /// АY: быстрый фильтр и сортировка — только при knowsFilters.
    @Published var quickFilter: ProductQuickFilter? {
        didSet {
            if quickFilter != oldValue {
                // «Без категории» и чип категории вместе дают пустой список.
                if quickFilter == .nocat && categoryFilter != nil { categoryFilter = nil; return }
                items = []; state = .loading; gen += 1; Task { await reload() }
            }
        }
    }
    @Published var sort: ProductSort = .catalog {
        didSet { if sort != oldValue { items = []; state = .loading; gen += 1; Task { await reload() } } }
    }
    /// Сервер подтвердил, что знает новые фильтры (поля stop_until/category_id в ответе).
    @Published private(set) var knowsFilters = false
    @Published var actionError: String?

    // Режим выбора (bulk)
    @Published var selecting = false
    @Published var selected: Set<Int> = []

    private var page = 1
    private var hasMore = false
    private var loadingMore = false
    /// Поколение списка: ответ устаревшего фильтра (или дозагрузка старого
    /// списка), пришедший после reload(), не должен перетирать новые данные.
    private var gen = 0
    private var searchTask: Task<Void, Never>?

    func onSearchChanged() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)   // дебаунс
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func loadCategories() async {
        categories = (try? await API.shared.categories()) ?? categories
    }

    /// Первая страница и фильтры, под которыми загружены страницы списка.
    private var firstPageCount = 0
    private var pagesKey = ""
    private var filterKey: String {
        "\(categoryFilter ?? -1)|\(statusFilter ?? "")|\(search)|\(quickFilter?.rawValue ?? "")|\(sort.rawValue)"
    }

    /// Параметры АY — только когда сервер их знает: старый сервер их молча
    /// игнорирует, и список выглядел бы отфильтрованным, не будучи им.
    private var extraQuery: [String: String] {
        guard knowsFilters else { return [:] }
        var q = quickFilter?.query ?? [:]
        for (k, v) in sort.query { q[k] = v }
        return q
    }

    /// Ответ без признака нового сервера (сайт откатили): фильтр и сортировку
    /// снимаем — иначе список под чипом был бы неотфильтрованным. true — сняли.
    private func dropUnknownFilters(_ res: ProductsPage) -> Bool {
        if res.knowsFilters { knowsFilters = true; return false }
        guard !res.items.isEmpty else { return false }
        let had = quickFilter != nil || sort != .catalog
        knowsFilters = false
        guard had else { return false }
        quickFilter = nil
        sort = .catalog
        return true
    }

    /// keepPages: обновить первую страницу, догруженные оставить. Раньше
    /// возврат с карточки товара откатывал список к 30 строкам — прокрутка прыгала.
    func reload(keepPages: Bool = false) async {
        gen += 1
        let myGen = gen
        moreError = nil   // ошибка догрузки прежнего списка к новому не относится
        if items.isEmpty { state = .loading }
        let key = filterKey
        do {
            let res = try await API.shared.products(category: categoryFilter, status: statusFilter,
                                                    q: search, page: 1, extra: extraQuery)
            guard myGen == gen else { return }
            if dropUnknownFilters(res) { return }
            if keepPages && page > 1 && key == pagesKey {
                // Перечитываем все загруженные страницы: склейка «новая первая +
                // старый хвост» теряла строки на стыке страниц.
                var all = res.items
                var more = res.hasMore ?? false
                var p = 1
                while p < page, more {
                    p += 1
                    let r = try await API.shared.products(category: categoryFilter, status: statusFilter,
                                                          q: search, page: p, extra: extraQuery)
                    guard myGen == gen else { return }
                    all += r.items
                    more = r.hasMore ?? false
                }
                var seen = Set<Int>()
                items = all.filter { seen.insert($0.productId).inserted }
                page = p
                hasMore = more
            } else {
                page = 1
                items = res.items
                hasMore = res.hasMore ?? false
            }
            firstPageCount = res.items.count
            pagesKey = key
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == gen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(current: ProductSummary) async {
        guard hasMore, !loadingMore, current.productId == items.last?.productId else { return }
        loadingMore = true
        defer { loadingMore = false }
        let myGen = gen
        moreError = nil
        do {
            let res = try await API.shared.products(category: categoryFilter, status: statusFilter,
                                                    q: search, page: page + 1, extra: extraQuery)
            guard myGen == gen else { return }
            // Сайт откатили между страницами: фильтр сервер уже не применил —
            // снимаем его (список перечитается), хвост не дописываем.
            // Фильтров не было — страница годится, только чипы скрываются.
            if knowsFilters && !res.knowsFilters && !res.items.isEmpty, dropUnknownFilters(res) { return }
            page += 1
            // Смещение страниц «плывёт», когда появляются новые записи: одна и та же
            // запись может прийти дважды, а дубли id ломают ForEach.
            let known = Set(items.map(\.productId))
            items += res.items.filter { !known.contains($0.productId) }
            hasMore = res.hasMore ?? false
        } catch is CancellationError {
        } catch {
            // Раньше ошибка глоталась: лента вставала на последней строке без
            // единого слова, и товары ниже казались несуществующими.
            guard myGen == gen else { return }
            moreError = error.localizedDescription
        }
    }

    /// Следующая страница не загрузилась — строка «Повторить» под списком.
    @Published var moreError: String?

    func retryMore() async {
        guard let last = items.last else { return }
        await loadMoreIfNeeded(current: last)
    }

    /// Товары, удалённые в карточке: строку убираем, когда карточка закроется.
    private var deletedIds: Set<Int> = []
    func markDeleted(_ productId: Int) { deletedIds.insert(productId) }

    /// После карточки товара обновляем только его строку — список и прокрутка
    /// остаются на месте. Товар удалён (сервер ответил отказом) — строку убираем.
    func refreshRow(productId: Int) async {
        if deletedIds.remove(productId) != nil {
            items.removeAll { $0.productId == productId }
            return
        }
        do {
            let d = try await API.shared.product(id: productId)
            guard let idx = items.firstIndex(where: { $0.productId == productId }) else { return }
            items[idx].name = d.name
            items[idx].article = d.article
            items[idx].barcode = d.barcode
            items[idx].price = d.price
            items[idx].priceOld = d.priceOld
            items[idx].type = d.type
            items[idx].status = d.status
            items[idx].isAvailable = d.isAvailable
            if let cid = d.categoryId {
                if let cat = categories.first(where: { $0.categoryId == cid }) { items[idx].category = cat.name }
            } else {
                items[idx].category = nil
            }
            if knowsFilters { items[idx].categoryId = d.categoryId }
        } catch let e as APIError {
            // Убираем строку только если товара больше нет (404). Временный сбой
            // сервера или 403 с текстом раньше удалял живой товар из списка.
            if case .http(404) = e { items.removeAll { $0.productId == productId } }
        } catch {}
    }

    /// Переключение наличия уже в пути: сервер инвертирует сам, и второй
    /// быстрый свайп возвращал товар в прежнее состояние. @Published — тумблер
    /// в строке гаснет до ответа.
    @Published private(set) var togglingIds: Set<Int> = []

    /// Тумблер «в наличии»: сервер инвертирует сам и возвращает новое значение.
    func toggleAvailability(_ product: ProductSummary) async {
        guard !togglingIds.contains(product.productId) else { return }
        togglingIds.insert(product.productId)
        defer { togglingIds.remove(product.productId) }
        actionError = nil
        do {
            let ack = try await API.shared.toggleAvailability(productId: product.productId)
            if let idx = items.firstIndex(where: { $0.productId == product.productId }) {
                items[idx].isAvailable = ack.isAvailable
                if ack.isAvailable == true { items[idx].stopped = false; items[idx].stopUntil = nil }
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Быстрая цена. nil — сохранено; иначе текст ошибки для окна цены
    /// (паритет с Android: окно закрывается только после ответа сервера).
    func quickPrice(_ product: ProductSummary, price: Decimal) async -> String? {
        actionError = nil
        do {
            let ack = try await API.shared.setPrice(productId: product.productId, price: price, priceOld: nil)
            if let idx = items.firstIndex(where: { $0.productId == product.productId }) {
                items[idx].price = ack.price ?? price
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var bulkBusy = false

    func bulk(action: String, value: String?) async {
        // Двойной выбор действия слал два массовых запроса (второй «удалить» — с ошибкой).
        guard !selected.isEmpty, !bulkBusy else { return }
        bulkBusy = true
        defer { bulkBusy = false }
        actionError = nil
        do {
            let ack = try await API.shared.bulkProducts(ids: Array(selected), action: action, value: value)
            selecting = false
            selected = []
            await reload()
            // Товары с остатком сервер не удаляет и пишет почему — раньше это
            // молча терялось, и товары оставались в списке без объяснения.
            if let msg = ack.message, !msg.isEmpty { actionError = msg }
        } catch {
            actionError = error.localizedDescription
        }
    }
}

struct ProductsView: View {
    @EnvironmentObject var session: Session
    @StateObject private var vm = ProductsViewModel()
    @State private var quickPriceTarget: ProductSummary?
    @State private var showCreate = false
    /// Открытая карточка товара. Строка — не NavigationLink: в ней свои
    /// тумблер наличия и кнопка ₽ (паритет с Android), а NavigationLink
    /// забирал касания всей строки.
    @State private var openedProduct: ProductSummary?
    /// Карточка реально на экране и когда её открывали — повторный тап по той же
    /// строке игнорируем (раньше карточка «моргала» назад-вперёд).
    @State private var detailShown = false
    @State private var openedAt = Date.distantPast
    @State private var showStopList = false
    /// Массовое удаление — только после вопроса: пункт меню удалял выбранные
    /// товары сразу, одним касанием (а одиночное удаление спрашивает).
    @State private var confirmBulkDelete = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filters
                if let err = vm.actionError { InlineErrorBar(message: err) }
                list
                if vm.selecting { bulkBar }
            }
            // Паритет с Android (FAB): «Новый товар» на виду, а не в меню «…».
            .overlay(alignment: .bottomTrailing) {
                if canCreate && !vm.selecting && !vm.items.isEmpty {
                    Button { showCreate = true } label: {
                        Label(session.shopType == "cafe" ? "Новое блюдо" : "Новый товар", systemImage: "plus")
                            .font(.headline)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 13)
                            .background(Brand.accent, in: Capsule())
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 16)
                }
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(session.shopType == "cafe" ? "Меню" : "Товары")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $vm.search, prompt: "Название, артикул, штрихкод")
            .onChange(of: vm.search) { _ in vm.onSearchChanged() }
            .toolbar {
                ToolbarItem(placement: .principal) { ShopSwitcherMenu() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        // Создание, цена и удаление — отдельные права внутри
                        // «Товаров»: продавец может править карточку, но не
                        // заводить позиции и не переписывать цены.
                        if canCreate {
                            Button { showCreate = true } label: { Label("Новый товар", systemImage: "plus") }
                        }
                        // Без прав на массовые действия выбор ни к чему не ведёт:
                        // строки отмечались, а меню «Действия» не появлялось.
                        // С А319 /products/bulk — право раздела «Товары» (не
                        // «Создавать товары»); удаление — ещё и products.delete.
                        if canBulk {
                            Button {
                                vm.selecting.toggle()
                                vm.selected = []
                            } label: {
                                Label(vm.selecting ? "Отменить выбор" : "Выбрать несколько", systemImage: "checkmark.circle")
                            }
                        }
                        Button { openStopList() } label: { Label("Стоп-лист", systemImage: "nosign") }
                        // АY: сортировка — только когда сервер её знает (сайт А616).
                        if vm.knowsFilters {
                            Picker(selection: $vm.sort) {
                                ForEach(ProductSort.allCases) { s in Text(s.title).tag(s) }
                            } label: {
                                Label("Сортировка", systemImage: "arrow.up.arrow.down")
                            }
                            .pickerStyle(.menu)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(isPresented: $showStopList) { StopListView() }
            .navigationDestination(isPresented: Binding(
                get: { openedProduct != nil },
                set: { if !$0 { openedProduct = nil } }
            )) {
                if let product = openedProduct {
                    // Удалили товар в карточке — строку убираем при закрытии: проверка 404
                    // в refreshRow не срабатывала (сервер отвечает 404 с текстом,
                    // это .server, а не .http), и удалённый товар висел в списке.
                    ProductEditView(productId: product.productId, categories: vm.categories,
                                    onDeleted: { vm.markDeleted(product.productId) })
                        .id(product.productId)
                        .onAppear { detailShown = true }
                        // Только строка этого товара: полный reload откатывал список к первой странице.
                        .onDisappear {
                            detailShown = false
                            Task { await vm.refreshRow(productId: product.productId) }
                        }
                }
            }
            .confirmationDialog("Удалить выбранные товары (\(vm.selected.count)) безвозвратно?",
                                isPresented: $confirmBulkDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { Task { await vm.bulk(action: "delete", value: nil) } }
            }
            .sheet(isPresented: $showCreate, onDismiss: { Task { await vm.reload() } }) {
                NavigationStack {
                    // «Закрыть» — внутри карточки: гаснет, пока создание в пути, и
                    // спрашивает, если форма заполнена. После создания карточка
                    // остаётся открытой — можно сразу добавить фото.
                    ProductEditView(productId: nil, categories: vm.categories,
                                    onClose: { showCreate = false })
                }
                // Случайный свайп вниз закрывал лист и стирал всю заполненную
                // карточку. Закрыть — только кнопкой.
                .interactiveDismissDisabled()
            }
            // Паритет с Android: в поле уже стоит текущая цена, окно закрывается
            // только после ответа сервера (ошибка — в самом окне).
            .sheet(item: $quickPriceTarget) { product in
                QuickPriceSheet(product: product) { price in
                    await vm.quickPrice(product, price: price)
                }
            }
            .task {
                await vm.loadCategories()
                // Возврат с карточки снова запускает .task — догруженные страницы не теряем.
                await vm.reload(keepPages: true)
            }
        }
    }

    /// Карточка товара. Повторный тап по вкладке снимает её со стека без вызова
    /// сеттера (как у стоп-листа ниже): openedProduct оставался заданным, и
    /// следующая строка не открывалась. Сначала сбрасываем, потом идём.
    private func openProduct(_ product: ProductSummary) {
        if openedProduct?.productId == product.productId
            && (detailShown || Date().timeIntervalSince(openedAt) < 1) { return }
        openedAt = Date()
        if openedProduct == nil { openedProduct = product; return }
        openedProduct = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { openedProduct = product }
    }

    /// Повторный тап по вкладке снимает стоп-лист со стека без вызова сеттера:
    /// флаг оставался true, и пункт «Стоп-лист» больше ничего не открывал.
    private func openStopList() {
        if !showStopList { showStopList = true; return }
        showStopList = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { showStopList = true }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "Все", selected: vm.categoryFilter == nil && vm.statusFilter == nil && vm.quickFilter == nil) {
                    vm.categoryFilter = nil; vm.statusFilter = nil; vm.quickFilter = nil
                }
                // АY: быстрые фильтры — только когда сервер их знает (сайт А616).
                if vm.knowsFilters {
                    ForEach(ProductQuickFilter.allCases) { f in
                        FilterChip(title: f.title, selected: vm.quickFilter == f) {
                            vm.quickFilter = vm.quickFilter == f ? nil : f
                        }
                    }
                }
                FilterChip(title: "Скрытые", selected: vm.statusFilter == "hidden") {
                    vm.statusFilter = vm.statusFilter == "hidden" ? nil : "hidden"
                }
                ForEach(vm.categories) { cat in
                    FilterChip(title: cat.name ?? "—", selected: vm.categoryFilter == cat.categoryId) {
                        vm.categoryFilter = vm.categoryFilter == cat.categoryId ? nil : cat.categoryId
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var list: some View {
        List {
            ForEach(vm.items) { product in
                row(product)
                    .listRowBackground(Brand.card)
                    .task { await vm.loadMoreIfNeeded(current: product) }
            }
            // Как в заказах: ошибка догрузки видна и повторяется одним нажатием.
            if let err = vm.moreError, !vm.items.isEmpty {
                Button { Task { await vm.retryMore() } } label: {
                    Text("Не загрузилось: \(err) · Повторить")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Brand.red)
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Brand.card)
            }
            // Место под кнопкой «Новый товар»: последняя строка не прячется под ней.
            if canCreate && !vm.selecting && !vm.items.isEmpty {
                Color.clear.frame(height: 56)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.reload() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "square.grid.2x2", emptyTitle: emptyTitle,
                   emptySubtitle: emptySubtitle,
                   retry: { Task { await vm.reload() } },
                   // Новый магазин: кнопка первого шага прямо на пустом экране.
                   emptyActionTitle: addFirstTitle,
                   emptyAction: addFirstAction)
    }

    private var addFirstTitle: String? {
        guard canAddFirst else { return nil }
        return session.shopType == "cafe" ? "Добавить первое блюдо" : "Добавить первый товар"
    }

    private var addFirstAction: (() -> Void)? {
        guard canAddFirst else { return nil }
        return { showCreate = true }
    }

    /// Каталог пуст без фильтров и есть право заводить позиции.
    private var canAddFirst: Bool {
        let filtered = !vm.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || vm.statusFilter != nil || vm.categoryFilter != nil || vm.quickFilter != nil
        return !filtered && canCreate
    }

    /// Новый товар: право «Создавать товары» и «Цены» — без цены сервер
    /// товар не создаёт (403, А116), кнопка вела бы к отказу.
    private var canCreate: Bool { session.can("products.create") && session.can("products.price") }

    /// Скрыть / показать / в категорию: право раздела «Товары» (А319).
    private var canBulk: Bool { session.can("products") }

    /// паритет с Android: пустой поиск или фильтр — не «товаров нет вообще».
    /// Новый товар — из меню «…» или кнопкой на пустом экране.
    private var emptyTitle: String {
        let q = vm.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "По запросу «\(q)» ничего не найдено" }
        if vm.statusFilter == "hidden" { return "Скрытых товаров нет" }
        if vm.quickFilter != nil { return "По этому фильтру товаров нет" }
        if vm.categoryFilter != nil { return "В этой категории товаров нет" }
        // У кафе вкладка называется «Меню» — и пустой экран о меню.
        return session.shopType == "cafe" ? "В меню пока пусто" : "Товаров пока нет"
    }

    private var emptySubtitle: String? {
        let filtered = !vm.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || vm.statusFilter != nil || vm.categoryFilter != nil || vm.quickFilter != nil
        if filtered { return nil }
        // Сотруднику без права создания раньше советовали меню, где пункта нет.
        if !session.can("products.create") { return "Позиции заводит владелец или сотрудник с правом создания товаров" }
        if !session.can("products.price") { return "Новый товар с ценой заводит владелец или сотрудник с правом «Менять цены»" }
        if session.shopStatus == "draft" { return "Без товаров организацию не отправить на проверку — клиентам нечего заказать" }
        return "Добавьте первую позицию — она появится на витрине"
    }

    /// Продаётся ли позиция: в наличии и не в стоп-листе (стоп мог поставить и кассир).
    private static func sells(_ p: ProductSummary) -> Bool {
        p.isAvailable == true && p.stopped != true
    }

    @ViewBuilder
    private func row(_ product: ProductSummary) -> some View {
        if vm.selecting {
            Button {
                if vm.selected.contains(product.productId) { vm.selected.remove(product.productId) }
                else { vm.selected.insert(product.productId) }
            } label: {
                HStack {
                    Image(systemName: vm.selected.contains(product.productId) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(Brand.accent)
                    ProductRow(product: product, stopDetail: vm.knowsFilters)
                }
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                // Каждая кнопка строки — .borderless: иначе касание по строке
                // срабатывало у всех кнопок сразу.
                Button { openProduct(product) } label: {
                    ProductRow(product: product, stopDetail: vm.knowsFilters).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                // Паритет с Android: ₽ в строке, поле — с текущей ценой.
                if session.can("products.price") {
                    Button { quickPriceTarget = product } label: {
                        Image(systemName: "rublesign.circle")
                            .font(.title3)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderless)
                    .tint(Brand.accent)
                    .accessibilityLabel("Изменить цену")
                }
                // Паритет с Android: «В наличии» — тумблер прямо в строке.
                // А318: позиция в стоп-листе не продаётся — тумблер выключен, и нажатие
                // ВОЗВРАЩАЕТ её (сервер ставит is_available = 1 и снимает стоп).
                Toggle("В наличии", isOn: Binding(
                    get: { Self.sells(product) },
                    set: { new in
                        if new != Self.sells(product) {
                            Task { await vm.toggleAvailability(product) }
                        }
                    }
                ))
                .labelsHidden()
                .tint(Brand.green)
                .disabled(vm.togglingIds.contains(product.productId))
            }
            // Долгое нажатие (паритет с Android): выбор нескольких и быстрые действия.
            .contextMenu {
                if canBulk {
                    Button {
                        vm.selecting = true
                        vm.selected = [product.productId]
                    } label: { Label("Выбрать несколько", systemImage: "checkmark.circle") }
                }
                Button {
                    Task { await vm.toggleAvailability(product) }
                } label: {
                    Label(Self.sells(product) ? "Нет в наличии" : "В наличии",
                          systemImage: Self.sells(product) ? "nosign" : "checkmark")
                }
                if session.can("products.price") {
                    Button { quickPriceTarget = product } label: { Label("Изменить цену", systemImage: "rublesign") }
                }
                Button { openProduct(product) } label: { Label("Открыть карточку", systemImage: "square.and.pencil") }
            }
            .swipeActions(edge: .trailing) {
                Button {
                    Task { await vm.toggleAvailability(product) }
                } label: {
                    Label(Self.sells(product) ? "Снять" : "В наличии",
                          systemImage: Self.sells(product) ? "nosign" : "checkmark")
                }
                .tint(Self.sells(product) ? Brand.amber : Brand.green)
                if session.can("products.price") {
                    Button {
                        quickPriceTarget = product
                    } label: {
                        Label("Цена", systemImage: "rublesign")
                    }
                    .tint(.blue)
                }
            }
        }
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            // «1 выбрано» / «5 выбрано» читалось с ошибкой — форма без согласования.
            Text("Выбрано: \(vm.selected.count)")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.text)
            Spacer()
            // Массовые действия: /products/bulk с А319 — право раздела «Товары»
            // (seller_products.php, «Создавать товары» не нужно), удаление —
            // ещё и products.delete.
            if canBulk {
                Menu("Действия") {
                    if canBulk {
                        Button("Показать") { Task { await vm.bulk(action: "status", value: "active") } }
                        // АY: action=avail (сайт А616) — старый сервер ответил бы «Неизвестное действие».
                        if vm.knowsFilters {
                            Button("В наличии") { Task { await vm.bulk(action: "avail", value: "1") } }
                        }
                        Button("Скрыть") { Task { await vm.bulk(action: "status", value: "hidden") } }
                        Menu("В категорию") {
                            ForEach(vm.categories) { cat in
                                Button(cat.name ?? "—") {
                                    Task { await vm.bulk(action: "category", value: String(cat.categoryId)) }
                                }
                            }
                        }
                    }
                    // Удаление — право раздела и products.delete (ветка delete в seller_products.php).
                    if canBulk && session.can("products.delete") {
                        Button("Удалить", role: .destructive) { confirmBulkDelete = true }
                    }
                }
                .disabled(vm.selected.isEmpty)
            }
        }
        .padding(14)
        .background(Brand.card)
    }
}

struct ProductRow: View {
    let product: ProductSummary
    /// АY: сервер шлёт stop_until — «В стопе до ЧЧ:ММ» / «В стопе»; иначе как раньше «Стоп».
    var stopDetail = false

    private var stopText: String {
        guard stopDetail else { return "Стоп" }
        if let until = product.stopUntil, !until.isEmpty { return "В стопе до " + Self.untilText(until) }
        return "В стопе"
    }

    /// Время сервера (МСК): сегодня — «ЧЧ:ММ», другой день — «ДД.ММ ЧЧ:ММ».
    private static let mskCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        return c
    }()
    private static func mskFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        f.dateFormat = format
        return f
    }
    private static let mskTime = mskFormatter("HH:mm")
    private static let mskDayTime = mskFormatter("dd.MM HH:mm")

    static func untilText(_ s: String) -> String {
        guard let d = DateFmt.parse(s) else { return DateFmt.time(s) }
        return mskCal.isDate(d, inSameDayAs: Date()) ? mskTime.string(from: d) : mskDayTime.string(from: d)
    }

    var body: some View {
        HStack(spacing: 10) {
            RemoteImage(path: product.photo, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(product.name ?? "Товар")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Brand.text)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(Money.rub(product.price))
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Brand.text)
                    if let old = product.priceOld, old > 0 {
                        Text(Money.rub(old))
                            .font(.caption)
                            .strikethrough()
                            .foregroundColor(Brand.muted)
                    }
                }
                HStack(spacing: 6) {
                    if let cat = product.category, !cat.isEmpty {
                        Text(cat).font(.caption2).foregroundColor(Brand.muted)
                    }
                    // паритет с Android: артикул в строке — по нему товар ищут на складе.
                    if let art = product.article, !art.isEmpty {
                        Text("арт. " + art).font(.caption2).foregroundColor(Brand.muted).lineLimit(1)
                    }
                    if product.status == "hidden" {
                        StatusBadge(text: "Скрыт", color: Brand.muted)
                    }
                    if product.stopped == true {
                        StatusBadge(text: stopText, color: Brand.red)
                    } else if product.isAvailable != true {
                        StatusBadge(text: "Нет в наличии", color: Brand.amber)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

/// Окно быстрой цены (паритет с Android): в поле уже стоит текущая цена, ввод
/// проверяется сразу, окно закрывается только после ответа сервера — ошибка
/// остаётся в окне, а не всплывает над списком после того, как оно закрылось.
struct QuickPriceSheet: View {
    let product: ProductSummary
    /// nil — сохранено; иначе текст ошибки.
    let onSave: (Decimal) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(product: ProductSummary, onSave: @escaping (Decimal) async -> String?) {
        self.product = product
        self.onSave = onSave
        _text = State(initialValue: product.price.map { "\($0)".replacingOccurrences(of: ".", with: ",") } ?? "")
    }

    /// Строгий разбор: Decimal(string:) читает только начало строки, и
    /// вставленное «1 500» (так цены пишет сам Money.rub) ставило цену 1 ₽;
    /// не больше двух знаков после запятой; «0» не проходит.
    private var parsed: Decimal? {
        let t = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "₽", with: "")
        guard let p = Money.strict(t), p > 0 else { return nil }
        return p
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Цена, ₽", text: $text)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .disabled(saving)
                } header: {
                    Text(product.name ?? "Товар")
                } footer: {
                    if let err = error {
                        Text(err).foregroundColor(Brand.red)
                    } else if parsed == nil && !text.isEmpty {
                        Text("Число больше нуля, например 1500 или 1500,50").foregroundColor(Brand.amber)
                    } else if let p = product.price {
                        Text("Сейчас: " + Money.rub(p))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Быстрая цена")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Сохранить") {
                            guard !saving, let p = parsed else { return }
                            saving = true
                            error = nil
                            Task {
                                let err = await onSave(p)
                                saving = false
                                if let err { error = err } else { dismiss() }
                            }
                        }
                        .disabled(parsed == nil)
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.height(260), .medium])
        .interactiveDismissDisabled(saving)
    }
}
