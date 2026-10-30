import SwiftUI
import Combine

// ============================================================================
//  «Ещё»: возвраты, стоп-лист, статус магазина (active/paused),
//  настройки уведомлений по категориям, аккаунт, выход.
// ============================================================================

struct MoreView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: DeepLinkRouter
    @ObservedObject private var push = PushManager.shared
    /// А66: непрочитанные ответы поддержки площадки (бейдж «Техподдержка»).
    @ObservedObject private var supportUnread = ShopSupportUnreadStore.shared
    /// А78: есть ли «Курьеры Yumurta» на сервере (старый сервер — пункта нет).
    @ObservedObject private var pool = PoolFeature.shared
    /// А82: есть ли на сервере «Отчёт по продажам» и «Контроль потерь».
    @ObservedObject private var salesFeature = SalesReportFeature.shared
    /// А99: есть ли на сервере «Переоценка» (старый сервер — 404, пункта нет).
    @ObservedObject private var revalFeature = RevalFeature.shared
    @State private var pushReturns = false
    /// Раздел, открытый из push (router.openSection): "security" | "reservations".
    @State private var pushSection: String?
    @State private var statusError: String?
    @State private var statusBusy = false
    @State private var showLogoutConfirm = false
    @State private var pushDiag: String?
    @State private var pushDiagRunning = false

    var body: some View {
        NavigationStack {
            List {
                shopSection
                supportSection
                lodgingSection
                sectionsSection
                clientsSection
                marketingSection
                staffSection
                analyticsSection
                deliverySection
                manageSection
                settingsSection
                notificationsSection
                accountSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Ещё")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { ShopSwitcherMenu() } }
            .navigationDestination(isPresented: $pushReturns) { ReturnsView() }
            .navigationDestination(isPresented: Binding(
                get: { pushSection != nil },
                set: { if !$0 { pushSection = nil } }
            )) {
                if pushSection == "security" {
                    SecurityView()
                } else if pushSection == "reservations" {
                    ReservationsView()
                } else if pushSection == "support" {
                    ShopSupportView()
                } else if pushSection == "reviews" {
                    // П-28.2: push «новый отзыв».
                    ReviewsView()
                } else if pushSection == "lodging_long" {
                    // П-28.1: push «заявка на длительную аренду».
                    LodgingLongView()
                } else if pushSection == "pool" {
                    // А78: push pool_call без заказа (вызов вручную, расчёты).
                    PoolView()
                }
            }
            // А78: пункт «Курьеры Yumurta» — после ответа сервера, для каждой организации.
            .task(id: session.activeShopId) { await pool.refresh(shopId: session.activeShopId) }
            // А82: пункты отчёта и контроля потерь — после ответа сервера (старый — 404, пунктов нет).
            .task(id: session.activeShopId) { await salesFeature.refresh(shopId: session.activeShopId) }
            // А99: пункт «Переоценка» — после ответа сервера, для каждой организации.
            .task(id: session.activeShopId) { await revalFeature.refresh(shopId: session.activeShopId) }
            .onAppear {
                push.refreshAuthorizationStatus()
                // А66: бейдж «Техподдержка» (сам не спрашивает чаще раза в минуту).
                supportUnread.refreshIfStale()
            }
            .sheet(isPresented: Binding(get: { pushDiag != nil },
                                        set: { if !$0 { pushDiag = nil } })) {
                NavigationStack {
                    ScrollView {
                        Text(pushDiag ?? "")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(Brand.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .background(Brand.bg.ignoresSafeArea())
                    .navigationTitle("Проверка уведомлений")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Готово") { pushDiag = nil }
                        }
                    }
                }
            }
            .onReceive(router.$openReturnId.receive(on: DispatchQueue.main)) { id in
                guard id != nil else { return }
                // Без права «Возвраты» push вёл на экран 403.
                if session.can("returns") { openReturns() } else { router.openReturnId = nil }
            }
            // Push «тревога безопасности» / «бронь стола» — тот же раздел, что в
            // меню, и под теми же условиями (иначе экран 403 или пустой).
            .onReceive(router.$openSection.receive(on: DispatchQueue.main)) { s in
                guard let s else { return }
                router.openSection = nil
                // А66: чат поддержки уже открыт — второй экран поверх не кладём,
                // просто сразу забираем новые сообщения.
                if s == "support", let live = ShopSupportViewModel.liveOnScreen {
                    live.pollNow()
                    return
                }
                guard sectionAllowed(s) else {
                    // А78: раздел недоступен — цель push не оставляем «на потом»,
                    // иначе следующий вход в раздел открыл бы старую карточку.
                    if s == "pool" { router.openPoolCallId = nil }
                    return
                }
                openSection(s)
            }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) {
                    // Черновики новых товаров — не для следующего, кто войдёт на этом телефоне.
                    ProductDraftStore.clearAll()
                    session.signOut()
                }
            }
        }
    }

    /// Повторный тап по «Ещё» снимает «Возвраты» со стека, а pushReturns
    /// остаётся true: следующий push о возврате ничего не открывал. Если флаг
    /// уже стоит и открытый экран «Возвраты» не забрал id — открываем заново.
    private func sectionAllowed(_ s: String) -> Bool {
        switch s {
        case "security": return session.can("security")
        case "reservations": return session.shopType == "cafe" && session.can("orders")
        // Переписка с поддержкой площадки открыта любому сотруднику с входом в панель.
        case "support": return true
        // П-28.1/2: те же условия, что у пунктов меню «Отзывы» и «Длительная аренда».
        case "reviews": return session.can("reviews")
        case "lodging_long": return session.shopType == "lodging" && session.can("orders")
        // А78: «Курьеры Yumurta» — право «Заказы», как у пункта меню.
        case "pool": return session.can("orders")
        default: return false
        }
    }

    /// Флаг мог остаться от снятого повторным тапом экрана — сначала сбрасываем.
    private func openSection(_ s: String) {
        if pushSection == nil { pushSection = s; return }
        pushSection = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pushSection = s }
    }

    private func openReturns() {
        if !pushReturns { pushReturns = true; return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard router.openReturnId != nil else { return }   // экран открыт и сам перешёл
            pushReturns = false
            try? await Task.sleep(nanoseconds: 50_000_000)
            pushReturns = true
        }
    }

    // ── Магазин ─────────────────────────────────────────────────────────────
    private var shopSection: some View {
        Section("Организация") {
            HStack(spacing: 12) {
                RemoteImage(path: session.activeShop?.logo, size: 44, cornerRadius: 10,
                            placeholderIcon: "building.2")
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.activeShop?.name ?? session.shopName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.text)
                    Text(shopTypeLabel)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
            // Черновик и организация на проверке (draft/review) ещё не опубликованы:
            // пауза для них сервером запрещена (settings/status → 422), а переключатель
            // показывал «Магазин на паузе» и отвечал ошибкой. Пишем, как есть.
            if session.can("settings") && (session.shopStatus == "draft" || session.shopStatus == "review") {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.shopStatus == "review" ? "Организация на проверке" : "Организация ещё не опубликована")
                        .font(.subheadline.weight(.semibold))
                    // Новый продавец без компьютера упирался в «кабинет на сайте».
                    // Чек-лист и «Отправить на проверку» есть на Дашборде.
                    Text(session.shopStatus == "review"
                         ? "Клиенты её пока не видят. Администратор проверит и опубликует — придёт уведомление."
                         : "Клиенты её пока не видят. Что заполнить и кнопка «Отправить на проверку» — на Дашборде.")
                        .font(.caption).foregroundColor(Brand.muted)
                    if session.shopStatus == "draft" {
                        Button("Открыть Дашборд") { router.requestedTab = "dashboard" }
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Brand.accent)
                            .buttonStyle(.borderless)
                            .padding(.top, 4)
                    }
                }
            } else if session.can("settings") {
                Toggle(isOn: Binding(
                    get: { session.shopStatus == "active" },
                    set: { newValue in
                        // Быстрое вкл/выкл слало два запроса, приходивших в разном порядке.
                        guard !statusBusy else { return }
                        statusBusy = true
                        Task {
                            defer { statusBusy = false }
                            do {
                                try await session.setShopStatus(newValue ? "active" : "paused")
                                statusError = nil
                            } catch {
                                statusError = error.localizedDescription
                            }
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.shopStatus == "active" ? "Магазин открыт" : "Магазин на паузе")
                            .font(.subheadline.weight(.semibold))
                        Text("На паузе клиенты не могут оформлять заказы")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .tint(Brand.green)
                .disabled(statusBusy)
                if let err = statusError {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
        }
        .listRowBackground(Brand.card)
    }

    // ── Техподдержка площадки (А66) ─────────────────────────────────────────
    // Переписка организации с поддержкой Yumurta — как вкладка «Техподдержка»
    // веб-кабинета. Без проверки прав: сервер пускает любого сотрудника панели.
    private var supportSection: some View {
        Section {
            NavigationLink {
                ShopSupportView()
            } label: {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Техподдержка")
                            Text("Связаться с поддержкой площадки")
                                .font(.caption)
                                .foregroundColor(Brand.muted)
                        }
                    } icon: {
                        Image(systemName: "bubble.left.and.bubble.right")
                    }
                    Spacer()
                    if supportUnread.unread > 0 {
                        StatusBadge(text: "\(supportUnread.unread)", color: Brand.accent)
                    }
                }
            }
        }
        .listRowBackground(Brand.card)
    }

    private var shopTypeLabel: String {
        switch session.shopType {
        case "cafe": return "Кафе / ресторан"
        case "service": return "Услуги"
        case "lodging": return "Жильё"
        default: return "Магазин"
        }
    }

    /// Есть ли у формата товары и склад. У услуг и жилья их нет: раньше
    /// проверялось только `!= "service"`, и кабинет жилья показывал
    /// «Категории», «Модификаторы» и документы склада, где всё пусто.
    private var hasGoods: Bool {
        session.shopType != "service" && session.shopType != "lodging"
    }

    /// Разделы формата «Жильё». Отдельным блоком, потому что права разные:
    /// заявки — «Заказы», налог — «Настройки» (так же размечено на сервере).
    @ViewBuilder
    private var lodgingSection: some View {
        if session.shopType == "lodging" {
            Section("Жильё") {
                if session.can("orders") {
                    NavigationLink { LodgingLongView() } label: {
                        Label("Длительная аренда", systemImage: "key")
                    }
                }
                if session.can("settings") {
                    NavigationLink { LodgingTaxView() } label: {
                        Label("Туристический налог", systemImage: "percent")
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Разделы ─────────────────────────────────────────────────────────────
    private var sectionsSection: some View {
        Section("Разделы") {
            if session.can("returns") {
                NavigationLink {
                    ReturnsView()
                } label: {
                    HStack {
                        Label("Возвраты", systemImage: "arrow.uturn.left.circle")
                        Spacer()
                        if let n = session.activeShop?.pendingReturns, n > 0 {
                            StatusBadge(text: "\(n)", color: Brand.accent)
                        }
                    }
                }
            }
            if hasGoods && session.can("products") {
                NavigationLink {
                    StopListView()
                } label: {
                    Label("Стоп-лист", systemImage: "nosign")
                }
            }
            // Продажи с кассы: срез по orders.source = 'pos'. Право отдельное —
            // «Отчёты кассы» (pos_reports), а не общая аналитика.
            if session.can("pos_reports") {
                NavigationLink {
                    PosSalesView()
                } label: {
                    Label("Продажи с кассы", systemImage: "creditcard")
                }
            }
            // Каталог: категории, наборы, модификаторы, артикулы. Всё под
            // правом «Товары» — так же размечено на сервере.
            // У кабинета услуг товаров нет, поэтому раздел не показываем.
            if hasGoods && session.can("products") {
                NavigationLink { CategoriesView() } label: {
                    Label("Категории", systemImage: "folder")
                }
                NavigationLink { CombosView() } label: {
                    Label("Наборы", systemImage: "square.stack.3d.up")
                }
                NavigationLink { ModifiersView() } label: {
                    Label("Модификаторы", systemImage: "slider.horizontal.3")
                }
                NavigationLink { ArticlesView() } label: {
                    Label("Артикулы и штрихкоды", systemImage: "barcode")
                }
            }
            // Склад: документы, ингредиенты, тех. карты. Права разные —
            // documents / suppliers / products, как размечено на сервере.
            // Ручки этой группы идут через warehouseShop(): у магазина без
            // склада они отвечают «Склад недоступен для этого типа магазина».
            if hasGoods {
                if session.can("documents") {
                    NavigationLink { DocumentsView() } label: {
                        Label("Документы склада", systemImage: "doc.text")
                    }
                    // А99: «Переоценка» (наценки категорий, журнал цен) — как в кабинете, после
                    // «Документов». Право то же — «Документы склада»; на старом сервере пункта нет.
                    if revalFeature.available {
                        NavigationLink { RevaluationsView() } label: {
                            Label("Переоценка", systemImage: "tag")
                        }
                    }
                }
                // Сервер поменял разметку (StaffAccess::pathPerms()): ingredients —
                // «Склад» (warehouse), tech-cards — «Товары». Пункт «Ингредиенты»
                // по праву «Товары» вёл повара в 403 (так же исправлено на Android).
                if session.shopType == "cafe" && session.can("warehouse") {
                    NavigationLink { IngredientsView() } label: {
                        Label("Ингредиенты", systemImage: "leaf")
                    }
                }
                if session.shopType == "cafe" && session.can("products") {
                    NavigationLink { TechCardsView() } label: {
                        Label("Тех. карты", systemImage: "doc.plaintext")
                    }
                }
            }
            // Листы ожидания — это очередь КЛИЕНТОВ за товаром, поэтому право
            // «Клиенты», а не «Товары» (так же размечено на сервере).
            if session.can("customers") {
                NavigationLink {
                    WaitlistView()
                } label: {
                    Label("Листы ожидания", systemImage: "hourglass")
                }
            }
            // Брони столов есть только у ресторана: у магазина и услуг
            // раздел пустой по определению. Право — «Заказы»: бронь это
            // ежедневная операционка хостес, а не настройка зала (создание
            // самих столов на сервере закрыто правом «Настройки»).
            if session.shopType == "cafe" && session.can("orders") {
                NavigationLink {
                    ReservationsView()
                } label: {
                    Label("Брони столов", systemImage: "calendar.badge.clock")
                }
            }
            Link(destination: URL(string: "https://yumurta.ru/seller/dashboard.php")!) {
                Label("Полный веб-кабинет", systemImage: "safari")
            }
        }
        .listRowBackground(Brand.card)
    }

    // ── Клиенты и отзывы (Фаза 2) ────────────────────────────────────────────
    @ViewBuilder
    private var clientsSection: some View {
        if session.can("reviews") || session.can("customers") {
            Section("Клиенты и отзывы") {
                if session.can("reviews") {
                    NavigationLink { ReviewsView() } label: {
                        Label("Отзывы", systemImage: "star.bubble")
                    }
                }
                if session.can("customers") {
                    NavigationLink { ClientsView() } label: {
                        Label("Клиенты", systemImage: "person.2")
                    }
                    NavigationLink { GiftCardsView() } label: {
                        Label("Подарочные карты", systemImage: "giftcard")
                    }
                    // Кешбэк баллами — право «Клиенты» (loyalty => customers
                    // в карте сервера), а не «Акции».
                    NavigationLink { LoyaltyView() } label: {
                        Label("Программа лояльности", systemImage: "gift")
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Маркетинг (Фаза 2) ───────────────────────────────────────────────────
    @ViewBuilder
    private var marketingSection: some View {
        if session.can("promotions") {
            Section("Маркетинг") {
                NavigationLink { PromotionsView() } label: {
                    Label("Акции", systemImage: "megaphone")
                }
                NavigationLink { PromoCodesView() } label: {
                    Label("Промокоды", systemImage: "ticket")
                }
                NavigationLink { BoostView() } label: {
                    Label("Продвижение (буст)", systemImage: "chart.line.uptrend.xyaxis")
                }
                NavigationLink { ShopQRView() } label: {
                    Label("QR витрины", systemImage: "qrcode")
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Персонал (Фаза 2) ────────────────────────────────────────────────────
    @ViewBuilder
    private var staffSection: some View {
        if session.can("employees") {
            Section("Персонал") {
                NavigationLink { EmployeesView() } label: {
                    Label("Сотрудники", systemImage: "person.3")
                }
                NavigationLink { RolesView() } label: {
                    Label("Роли и права", systemImage: "lock.shield")
                }
                NavigationLink { ShiftsView() } label: {
                    Label("Смены", systemImage: "clock.arrow.circlepath")
                }
                NavigationLink { VacanciesView() } label: {
                    Label("Вакансии и отклики", systemImage: "person.badge.plus")
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Аналитика, склад, закупки (Фаза 2–3) ─────────────────────────────────
    // Права здесь РАЗНЫЕ: аналитика — analytics, склад — warehouse, поставщики
    // и закупки — suppliers. Раньше вся группа висела на «Аналитике», и
    // кладовщик без неё не видел даже собственный склад.
    @ViewBuilder
    private var analyticsSection: some View {
        let hasWarehouse = hasGoods && session.can("warehouse")
        let hasSuppliers = hasGoods && session.can("suppliers")
        if session.can("analytics") || hasWarehouse || hasSuppliers {
            Section("Аналитика и склад") {
                if session.can("analytics") {
                    // А82: наличные, карта, QR, онлайн; дни, часы, каналы, кассы; Excel.
                    // Выше «Аналитики» — как в кабинете и в Android.
                    if salesFeature.sales {
                        NavigationLink { SalesReportView() } label: {
                            Label("Отчёт по продажам", systemImage: "banknote")
                        }
                    }
                    NavigationLink { AnalyticsView() } label: {
                        Label("Аналитика", systemImage: "chart.pie")
                    }
                }
                if hasWarehouse {
                    NavigationLink { StockView() } label: {
                        Label("Склад", systemImage: "shippingbox")
                    }
                    NavigationLink { ExpiryView() } label: {
                        Label("Сроки годности", systemImage: "calendar.badge.exclamationmark")
                    }
                    NavigationLink { WarehouseReportsView() } label: {
                        Label("Отчёты по складу", systemImage: "chart.bar.doc.horizontal")
                    }
                    NavigationLink { WarehouseSettingsView() } label: {
                        Label("Настройки склада", systemImage: "slider.horizontal.3")
                    }
                }
                if hasSuppliers {
                    NavigationLink { SuppliersView() } label: {
                        Label("Поставщики", systemImage: "truck.box")
                    }
                    NavigationLink { PurchaseOrdersView() } label: {
                        Label("Закупки", systemImage: "cart.badge.plus")
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Доставка и курьеры ───────────────────────────────────────────────────
    // Курьеры закрыты своим правом «Курьеры» (couriers), а зоны и способы
    // доставки — «Настройками»: это разные права в каталоге сервера.
    @ViewBuilder
    private var deliverySection: some View {
        // А78: «Курьеры Yumurta» (курьеры площадки) — право «Заказы»: вызвать
        // курьера к заказу — работа с заказами (StaffAccess: pool => orders).
        let showPool = session.can("orders") && pool.available
        if hasGoods && (session.can("couriers") || session.can("settings") || showPool) {
            Section("Доставка") {
                if session.can("settings") {
                    NavigationLink { DeliverySettingsView() } label: {
                        Label("Зоны и способы доставки", systemImage: "map")
                    }
                }
                if session.can("couriers") {
                    NavigationLink { CouriersView() } label: {
                        Label("Курьеры", systemImage: "bicycle")
                    }
                }
                if showPool {
                    NavigationLink { PoolView() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Курьеры Yumurta")
                                Text("Вызвать курьера площадки, расчёты")
                                    .font(.caption)
                                    .foregroundColor(Brand.muted)
                            }
                        } icon: {
                            Image(systemName: "car")
                        }
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Выгрузки и тип организации ───────────────────────────────────────────
    // Экспорт раньше жил внутри «Аналитики», хотя ручки закрыты другими правами
    // (товары, заказы, финансы): кладовщик без аналитики не видел выгрузку
    // остатков, которая ему как раз разрешена.
    @ViewBuilder
    private var manageSection: some View {
        // Сервер проверяет выгрузку по её СОДЕРЖИМОМУ (StaffAccess::pathPerm:
        // export/clients — «Клиенты», export/orders — «Заказы», export/stock и
        // ingredients — «Склад», остальное — «Товары»), кошелёк — «Финансы».
        // Экран выгрузок сам прячет недоступные файлы; по одному праву «Товары»
        // кладовщик и менеджер по клиентам свои файлы не находили.
        let canExport = session.can("products") || session.can("orders") || session.can("customers")
            || session.can("warehouse") || session.can("finance")
        if canExport || session.can("settings") {
            Section("Данные организации") {
                if canExport {
                    NavigationLink { ExportsView() } label: {
                        Label("Выгрузки и обмен", systemImage: "square.and.arrow.up")
                    }
                }
                // Загрузка заполненного файла — право «Товары»: импорт заводит
                // и правит позиции каталога.
                if session.can("products") {
                    NavigationLink { ImportView() } label: {
                        Label("Импорт из файла", systemImage: "square.and.arrow.down")
                    }
                }
                if session.can("settings") {
                    NavigationLink { OrgTypeView() } label: {
                        Label("Тип и режим организации", systemImage: "building.2")
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Настройки и безопасность ─────────────────────────────────────────────
    // «Безопасность» — ОТДЕЛЬНОЕ право security в каталоге сервера (журнал
    // действий и сессии). Раньше пункт висел на «Настройках»: аудитор с одним
    // правом security до журнала не добирался, а настройщик без него получал
    // 403 внутри экрана.
    @ViewBuilder
    private var settingsSection: some View {
        if session.can("settings") || session.can("security") {
            Section("Настройки") {
                if session.can("settings") {
                    NavigationLink { ShopSettingsView() } label: {
                        Label("Настройки магазина", systemImage: "gearshape")
                    }
                    NavigationLink { KycView() } label: {
                        Label("Готовность организации", systemImage: "checklist")
                    }
                }
                // Столы и станции есть только у ресторана: у магазина и услуг
                // разделы пустые по определению. Право — «Настройки», как на
                // сервере (создание столов и касс это настройка зала).
                if session.shopType == "cafe" && session.can("settings") {
                    NavigationLink { TablesView() } label: {
                        Label("Столы и QR-меню", systemImage: "tablecells")
                    }
                    NavigationLink { StationsView() } label: {
                        Label("Станции и кассы", systemImage: "desktopcomputer")
                    }
                }
                if session.can("security") {
                    NavigationLink { SecurityView() } label: {
                        Label("Безопасность", systemImage: "checkmark.shield")
                    }
                    // А82: индекс риска, подозрительные операции, сотрудники и кассы.
                    if salesFeature.loss {
                        NavigationLink { LossControlView() } label: {
                            Label("Контроль потерь", systemImage: "exclamationmark.shield")
                        }
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Уведомления (локальные тумблеры категорий) ───────────────────────────
    private var notificationsSection: some View {
        Section("Уведомления") {
            // Сначала разрешение системы: без него тумблеры ниже ничего не решают.
            pushPermissionRow
            pushDeliveryRow

            ForEach(PushManager.Category.allCases, id: \.self) { cat in
                Toggle(cat.title, isOn: Binding(
                    get: { PushManager.shared.isEnabled(cat) },
                    set: { PushManager.shared.setEnabled(cat, $0) }
                ))
                .tint(Brand.green)
                .disabled(!push.isSystemAllowed)
                .opacity(push.isSystemAllowed ? 1 : 0.45)
            }
        }
        .listRowBackground(Brand.card)
    }

    /// Состояние доставки: есть ли токен от Apple, принял ли его сервер, и
    /// живая проверка всей цепочки одним нажатием. Без этого «не приходит»
    /// не отличить от «Apple не выдала токен» и «сервер не обновлён».
    @ViewBuilder
    private var pushDeliveryRow: some View {
        if push.isSystemAllowed {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: push.deviceToken != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(push.deviceToken != nil ? Brand.green : Brand.red)
                    Text(push.deviceToken != nil ? "Токен устройства получен" : "Токен устройства не получен")
                        .font(.caption).foregroundColor(Brand.muted)
                }
                HStack(spacing: 6) {
                    Image(systemName: push.serverRegistered ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(push.serverRegistered ? Brand.green : Brand.red)
                    Text(push.serverRegistered ? "Токен зарегистрирован на сервере" : "Сервер токен не принял")
                        .font(.caption).foregroundColor(Brand.muted)
                }
                if let err = push.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(Brand.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    pushDiagRunning = true
                    Task {
                        let text = await push.runSelfTest()
                        await MainActor.run {
                            pushDiagRunning = false
                            pushDiag = text
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if pushDiagRunning { ProgressView().controlSize(.small) }
                        Text(pushDiagRunning ? "Проверяем…" : "Проверить уведомления")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.accent)
                }
                .disabled(pushDiagRunning)
            }
            .padding(.vertical, 4)
        }
    }

    /// Статус разрешения iOS + действие. Отдельной строкой, потому что это
    /// первая причина «уведомления не приходят»: пока разрешения нет, приложение
    /// не появляется даже в «Настройки → Уведомления».
    @ViewBuilder
    private var pushPermissionRow: some View {
        switch push.authorizationStatus {
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Label("Уведомления запрещены", systemImage: "bell.slash.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Text("Включите их в настройках iPhone — повторно система не спросит.")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                Button("Открыть настройки iPhone") { push.openSystemSettings() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.accent)
            }
            .padding(.vertical, 4)
        case .authorized, .provisional, .ephemeral:
            HStack {
                Label("Разрешены", systemImage: "bell.badge.fill")
                    .font(.subheadline)
                    .foregroundColor(Brand.text)
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundColor(Brand.green)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("Разрешение ещё не запрошено")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Button("Разрешить уведомления") { push.requestAuthorization() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.accent)
            }
            .padding(.vertical, 4)
        }
    }

    // ── Аккаунт ──────────────────────────────────────────────────────────────
    private var accountSection: some View {
        Section("Аккаунт") {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.user?.name ?? "Продавец")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                if let email = session.user?.email, !email.isEmpty {
                    Text(email)
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
            }
            // Версия и сборка — их первым делом спрашивает поддержка.
            NavigationLink { AboutAppView() } label: {
                Label("О приложении", systemImage: "info.circle")
            }
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        .listRowBackground(Brand.card)
    }
}
