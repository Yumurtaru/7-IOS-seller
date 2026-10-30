import SwiftUI
import Combine

// ============================================================================
//  Заказы — GET /api/seller/orders?status=&payment=&date=&page= (по 20 на
//  страницу, has_more от сервера). Фильтры-чипы по статусу и оплате, день
//  оформления (?date=), поиск по номеру/телефону/имени на сервере (?search=,
//  П-61 №1; с задержкой ввода, вместе с фильтрами), deep link в деталь.
// ============================================================================

@MainActor
final class OrdersViewModel: ObservableObject {
    @Published var items: [OrderSummary] = []
    @Published var state: LoadState = .idle
    @Published var statusFilter: String? = "active" {
        didSet { if statusFilter != oldValue { items = []; state = .loading; gen += 1; Task { await reload() } } }
    }
    // Смена фильтра убирает старые строки: если новый запрос не удастся, под
    // чипом «Отменённые» не должны остаться активные заказы.
    @Published var paymentFilter: String? {
        didSet { if paymentFilter != oldValue { items = []; state = .loading; gen += 1; Task { await reload() } } }
    }
    /// День оформления (сервер: ?date=yyyy-MM-dd, routes/seller.php). nil — за всё время.
    @Published var dateFilter: Date? {
        didSet { if dateFilter != oldValue { items = []; state = .loading; gen += 1; Task { await reload() } } }
    }
    /// Набранный поиск (номер, телефон или имя). Запрос уходит на сервер через
    /// 400 мс после последней буквы; прежний запрос отменяется.
    @Published var search = "" {
        didSet { if search != oldValue { scheduleSearch() } }
    }
    /// Поиск, с которым загружен список (?search=); "" — без поиска.
    @Published private(set) var appliedSearch = ""
    private var searchTask: Task<Void, Never>?
    private var page = 1
    @Published private(set) var hasMore = false
    private var loadingMore = false
    /// Следующая страница не загрузилась. Раньше ошибка глоталась, а строка-
    /// триггер уже показана — лента вставала, и заказы ниже были не видны.
    @Published var moreError: String?
    /// Поколение списка: ответ устаревшего фильтра (или дозагрузка старого
    /// списка), пришедший после reload(), не должен перетирать новые данные.
    private var gen = 0

    /// Вычисляем, а не константа: подписи «Готовятся»/«Собираются»/«В работе»
    /// зависят от типа организации, а он известен только после /api/seller/me.
    static var statusChips: [(String?, String)] {
        // Бронь жилья идёт new → accepted → done: шаги доставки ей не нужны.
        if OrderStatuses.shopType == "lodging" {
            return [("active", "Активные"), (nil, "Все"), ("new", "Новые"), ("accepted", "Принятые"),
                    ("done", "Выполнены"), ("cancelled", "Отменённые")]
        }
        return [
            ("active", "Активные"), (nil, "Все"), ("new", "Новые"), ("accepted", "Принятые"),
            ("preparing", OrderStatuses.filterLabel("preparing")),
            ("ready", OrderStatuses.filterLabel("ready")),
            ("in_delivery", "В пути"),
            ("done", "Выполнены"), ("cancelled", "Отменённые"),
        ]
    }

    /// Параметр ?date= для сервера: календарный день, выбранный продавцом.
    var dateParam: String? {
        guard let d = dateFilter else { return nil }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        guard let y = c.year, let m = c.month, let day = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", y, m, day)
    }

