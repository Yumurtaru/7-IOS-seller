import SwiftUI
import Combine

// ============================================================================
//  Корневая навигация: TabView, разделы зависят от shops.type активного
//  магазина (shop | cafe | service | lodging). Тип берётся из
//  GET /api/seller/settings — /api/seller/shops его не отдаёт (факт контракта).
// ============================================================================

struct MainTabView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: DeepLinkRouter

    /// Теги вкладок, которые реально нарисованы при текущих правах.
    /// Нужен, чтобы переход по push/deep-link не оставил пустой экран.
    private var availableTabs: Set<String> {
        var t: Set<String> = ["dashboard", "more"]
        if session.can("orders") { t.insert("orders") }
        if session.can("products") { t.insert("products") }
        if session.can("finance") { t.insert("wallet") }
        return t
    }

    @EnvironmentObject var poller: NewOrderPoller
    @State private var tab = "dashboard"
    /// Непрочитанные ответы поддержки площадки — в бейдже вкладки «Ещё».
    @ObservedObject private var supportUnread = ShopSupportUnreadStore.shared

    /// Бейдж «Ещё»: возвраты на рассмотрении + непрочитанное от поддержки.
    private var moreBadge: Int {
        (session.activeShop?.pendingReturns ?? 0) + supportUnread.unread
    }

    private var isService: Bool { session.shopType == "service" }
    /// Жильё: вместо «Заказы/Товары» — «Брони/Объекты». Раздел доступен только
    /// организациям этого формата: на другой тип сервер отвечает 403.
    private var isLodging: Bool { session.shopType == "lodging" }

    var body: some View {
        TabView(selection: $tab) {
            DashboardView()
                .tabItem { Label("Дашборд", systemImage: "chart.bar.fill") }
                .tag("dashboard")

            // Вкладки тоже под правами: сотрудник не должен видеть раздел,
            // в который его всё равно не пустят (сервер ответит 403).
            // Дашборд остаётся всегда — иначе у кассира без прав была бы
            // пустая панель вкладок.
            if isLodging {
                if session.can("orders") {
                    LodgingBookingsView()
                        .tabItem { Label("Брони", systemImage: "calendar.badge.clock") }
                        .tag("orders")
                        .badge(poller.newCount)
                }
                if session.can("products") {
                    LodgingUnitsView()
                        .tabItem { Label("Объекты", systemImage: "bed.double.fill") }
                        .tag("products")
                }
            } else if isService {
                if session.can("orders") {
                    BookingsView()
                        .tabItem { Label("Записи", systemImage: "calendar.badge.clock") }
                        .tag("orders")
                        .badge(poller.newCount)
                }
                if session.can("products") {
                    ServicesHubView()
                        .tabItem { Label("Услуги", systemImage: "scissors") }
                        .tag("products")
                }
            } else {
                if session.can("orders") {
                    OrdersView()
                        .tabItem { Label("Заказы", systemImage: "bag.fill") }
                        .tag("orders")
                        .badge(poller.newCount)
                }
                if session.can("products") {
                    ProductsView()
                        .tabItem { Label(session.shopType == "cafe" ? "Меню" : "Товары", systemImage: "square.grid.2x2.fill") }
                        .tag("products")
                }
            }

            // RBAC (Фаза 2.5): финансы видят только владелец/роли с правом finance.
            if session.can("finance") {
                WalletView()
                    .tabItem { Label("Кошелёк", systemImage: "rublesign.circle.fill") }
                    .tag("wallet")
            }

            MoreView()
                .tabItem { Label("Ещё", systemImage: "ellipsis.circle.fill") }
                .tag("more")
                // А66: плюс непрочитанные ответы поддержки площадки («Техподдержка»).
                .badge(moreBadge)
        }
        .id(session.reloadKey)   // смена магазина → полная перезагрузка разделов
        // После смены магазина (или новых прав) открытой вкладки может не
        // стать: TabView без выбранного содержимого — белый экран без выхода.
        .onChange(of: session.reloadKey) { _ in
            if !availableTabs.contains(tab) { tab = "dashboard" }
        }
        // Права обновил bootstrap без пересоздания вкладок — открытой вкладки может не стать.
        .onChange(of: availableTabs) { tabs in
            if !tabs.contains(tab) { tab = "dashboard" }
        }
        // onReceive, а не onChange: значение, выставленное до появления экрана
        // (холодный старт из push), onChange не видел.
        .onReceive(router.$requestedTab.receive(on: DispatchQueue.main)) { newTab in
            // Переключаемся только на СУЩЕСТВУЮЩУЮ вкладку. Вкладки «Кошелёк» и
            // «Заказы» рисуются по правам, и присвоение их тега сотруднику без
            // права оставляло TabView без выбранного содержимого: белый экран,
            // ни одна вкладка не подсвечена, выхода нет. Сюда приводили и
            // карточка баланса на дашборде, и push «новый заказ», и deep-link.
            if let t = newTab {
                if availableTabs.contains(t) {
                    tab = t
                    // Деталь заказа открывает только экран «Заказы»; вкладки записей
                    // и броней её не забирают — id остался бы и открылся в другом магазине.
                    if t == "orders" && (isService || isLodging) {
                        router.openOrderId = nil
                        if isLodging { router.openChatForOrderId = nil }
                    }
                } else {
                    // Вкладки нет — гасим и «полезную нагрузку» перехода. Иначе
                    // id заказа из push оставался в роутере навсегда и всплывал
                    // позже (смена магазина пересоздаёт дерево, подписчик
                    // получает текущее значение и открывает чужой заказ).
                    tab = "dashboard"
                    router.openOrderId = nil
                    router.openChatForOrderId = nil
                    router.openReturnId = nil
                }
                router.requestedTab = nil
            }
        }
        .task {
            poller.start()
            // А66: бейдж «Техподдержка» — при запуске и после смены магазина (не чаще раза в минуту).
            Task { @MainActor in ShopSupportUnreadStore.shared.refreshIfStale() }
        }
        // Бейдж возвратов на «Ещё» берётся из списка магазинов, а его
        // перечитывал только экран «Возвраты»: новый возврат, пришедший, пока
        // приложение было свёрнуто, не появлялся в бейдже до перезапуска.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await session.refreshShops() }
        }
        // П-52: «Вышла новая версия» — только на сводке и не поверх входа (этот экран
        // есть только после входа). Окно — отдельным модификатором (AppUpdateViews.swift).
        // Во время смены магазина — тоже нет: дерево экранов пересоздаётся, окно мешало бы.
        // (Открытый в сводке экран отсюда не виден — стек навигации внутри DashboardView.)
        .modifier(SoftUpdatePrompt(isMainScreen: tab == "dashboard" && !session.switching))
        .overlay(alignment: .top) {
            if let err = session.bootError {
                // Паритет с Android («Магазины не загрузились — нажмите, чтобы
                // повторить»): касание не только прячет ошибку, но и повторяет загрузку
                // магазинов и прав — раньше помогал лишь перезапуск приложения.
                InlineErrorBar(message: err)
                    .onTapGesture {
                        session.bootError = nil
                        Task { await session.bootstrap() }
                    }
            }
        }
    }
}

