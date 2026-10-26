import SwiftUI
import Combine

// ============================================================================
//  Заказы — GET /api/seller/orders?status=&payment=&page= (по 20 на страницу,
//  has_more от сервера). Фильтры-чипы по статусу и оплате, deep link в деталь.
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
    private var page = 1
    private var hasMore = false
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
            let res = try await API.shared.orders(status: statusFilter, payment: paymentFilter, page: 1)
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
                    let r = try await API.shared.orders(status: statusFilter, payment: paymentFilter, page: p)
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
            NewOrderPoller.shared.acknowledge()
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
            let res = try await API.shared.orders(status: statusFilter, payment: paymentFilter, page: page + 1)
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
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
                           emptyIcon: "bag", emptyTitle: emptyTitle,
                           emptySubtitle: emptySubtitle,
                           retry: { Task { await vm.reload() } })
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Заказы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { ShopSwitcherMenu() }
                ToolbarItem(placement: .navigationBarTrailing) { paymentMenu }
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
        if vm.statusFilter == nil && vm.paymentFilter == nil { return "Заказов пока нет" }
        if vm.statusFilter == "active" && vm.paymentFilter == nil { return "Активных заказов нет" }
        return "Нет заказов с таким фильтром"
    }

    /// Новая организация (draft/review) клиентам не видна, и обещание «заказы
    /// появятся со звуковым сигналом» вводило в заблуждение — объясняем почему.
    private var emptySubtitle: String {
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

    private var paymentMenu: some View {
        Menu {
            // Галочка у выбранного способа: раньше видно было только «залитую»
            // иконку, и какой фильтр включён (почему заказов мало) — не понять.
            paymentOption("Все способы оплаты", nil)
            paymentOption("Наличные", "cash")
            paymentOption("Карта курьеру", "card_courier")
            paymentOption("СБП", "sbp")
            paymentOption("Картой онлайн", "online_card")
        } label: {
            Image(systemName: vm.paymentFilter == nil ? "creditcard" : "creditcard.fill")
        }
    }

    private func paymentOption(_ title: String, _ value: String?) -> some View {
        Button { vm.paymentFilter = value } label: {
            if vm.paymentFilter == value {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
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
