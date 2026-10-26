import SwiftUI

// ============================================================================
//  Товары — GET /api/seller/products?category=&status=&q=&page= (30/страница).
//  Поиск, фильтр категорий, тумблер наличия, быстрая цена, режим выбора
//  для bulk-действий (POST /api/seller/products/bulk), стоп-лист.
// ============================================================================

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
        didSet { if categoryFilter != oldValue { items = []; state = .loading; gen += 1; Task { await reload() } } }
    }
    @Published var statusFilter: String? {
        didSet { if statusFilter != oldValue { items = []; state = .loading; gen += 1; Task { await reload() } } }
    }
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
    private var filterKey: String { "\(categoryFilter ?? -1)|\(statusFilter ?? "")|\(search)" }

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
                                                    q: search, page: 1)
            guard myGen == gen else { return }
            if keepPages && page > 1 && key == pagesKey {
                // Перечитываем все загруженные страницы: склейка «новая первая +
                // старый хвост» теряла строки на стыке страниц.
                var all = res.items
                var more = res.hasMore ?? false
                var p = 1
                while p < page, more {
                    p += 1
                    let r = try await API.shared.products(category: categoryFilter, status: statusFilter,
                                                          q: search, page: p)
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
                                                    q: search, page: page + 1)
            guard myGen == gen else { return }
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
        } catch let e as APIError {
            // Убираем строку только если товара больше нет (404). Временный сбой
            // сервера или 403 с текстом раньше удалял живой товар из списка.
            if case .http(404) = e { items.removeAll { $0.productId == productId } }
        } catch {}
    }

    /// Переключение наличия уже в пути: сервер инвертирует сам, и второй
    /// быстрый свайп возвращал товар в прежнее состояние.
    private var togglingIds: Set<Int> = []

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
                if ack.isAvailable == true { items[idx].stopped = false }
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    func quickPrice(_ product: ProductSummary, price: Decimal) async {
        actionError = nil
        do {
            let ack = try await API.shared.setPrice(productId: product.productId, price: price, priceOld: nil)
            if let idx = items.firstIndex(where: { $0.productId == product.productId }) {
                items[idx].price = ack.price ?? price
            }
        } catch {
            actionError = error.localizedDescription
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
    @State private var quickPriceText = ""
    @State private var showCreate = false
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
                        if session.can("products.create") {
                            Button { showCreate = true } label: { Label("Новый товар", systemImage: "plus") }
                        }
                        // Без прав на массовые действия выбор ни к чему не ведёт:
                        // строки отмечались, а меню «Действия» не появлялось.
                        // Любое массовое действие (и удаление тоже) сервер пускает
                        // только с products.create — одного products.delete мало.
                        if session.can("products.create") {
                            Button {
                                vm.selecting.toggle()
                                vm.selected = []
                            } label: {
                                Label(vm.selecting ? "Отменить выбор" : "Выбрать несколько", systemImage: "checkmark.circle")
                            }
                        }
                        Button { openStopList() } label: { Label("Стоп-лист", systemImage: "nosign") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(isPresented: $showStopList) { StopListView() }
            .confirmationDialog("Удалить выбранные товары (\(vm.selected.count)) безвозвратно?",
                                isPresented: $confirmBulkDelete, titleVisibility: .visible) {
                Button("Удалить", role: .destructive) { Task { await vm.bulk(action: "delete", value: nil) } }
            }
            .sheet(isPresented: $showCreate, onDismiss: { Task { await vm.reload() } }) {
                NavigationStack {
                    ProductEditView(productId: nil, categories: vm.categories)
                        // Случайный свайп вниз закрывал лист и стирал всю заполненную
                        // карточку. Закрыть — только кнопкой.
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Закрыть") { showCreate = false }
                            }
                        }
                }
                .interactiveDismissDisabled()
            }
            .alert("Быстрая цена", isPresented: Binding(
                get: { quickPriceTarget != nil },
                set: { if !$0 { quickPriceTarget = nil } }
            )) {
                TextField("Цена, ₽", text: $quickPriceText)
                    .keyboardType(.decimalPad)
                Button("Сохранить") {
                    // Строгий разбор: Decimal(string:) читает только начало строки,
                    // и вставленное «1 500» (так цены пишет сам Money.rub) ставило
                    // товару цену 1 ₽; «0» тоже проходил.
                    let t = String(quickPriceText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
                        .replacingOccurrences(of: ",", with: ".")
                        .replacingOccurrences(of: "₽", with: "")
                    if let p = quickPriceTarget {
                        // Не больше двух знаков после запятой: «99,999» уходило как есть,
                        // и сервер молча округлял цену до 100 ₽.
                        if let price = Money.strict(t), price > 0 {
                            Task { await vm.quickPrice(p, price: price) }
                        } else {
                            vm.actionError = "Некорректная цена"
                        }
                    }
                    quickPriceTarget = nil
                }
                Button("Отмена", role: .cancel) { quickPriceTarget = nil }
            } message: {
                Text(quickPriceTarget?.name ?? "")
            }
            .task {
                await vm.loadCategories()
                // Возврат с карточки снова запускает .task — догруженные страницы не теряем.
                await vm.reload(keepPages: true)
            }
        }
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
                FilterChip(title: "Все", selected: vm.categoryFilter == nil && vm.statusFilter == nil) {
                    vm.categoryFilter = nil; vm.statusFilter = nil
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
            || vm.statusFilter != nil || vm.categoryFilter != nil
        return !filtered && session.can("products.create")
    }

    /// паритет с Android: пустой поиск или фильтр — не «товаров нет вообще».
    /// Новый товар — из меню «…» или кнопкой на пустом экране.
    private var emptyTitle: String {
        let q = vm.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { return "По запросу «\(q)» ничего не найдено" }
        if vm.statusFilter == "hidden" { return "Скрытых товаров нет" }
        if vm.categoryFilter != nil { return "В этой категории товаров нет" }
        // У кафе вкладка называется «Меню» — и пустой экран о меню.
        return session.shopType == "cafe" ? "В меню пока пусто" : "Товаров пока нет"
    }

    private var emptySubtitle: String? {
        let filtered = !vm.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || vm.statusFilter != nil || vm.categoryFilter != nil
        if filtered { return nil }
        // Сотруднику без права создания раньше советовали меню, где пункта нет.
        if !session.can("products.create") { return "Позиции заводит владелец или сотрудник с правом создания товаров" }
        if session.shopStatus == "draft" { return "Без товаров организацию не отправить на проверку — клиентам нечего заказать" }
        return "Добавьте первую позицию — она появится на витрине"
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
                    ProductRow(product: product)
                }
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                // Удалили товар в карточке — строку убираем при закрытии: проверка 404
                // в refreshRow не срабатывала (сервер отвечает 404 с текстом,
                // это .server, а не .http), и удалённый товар висел в списке.
                ProductEditView(productId: product.productId, categories: vm.categories,
                                onDeleted: { vm.markDeleted(product.productId) })
                    // Только строка этого товара: полный reload откатывал список к первой странице.
                    .onDisappear { Task { await vm.refreshRow(productId: product.productId) } }
            } label: {
                ProductRow(product: product)
            }
            .swipeActions(edge: .trailing) {
                Button {
                    Task { await vm.toggleAvailability(product) }
                } label: {
                    Label(product.isAvailable == true ? "Снять" : "В наличии",
                          systemImage: product.isAvailable == true ? "nosign" : "checkmark")
                }
                .tint(product.isAvailable == true ? Brand.amber : Brand.green)
                if session.can("products.price") {
                    Button {
                        quickPriceText = ""
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
            // Массовые действия закрыты правами на сервере: /products/bulk —
            // products.create, а удаление — ещё и products.delete. Раньше меню
            // видел любой, у кого есть раздел «Товары»: мерчендайзер выделял 40
            // позиций, жал «Скрыть» и получал «Недостаточно прав», а выделение
            // сбрасывалось — работа терялась.
            if session.can("products.create") {
                Menu("Действия") {
                    if session.can("products.create") {
                        Button("Показать") { Task { await vm.bulk(action: "status", value: "active") } }
                        Button("Скрыть") { Task { await vm.bulk(action: "status", value: "hidden") } }
                        Menu("В категорию") {
                            ForEach(vm.categories) { cat in
                                Button(cat.name ?? "—") {
                                    Task { await vm.bulk(action: "category", value: String(cat.categoryId)) }
                                }
                            }
                        }
                    }
                    // Удаление — оба права: products.create (сама ручка bulk) и
                    // products.delete (ветка delete в seller_products.php).
                    if session.can("products.create") && session.can("products.delete") {
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
                        StatusBadge(text: "Стоп", color: Brand.red)
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