/// Переключатель организаций в шапке (владелец нескольких точек).
/// GET /api/seller/shops → POST /api/seller/switch-shop → перезагрузка данных.
struct ShopSwitcherMenu: View {
    @EnvironmentObject var session: Session
    /// Чек-лист публикации по метке «Не опубликован ›» (паритет с Android).
    @State private var showPublish = false

    var body: some View {
        VStack(spacing: 1) {
            switcher
            // Паритет с Android: состояние организации видно в шапке КАЖДОГО
            // раздела, а не только бейджем «На паузе» на Дашборде.
            if let label = stateLabel {
                if canPublish {
                    Button { showPublish = true } label: {
                        Text(label + " ›")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(stateColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label + ", открыть чек-лист публикации")
                } else {
                    Text(label)
                        .font(.caption2.weight(.bold))
                        .foregroundColor(stateColor)
                }
            }
        }
        .sheet(isPresented: $showPublish) { ShopPublishSheet() }
    }

    /// Те же подписи, что в шапке Android (Nav.kt): статусы панели на сервере
    /// active / paused / draft / review (pending, blocked — на всякий случай).
    private var stateLabel: String? {
        switch session.shopStatus {
        case "paused": return "Пауза"
        case "review", "pending": return "На проверке"
        case "draft": return "Не опубликован"
        case "blocked": return "Заблокирован"
        default: return nil
        }
    }

    private var stateColor: Color {
        switch session.shopStatus {
        case "paused", "review", "pending": return Brand.amber
        default: return Brand.red
        }
    }

    /// Новая организация или на проверке: по метке — чек-лист и «Отправить на
    /// проверку». Без права «Настройки» сервер ответит 403 — метка просто текст.
    private var canPublish: Bool {
        (session.shopStatus == "draft" || session.shopStatus == "review") && session.can("settings")
    }

    @ViewBuilder
    private var switcher: some View {
        if session.shops.count > 1 {
            Menu {
                ForEach(session.shops) { shop in
                    Button {
                        Task { await session.switchShop(to: shop.shopId) }
                    } label: {
                        HStack {
                            Text(shopTitle(shop))
                            if shop.shopId == session.activeShopId {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "building.2")
                    Text(session.activeShop?.name ?? session.shopName)
                        .lineLimit(1)
                    // Переключение идёт — видно ожидание; второй выбор раньше
                    // молча отбрасывался, и казалось, что меню не работает.
                    if session.switching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                }
                .font(.subheadline.weight(.semibold))
            }
            .disabled(session.switching)
        } else {
            // Сотруднику подписываем роль: иначе непонятно, почему часть
            // разделов отсутствует. У владельца всё как было — одно название.
            VStack(spacing: 0) {
                Text(session.activeShop?.name ?? session.shopName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.muted)
                    .lineLimit(1)
                // Три строки в шапке не помещаются: при метке состояния роль не пишем.
                if !session.isOwner && stateLabel == nil {
                    Text([session.staffName, session.roleName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundColor(Brand.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    private func shopTitle(_ shop: ShopSummary) -> String {
        var t = shop.name ?? "Организация"
        // Паритет с Android (П-27.13): тип точки — владельцу нескольких точек видно,
        // где магазин, а где кафе или жильё. Старый сервер type не шлёт — подписи нет.
        switch shop.type {
        case "shop": t += " · магазин"
        case "cafe": t += " · кафе"
        case "service": t += " · услуги"
        case "lodging": t += " · жильё"
        default: break
        }
        if let city = shop.city, !city.isEmpty {
            t += " · \(city)"
        }
        // Паритет с Android: в списке организаций видно состояние точки и её
        // новые заказы (draft/review/paused — статусы панели на сервере).
        switch shop.status {
        case "paused": t += " · на паузе"
        case "review": t += " · на проверке"
        case "draft": t += " · не опубликован"
        default: break
        }
        if let n = shop.newOrders, n > 0 {
            t += " · новых: \(n)"
        }
        return t
    }
}
