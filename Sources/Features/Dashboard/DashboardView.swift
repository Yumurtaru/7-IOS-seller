import SwiftUI
import Charts
import Combine

// ============================================================================
//  Дашборд — GET /api/seller/dashboard?period=today|week|month
//  Метрики, график 14 дней (Swift Charts), активные заказы, баланс, счётчики.
// ============================================================================

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var data: DashboardData?
    @Published var period = "today" {
        didSet { if period != oldValue { Task { await load() } } }
    }
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    /// Когда начали последнюю загрузку (см. reloadForNewOrders).
    private var lastLoadStart = Date.distantPast

    func load() async {
        lastLoadStart = Date()
        loadGen += 1
        let myGen = loadGen
        if data == nil { state = .loading }
        do {
            let fresh = try await API.shared.dashboard(period: period)
            guard myGen == loadGen else { return }
            data = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
        await loadPublish()
    }

    /// Счётчик новых заказов вырос. При запуске, возврате из фона и смене
    /// магазина первый ответ поллера приходит, пока дашборд сам грузится (или
    /// только что загрузился): уходил второй одинаковый GET dashboard. Загрузка,
    /// начатая меньше 3 с назад, уже видит эти заказы — повтор не шлём.
    func reloadForNewOrders() async {
        guard Date().timeIntervalSince(lastLoadStart) > 3 else { return }
        await load()
    }

    // ── Публикация новой организации (GET /api/seller/publish-status) ──────
    // Новая организация (draft) клиентам не видна, а дашборд об этом молчал:
    // продавец не знал, что заполнить и куда нажать. Показываем чек-лист
    // сервера и кнопку «Отправить на проверку» (POST publish-request).
    @Published var publish: ShopPublishStatus?
    @Published var publishBusy = false
    @Published var publishError: String?

    func loadPublish() async {
        // Без права «Настройки» сервер ответит 403 — не спрашиваем зря.
        guard Session.shared.can("settings") else { return }
        // Уже опубликована — не спрашиваем на каждом новом заказе (смена
        // магазина пересоздаёт экран, и для нового магазина спросим заново).
        if let s = publish?.status, s == "active" || s == "paused" { return }
        // Старый сервер без ручки или сбой — карточку просто не показываем.
        if let p = try? await API.shared.get("api/seller/publish-status", as: ShopPublishStatus.self) {
            publish = p
        }
    }

    /// true — заявка ушла (статус стал review).
    func submitPublish() async -> Bool {
        guard !publishBusy else { return false }
        publishBusy = true
        defer { publishBusy = false }
        publishError = nil
        var ok = false
        do {
            _ = try await API.shared.post("api/seller/publish-request", as: BoolAck.self)
            ok = true
        } catch is CancellationError {
        } catch {
            publishError = error.localizedDescription
        }
        // И после обрыва: заявка могла дойти — статус покажет сервер.
        await loadPublish()
        if publish?.inReview == 1 { publishError = nil; ok = true }
        return ok
    }
}

/// Ответ GET /api/seller/publish-status (seller_settings.php, shopReadiness).
struct ShopPublishStatus: Decodable {
    var status: String?
    var statusLabel: String?
    @LenientInt var canSubmit: Int?
    @LenientInt var inReview: Int?
    @LenientInt var done: Int?
    @LenientInt var total: Int?
    var checklist: [ShopPublishCheck]?
    var publishNote: String?

    enum CodingKeys: String, CodingKey {
        case status, done, total, checklist
        case statusLabel = "status_label"
        case canSubmit = "can_submit"
        case inReview = "in_review"
        case publishNote = "publish_note"
    }
}

struct ShopPublishCheck: Decodable {
    var key: String?
    var label: String?
    var hint: String?
    @LenientBool var ok: Bool?
}