    private var trimmedSearch: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !appliedSearch.isEmpty }
    private var searchParam: String? { appliedSearch.isEmpty ? nil : appliedSearch }

    /// Поиск на сервере: ждём паузу в наборе, затем первая страница с ?search=.
    /// Отменяется только ожидание паузы; сам запрос идёт отдельной задачей
    /// (ответ устаревшего поиска отсекает gen). Иначе отмена посреди запроса
    /// оставляла пустой список со спиннером: «12» → стёрли «3» → поиск тот же.
    private func scheduleSearch() {
        searchTask?.cancel()
        let term = trimmedSearch
        // Тот же поиск уже на экране — перечитывать нечего; но если его загрузка
        // так и не закончилась (список пуст, спиннер) — перечитываем.
        if term == appliedSearch {
            if state == .loading && items.isEmpty { Task { await reload() } }
            return
        }
        searchTask = Task { [weak self] in
            if !term.isEmpty { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled, let self = self else { return }
            self.appliedSearch = term
            self.items = []
            self.state = .loading
            self.gen += 1
            Task { await self.reload() }
        }
    }

    /// Сколько строк пришло первой страницей — чтобы при мягком обновлении
    /// заменить именно её, а догруженные страницы оставить.
    private var firstPageCount = 0

    /// keepPages: обновить первую страницу, не выбрасывая догруженные.
    /// Раньше возврат из заказа (.task срабатывает снова) и смена статуса
    /// откатывали список к 20 строкам — прокрутка прыгала.
    func reload(keepPages: Bool = false) async {
        gen += 1
        let myGen = gen
        moreError = nil
        if items.isEmpty { state = .loading }
        do {
            let res = try await API.shared.orders(status: statusFilter, payment: paymentFilter, date: dateParam, search: searchParam, page: 1)
            guard myGen == gen else { return }
            if keepPages && page > 1 {
                // Перечитываем ВСЕ загруженные страницы: склейка «новая первая +
                // старый хвост» теряла строки на стыке, когда приходили новые
                // заказы, и держала устаревшие статусы ниже первой страницы.
                var all = res.items
                var more = res.hasMore ?? false
                var p = 1
                while p < page, more {
                    p += 1
                    let r = try await API.shared.orders(status: statusFilter, payment: paymentFilter, date: dateParam, search: searchParam, page: p)
                    guard myGen == gen else { return }
                    all += r.items
                    more = r.hasMore ?? false
                }
                var seen = Set<Int>()
                items = all.filter { seen.insert($0.orderId).inserted }
                page = p
                hasMore = more
            } else {
                page = 1
                items = res.items
                hasMore = res.hasMore ?? false
            }
            firstPageCount = res.items.count
            state = .loaded
            // Под фильтром «за день» (например, вчера) новых заказов на экране нет —
            // звонок нового заказа не гасим.
            // Под поиском — тоже: в выдаче поиска нового заказа может не быть.
            if dateFilter == nil && appliedSearch.isEmpty { NewOrderPoller.shared.acknowledge() }
        } catch is CancellationError {
        } catch {
            guard myGen == gen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(current: OrderSummary) async {
        guard hasMore, !loadingMore, current.orderId == items.last?.orderId else { return }
        loadingMore = true
        defer { loadingMore = false }
        let myGen = gen
        moreError = nil
        do {
            let res = try await API.shared.orders(status: statusFilter, payment: paymentFilter, date: dateParam, search: searchParam, page: page + 1)
            guard myGen == gen else { return }
            page += 1
            // Смещение страниц «плывёт», когда появляются новые записи: одна и та же
            // запись может прийти дважды, а дубли id ломают ForEach.
            let known = Set(items.map(\.orderId))
            items += res.items.filter { !known.contains($0.orderId) }
            hasMore = res.hasMore ?? false
        } catch is CancellationError {
        } catch {
            guard myGen == gen else { return }
            moreError = error.localizedDescription
        }
    }

    /// «Повторить» под лентой: та же догрузка с последней строки.
    func retryMore() async {
        guard let last = items.last else { return }
        await loadMoreIfNeeded(current: last)
    }
}

struct OrdersView: View {
    @EnvironmentObject var router: DeepLinkRouter
    @EnvironmentObject var session: Session
    @EnvironmentObject var poller: NewOrderPoller
    @StateObject private var vm = OrdersViewModel()
    @State private var pushedOrderId: Int?
    /// Деталь реально на экране — новый заказ меняем на месте (.id), без
    /// закрытия и повторного открытия.
    @State private var detailShown = false
    @State private var pushedChat = false
    /// Повторный push «чат» по заказу, деталь которого уже открыта из push:
    /// id тот же, экран не пересоздавался — и чат не открывался. Счётчик в .id.
    @State private var chatNonce = 0
    @State private var showDatePicker = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
                paymentChips
                List {
                    ForEach(vm.items) { order in
                        NavigationLink {
                            OrderDetailView(orderId: order.orderId, onChanged: { Task { await vm.reload(keepPages: true) } })
                        } label: {
                            OrderRow(order: order)
                        }
                        .listRowBackground(Brand.card)
                        .task { await vm.loadMoreIfNeeded(current: order) }
                    }
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
                           emptyIcon: vm.isSearching ? "magnifyingglass" : "bag", emptyTitle: emptyTitle,
                           emptySubtitle: emptySubtitle,
                           retry: { Task { await vm.reload() } })
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Заказы")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $vm.search, prompt: "Номер, телефон или имя")
            .toolbar {
                ToolbarItem(placement: .principal) { ShopSwitcherMenu() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showDatePicker = true } label: {
                        Image(systemName: vm.dateFilter == nil ? "calendar" : "calendar.badge.clock")
                    }
                    .accessibilityLabel("Заказы за день")
                }
            }
            .sheet(isPresented: $showDatePicker) {
                OrdersDaySheet(selected: vm.dateFilter) { vm.dateFilter = $0 }
            }
            // Возврат из заказа снова запускает .task — догруженные страницы не теряем.
            .task { await vm.reload(keepPages: true) }
            // Поллер нашёл новый заказ — открытый список обновляем сам: раньше
            // звенело, а заказа на экране не было до «потянуть вниз».
            .onChange(of: poller.newCount) { n in
                if n > 0 { Task { await vm.reload(keepPages: true) } }
            }
            // Push «новый заказ» на открытом экране: число новых могло остаться
            // прежним (предыдущий приняли на кассе), и заказа в ленте не было.
            .onChange(of: poller.pushArrivals) { _ in
                Task { await vm.reload(keepPages: true) }
            }
            // Возврат в приложение: за время в фоне заказы могли отменить, принять
            // с другого телефона или выдать. Счётчик новых при этом не менялся, и
            // в ленте до «потянуть вниз» висели старые статусы.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await vm.reload(keepPages: true) }
            }
            // iOS 16-совместимый пуш детали по deep link (navigationDestination(item:) — только iOS 17)
            .navigationDestination(isPresented: Binding(
                get: { pushedOrderId != nil },
                set: { if !$0 { pushedOrderId = nil } }
            )) {
                if let id = pushedOrderId {
                    // id: второй push при открытой детали показывал прежний заказ.
                    OrderDetailView(orderId: id, openChat: pushedChat,
                                    onChanged: { Task { await vm.reload(keepPages: true) } })
                        .id("\(id)#\(chatNonce)")
                        .onAppear { detailShown = true }
                        .onDisappear { detailShown = false }
                }
            }
            .onReceive(router.$openOrderId.receive(on: DispatchQueue.main)) { id in
                guard let id = id else { return }
                // Флаг чата забираем сразу: иначе следующий переход к этому
                // заказу сам открывал чат.
                pushedChat = router.openChatForOrderId == id
                if pushedChat && detailShown && pushedOrderId == id { chatNonce += 1 }
                router.openOrderId = nil
                router.openChatForOrderId = nil
                openPushed(id)
            }
        }
    }

    /// Под чипом «Активные» (он выбран по умолчанию) пустой экран писал
    /// «Заказов нет», хотя выполненные заказы есть — называем фильтр.
    private var emptyTitle: String {
        if vm.isSearching { return "По запросу «\(vm.appliedSearch)» заказов не найдено" }
        if vm.dateFilter != nil { return "За этот день заказов нет" + (vm.statusFilter == nil && vm.paymentFilter == nil ? "" : " с таким фильтром") }
        if vm.statusFilter == nil && vm.paymentFilter == nil { return "Заказов пока нет" }
        if vm.statusFilter == "active" && vm.paymentFilter == nil { return "Активных заказов нет" }
        return "Нет заказов с таким фильтром"
    }

    /// Новая организация (draft/review) клиентам не видна, и обещание «заказы
    /// появятся со звуковым сигналом» вводило в заблуждение — объясняем почему.
    private var emptySubtitle: String {
        if vm.isSearching {
            return vm.statusFilter == nil && vm.paymentFilter == nil && vm.dateFilter == nil
                ? "Проверьте номер, телефон или имя."
                : "Поиск учитывает фильтры сверху — выберите «Все», чтобы искать среди всех заказов."
        }
        if vm.dateFilter != nil || (vm.statusFilter != nil && vm.statusFilter != "active") || vm.paymentFilter != nil {
            return "Измените фильтры, чтобы увидеть другие заказы."
        }
        switch session.shopStatus {
        case "draft": return "Организация ещё не опубликована — клиенты её не видят. Заполните чек-лист на Дашборде и отправьте на проверку."
        case "review": return "Организация на проверке. Заказы начнут приходить после публикации."
        case "paused": return "Магазин на паузе — новые заказы не принимаются. Включить приём можно в разделе «Ещё»."
        default: return "Новые заказы появятся здесь со звуковым сигналом"
        }
    }

    /// Повторный тап по вкладке «Заказы» снимает деталь со стека, но сеттер
    /// Binding не вызывается: pushedOrderId оставался «висеть», и следующий push
    /// (или тот же заказ) ничего не открывал. Сначала сбрасываем, потом идём.
    private func openPushed(_ id: Int) {
        if pushedOrderId == nil || detailShown { pushedOrderId = id; return }
        pushedOrderId = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pushedOrderId = id }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(OrdersViewModel.statusChips, id: \.1) { value, title in
                    FilterChip(title: title, selected: vm.statusFilter == value) {
                        vm.statusFilter = value
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    /// Паритет с Android: оплата — вторым рядом чипов на виду (раньше — иконка
    /// в шапке, и включённый фильтр было не заметить). Первый чип — день.
    private var paymentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let d = vm.dateFilter {
                    FilterChip(title: "📅 " + Self.dayTitle(d) + "  ✕", selected: true) { vm.dateFilter = nil }
                } else {
                    FilterChip(title: "📅 Любой день", selected: false) { showDatePicker = true }
                }
                ForEach(Self.paymentChipValues, id: \.self) { value in
                    FilterChip(title: value.map { PaymentLabels.type($0) } ?? "Любая оплата",
                               selected: vm.paymentFilter == value) {
                        vm.paymentFilter = value
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private static let paymentChipValues: [String?] = [nil, "cash", "card_courier", "sbp", "online_card"]

    static func dayTitle(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Сегодня" }
        if cal.isDateInYesterday(d) { return "Вчера" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: Date()) ? "d MMM" : "d MMM yyyy"
        return f.string(from: d)
    }
}

/// Выбор дня оформления заказов (фильтр сервера ?date=).
struct OrdersDaySheet: View {
    let selected: Date?
    let onPick: (Date?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date

    init(selected: Date?, onPick: @escaping (Date?) -> Void) {
        self.selected = selected
        self.onPick = onPick
        _day = State(initialValue: selected ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("День", selection: $day, in: ...Date(), displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                    Button("Сегодня") { onPick(Calendar.current.startOfDay(for: Date())); dismiss() }
                    Button("Вчера") {
                        let y = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
                        onPick(Calendar.current.startOfDay(for: y)); dismiss()
                    }
                } footer: {
                    Text("Покажем заказы, оформленные в этот день. Остальные фильтры остаются.")
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Заказы за день")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if selected != nil {
                        Button("За всё время") { onPick(nil); dismiss() }
                    } else {
                        Button("Отмена") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onPick(day); dismiss() } label: { Text("Показать").bold() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct OrderRow: View {
    let order: OrderSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("№\(order.dailyNumber ?? order.orderId)")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Brand.text)
                // П-26.7: status_title сервера («Выполнен» у самовывоза вместо
                // «Доставлен» и т.п.); нет его — прежний словарь приложения.
                StatusBadge(text: order.statusText,
                            color: OrderStatuses.color(order.status))
                Spacer()
                Text(Money.rub(order.total))
                    .font(.headline)
                    .foregroundColor(Brand.text)
            }
            HStack(spacing: 8) {
                Label(PaymentLabels.delivery(order.deliveryType),
                      systemImage: order.deliveryType == "delivery" ? "bicycle" : "bag")
                Label(PaymentLabels.type(order.paymentType), systemImage: "creditcard")
                if order.paymentStatus == "paid" {
                    StatusBadge(text: "Оплачен", color: Brand.green)
                }
                // паритет с Android: возврат и «Наличные у курьера» видны прямо в ленте,
                // а не только в карточке заказа.
                if order.paymentStatus == "refunded" || order.paymentStatus == "awaiting_courier_cash" {
                    StatusBadge(text: PaymentLabels.status(order.paymentStatus), color: Brand.amber)
                }
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
            // Предзаказ видно в ленте: время «к которому» важнее времени оформления.
            // Крупнее и с плашкой: мелкую строку легко пропустить, а от этого
            // времени зависит, когда начинать готовить.
            if let pre = order.preorderAt, !pre.isEmpty {
                Label("Ко времени: " + DateFmt.short(pre), systemImage: "clock.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.amber)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Brand.amber.opacity(0.15))
                    .clipShape(Capsule())
            }
            // Бронь жилья видно сразу в списке: даты важнее способа получения,
            // которого у проживания нет.
            if let lg = order.lodging {
                Text("Бронь · " + lg.datesText + " · " + lg.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Brand.accent)
                    .lineLimit(1)
            }
            // паритет с Android: комментарий клиента к записи (client_comment) — мастер
            // видит его сразу в ленте.
            if let cc = order.clientComment?.trimmingCharacters(in: .whitespacesAndNewlines), !cc.isEmpty {
                Text("💬 " + cc)
                    .font(.caption)
                    .foregroundColor(Brand.text)
                    .lineLimit(2)
            }
            HStack {
                // паритет с Android: имя и телефон клиента одной строкой.
                let who = joinedNonEmpty([order.client, order.clientPhone], separator: " · ")
                if !who.isEmpty {
                    Text(who).font(.caption).foregroundColor(Brand.muted).lineLimit(1)
                }
                Spacer()
                Text(DateFmt.short(order.createdAt))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 4)
    }
}