struct DashboardView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: DeepLinkRouter
    @EnvironmentObject var poller: NewOrderPoller
    @StateObject private var vm = DashboardViewModel()
    /// А82: блоки «Оплаты» и «Контроль потерь» — свои запросы, свой счётчик.
    @StateObject private var pro = SalesDashboardModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Период", selection: $vm.period) {
                        Text("Сегодня").tag("today")
                        Text("Неделя").tag("week")
                        Text("Месяц").tag("month")
                    }
                    .pickerStyle(.segmented)

                    // Черновик / на проверке: что сделать, чтобы клиенты увидели организацию.
                    if let p = vm.publish, p.status == "draft" || p.status == "review" {
                        publishCard(p)
                    }

                    if let d = vm.data {
                        // Блоки, закрытые правами, не рисуем вовсе: нули в них
                        // неотличимы от настоящих цифр (см. DashboardData.blocks).
                        let seeAnalytics = d.blocks?["analytics"] ?? true
                        let seeFinance = d.blocks?["finance"] ?? true
                        let seeOrders = d.blocks?["orders"] ?? true
                        if seeAnalytics { metricsGrid(d) }
                        // АY (сайт А616): что сделать сейчас; старый сервер — блока нет.
                        if let att = d.attention, !attentionRows(att).isEmpty { attentionCard(att) }
                        if seeFinance { walletCard(d) }
                        // А82: оплаты сегодня по способам и контроль потерь за 7 дней.
                        // Без права (403) или на старом сервере (404) блоков нет.
                        SalesDashboardBlocks(model: pro)
                        if seeAnalytics { chartCard(d) }
                        countersCard(d)
                        // Без права «Заказы» сервер кладёт пустой список, и
                        // карточка читалась как «активных заказов нет».
                        if seeOrders { activeOrdersCard(d) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Дашборд")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // «Пауза / На проверке / Не опубликован» — метка под названием в
                // ShopSwitcherMenu (на всех вкладках); отдельный бейдж паузы не нужен.
                ToolbarItem(placement: .principal) { ShopSwitcherMenu() }
            }
            .refreshable {
                await vm.load()
                // А82: блоки — принудительно, но не держим ими крутилку «потянуть вниз».
                Task { await pro.load(force: true) }
            }
            .listState(vm.state, isEmpty: vm.data == nil,
                       emptyIcon: "chart.bar", emptyTitle: "Нет данных",
                       retry: { Task { await vm.load() } })
            .task { await vm.load() }
            // А82: не чаще раза в 5 минут (см. SalesDashboardModel.load).
            .task { await pro.load() }
            // Звенит новый заказ — «Активные заказы» и цифры обновляем сами,
            // как в списке заказов: раньше дашборд молчал до «потянуть вниз».
            .onChange(of: poller.newCount) { n in
                if n > 0 { Task { await vm.reloadForNewOrders() } }
            }
            // Вернулись в приложение из фона (утром, после звонка): цифры
            // «Сегодня» и активные заказы оставались вчерашними до «потянуть вниз».
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await vm.load() }
                Task { await pro.load() }
            }
        }
    }

    // ── Публикация (draft/review) ────────────────────────────────────────────
    private func publishCard(_ p: ShopPublishStatus) -> some View {
        let inReview = p.inReview == 1 || p.status == "review"
        let items = p.checklist ?? []
        let fallback = inReview ? "На проверке у администратора" : "Не опубликована — заполняется"
        return SectionCard(title: "Организация не видна клиентам") {
            Text(p.statusLabel ?? fallback)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.amber)
            Text(inReview
                 ? "Администратор площадки проверяет организацию. Клиенты увидят её сразу после публикации."
                 : "Заполните пункты ниже и отправьте организацию на проверку администратору.")
                .font(.caption).foregroundColor(Brand.muted)
            if let note = p.publishNote, !note.isEmpty {
                Text("Замечание администратора: " + note)
                    .font(.caption).foregroundColor(Brand.red)
            }
            if !inReview && !items.isEmpty {
                Text("Готово \(p.done ?? 0) из \(p.total ?? items.count)")
                    .font(.caption.weight(.semibold)).foregroundColor(Brand.text)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    publishRow(item)
                }
            }
            if !inReview && p.canSubmit == 1 && session.can("settings") {
                Button {
                    // Ушло — перечитываем /me: «Ещё» и «Настройки» покажут «на проверке».
                    Task { if await vm.submitPublish() { await session.bootstrap() } }
                } label: {
                    HStack {
                        Spacer()
                        if vm.publishBusy { ProgressView() } else { Text("Отправить на проверку").bold() }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .disabled(vm.publishBusy)
            }
            if let err = vm.publishError {
                Text(err).font(.caption).foregroundColor(Brand.red)
            }
        }
    }

    private func publishRow(_ item: ShopPublishCheck) -> some View {
        let ok = item.ok == true
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundColor(ok ? Brand.green : Brand.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label ?? item.key ?? "—")
                    .font(.subheadline).foregroundColor(Brand.text)
                if !ok, let hint = item.hint, !hint.isEmpty {
                    Text(hint).font(.caption).foregroundColor(Brand.muted)
                }
            }
        }
    }

    // ── Метрики периода ──────────────────────────────────────────────────────
    private func metricsGrid(_ d: DashboardData) -> some View {
        // АY: prev — тот же отрезок прошлого периода (сайт А616); нет — без строки тренда.
        let p = d.prev
        return HStack(spacing: 10) {
            metric("Выручка", Money.rub(d.revenue)) {
                TrendText(current: d.revenue, previous: p?.revenue, format: { Money.rub($0) })
            }
            metric("Заказы", "\(d.orders ?? 0)") {
                TrendText(current: Decimal(d.orders ?? 0), previous: p?.orders.map { Decimal($0) },
                          format: { "\($0)" })
            }
            metric("Ср. чек", Money.rub(d.avgCheck)) {
                TrendText(current: d.avgCheck, previous: p?.avgCheck, format: { Money.rub($0) })
            }
        }
    }

    private func metric<Trend: View>(_ title: String, _ value: String,
                                     @ViewBuilder trend: () -> Trend) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .foregroundColor(Brand.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundColor(Brand.muted)
            trend()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // ── Требует внимания (АY, сайт А616) ─────────────────────────────────────
    /// Строка блока: текст и куда ведёт касание.
    private enum AttentionTarget { case orders, reviews, wallet }
    private struct AttentionRow: Identifiable {
        let id: String
        let text: String
        let target: AttentionTarget
    }

    /// Только ненулевые; null (нет права) — строки нет.
    private func attentionRows(_ a: DashboardAttention) -> [AttentionRow] {
        var rows: [AttentionRow] = []
        if let n = a.lateNew, n > 0 {
            rows.append(AttentionRow(id: "late_new", text: "Новые без ответа дольше нормы: \(n)", target: .orders))
        }
        if let n = a.stuck, n > 0 {
            rows.append(AttentionRow(id: "stuck", text: "Зависшие заказы: \(n)", target: .orders))
        }
        if let n = a.preordersSoon, n > 0 {
            rows.append(AttentionRow(id: "preorders_soon", text: "Предзаказы скоро: \(n)", target: .orders))
        }
        if let n = a.reviewsNoReply, n > 0 {
            rows.append(AttentionRow(id: "reviews_no_reply", text: "Отзывы без ответа: \(n)", target: .reviews))
        }
        if let n = a.walletLow, n > 0 {
            rows.append(AttentionRow(id: "wallet_low", text: "Мало денег на кошельке", target: .wallet))
        }
        return rows
    }

    private func attentionCard(_ a: DashboardAttention) -> some View {
        SectionCard(title: "Требует внимания") {
            let rows = attentionRows(a)
            ForEach(rows) { row in
                attentionLink(row)
                if row.id != rows.last?.id {
                    Divider().overlay(Brand.border)
                }
            }
        }
    }

    @ViewBuilder
    private func attentionLink(_ row: AttentionRow) -> some View {
        switch row.target {
        case .reviews where session.can("reviews"):
            NavigationLink { ReviewsView() } label: { attentionLabel(row.text, tappable: true) }
                .buttonStyle(.plain)
        case .orders where session.can("orders"):
            Button { router.requestedTab = "orders" } label: { attentionLabel(row.text, tappable: true) }
                .buttonStyle(.plain)
        case .wallet where session.can("finance"):
            Button { router.requestedTab = "wallet" } label: { attentionLabel(row.text, tappable: true) }
                .buttonStyle(.plain)
        default:
            attentionLabel(row.text, tappable: false)
        }
    }

    private func attentionLabel(_ text: String, tappable: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(Brand.amber)
            Text(text).font(.subheadline).foregroundColor(Brand.text)
            Spacer()
            if tappable { Image(systemName: "chevron.right").foregroundColor(Brand.muted) }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    // ── Кошелёк ──────────────────────────────────────────────────────────────
    private func walletCard(_ d: DashboardData) -> some View {
        Button { router.requestedTab = "wallet" } label: {
            SectionCard {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Баланс кошелька").font(.caption).foregroundColor(Brand.muted)
                        Text(Money.rub(d.wallet))
                            .font(.title3.weight(.bold))
                            .foregroundColor((d.wallet ?? 0) < 500 ? Brand.red : Brand.green)
                    }
                    Spacer()
                    if let pending = d.pendingCommission, pending > 0 {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Комиссия к списанию").font(.caption).foregroundColor(Brand.muted)
                            Text(Money.rub(pending)).font(.subheadline.weight(.semibold)).foregroundColor(Brand.amber)
                        }
                    }
                    Image(systemName: "chevron.right").foregroundColor(Brand.muted)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // ── График 14 дней ───────────────────────────────────────────────────────
    private func chartCard(_ d: DashboardData) -> some View {
        SectionCard(title: "Выручка за 14 дней") {
            let points = d.chart ?? []
            if points.isEmpty {
                Text("Пока нет заказов за период")
                    .font(.subheadline).foregroundColor(Brand.muted)
            } else {
                Chart(points) { p in
                    BarMark(
                        x: .value("День", DateFmt.dayMonth(p.d)),   // подпись оси — без года
                        y: .value("Выручка", NSDecimalNumber(decimal: p.rev ?? 0).doubleValue)
                    )
                    .foregroundStyle(Brand.accent.gradient)
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let s = value.as(String.self) {
                                Text(s).font(.system(size: 8)).foregroundColor(Brand.muted)
                            }
                        }
                    }
                }
                .frame(height: 160)
            }
        }
    }

    // ── Счётчики ────────────────────────────────────────────────────────────
    private func countersCard(_ d: DashboardData) -> some View {
        // Без права «Возвраты» пункта в «Ещё» нет: касание уводило на вкладку,
        // где возвратов не найти. Такому сотруднику счётчик не кнопка.
        let openReturns: (() -> Void)? = session.can("returns") ? { router.requestedTab = "more" } : nil
        return HStack(spacing: 10) {
            // «Отзывы» и «Отклики» выглядели как «Возвраты», но касание молча
            // ничего не делало. Открываем их экраны — по тем же правам, что в «Ещё».
            if session.can("reviews") {
                NavigationLink { ReviewsView() } label: { counterTile("Отзывы", d.newReviews ?? 0, "star.bubble") }
                    .buttonStyle(.plain)
            } else {
                counterTile("Отзывы", d.newReviews ?? 0, "star.bubble")
            }
            counter("Возвраты", d.pendingReturns ?? 0, "arrow.uturn.left.circle", action: openReturns)
            if session.can("employees") {
                NavigationLink { VacanciesView() } label: {
                    counterTile("Отклики", d.newApplications ?? 0, "person.crop.circle.badge.questionmark")
                }
                .buttonStyle(.plain)
            } else {
                counterTile("Отклики", d.newApplications ?? 0, "person.crop.circle.badge.questionmark")
            }
        }
    }

    private func counter(_ title: String, _ value: Int, _ icon: String, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: {
            counterTile(title, value, icon)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private func counterTile(_ title: String, _ value: Int, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(value > 0 ? Brand.accent : Brand.muted)
            Text("\(value)")
                .font(.headline)
                .foregroundColor(Brand.text)
            Text(title).font(.caption2).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func activeSubtitle(_ order: OrderSummary) -> String {
        joinedNonEmpty([order.client ?? "Клиент", DateFmt.short(order.createdAt)], separator: " · ")
    }

    // ── Активные заказы ──────────────────────────────────────────────────────
    private func activeOrdersCard(_ d: DashboardData) -> some View {
        SectionCard(title: "Активные заказы") {
            let active = d.active ?? []
            if active.isEmpty {
                Text("Нет активных заказов")
                    .font(.subheadline).foregroundColor(Brand.muted)
            } else {
                ForEach(active) { order in
                    Button {
                        router.requestedTab = "orders"
                        router.openOrderId = order.orderId
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 10) {
                                Text("№\(order.dailyNumber ?? order.orderId)")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundColor(Brand.text)
                                // П-26.7: подпись статуса сервера, если он её прислал.
                                StatusBadge(text: order.statusText,
                                            color: OrderStatuses.color(order.status))
                                Spacer()
                                Text(Money.rub(order.total))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(Brand.text)
                            }
                            // паритет с Android: клиент и время заказа (client, created_at
                            // из dashboard.active) — без них строки «№12 Новый» не различить.
                            Text(activeSubtitle(order))
                                .font(.caption).foregroundColor(Brand.muted).lineLimit(1)
                            // П-26.3: предзаказ «к времени» и «сдача с …» прямо на сводке —
                            // заказ на завтра не должен выглядеть заказом «прямо сейчас».
                            if let pre = order.preorderAt, !pre.isEmpty {
                                Label("Ко времени: " + DateFmt.short(pre), systemImage: "clock.fill")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(Brand.amber)
                                    .lineLimit(1)
                            }
                            // Сдача — только у оплаты наличными: сайт хранит change_from и
                            // при оплате картой. Пока dashboard.active не отдаёт payment_type
                            // (заявка П-30), строки нет.
                            if order.paymentType == "cash",
                               let note = order.paymentNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                                Text("Сдача с " + note)
                                    .font(.caption).foregroundColor(Brand.muted).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    if order.orderId != active.last?.orderId {
                        Divider().overlay(Brand.border)
                    }
                }
            }
        }
    }
}
