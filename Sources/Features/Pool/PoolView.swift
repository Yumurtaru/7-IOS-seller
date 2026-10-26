import SwiftUI
import Combine
import UIKit

// ============================================================================
//  Раздел «Курьеры Yumurta» (волна А78) — как seller/pool.php на сайте:
//  «Вызовы» (активные/завершённые, вызов вручную для заказа по телефону),
//  «Расчёты» с курьерами (получили деньги, отдали за доставку, подтвердить
//  «курьер сдал деньги», оплата по QR, история) и «QR для оплаты» у двери.
//  Ручки /api/v1/seller/pool/*, право «Заказы»; QR — ещё и «Настройки».
// ============================================================================

/// Есть ли раздел на сервере. Старый сервер на /quote отвечает «не найдено» —
/// пункт меню не показываем. Проверка — раз в 10 минут на организацию.
/// Класс без @MainActor (как ShopSupportUnreadStore и PushManager): его берут
/// через @ObservedObject … = .shared в свойствах экранов; состояние меняется
/// только в методах @MainActor.
final class PoolFeature: ObservableObject {
    static let shared = PoolFeature()
    @Published private(set) var available = false

    private var checkedShop: Int?
    private var checkedAt = Date.distantPast
    /// Организация, проверка которой сейчас идёт. Проверку другой организации
    /// (переключили магазин посреди запроса) не пропускаем.
    private var checkingShop: Int?

    private init() {}

    @MainActor
    func refresh(shopId: Int?) async {
        guard let sid = shopId, Session.shared.can("orders") else { available = false; return }
        if checkedShop != sid { available = false }
        if checkedShop == sid && Date().timeIntervalSince(checkedAt) < 600 { return }
        guard checkingShop != sid else { return }
        checkingShop = sid
        defer { if checkingShop == sid { checkingShop = nil } }
        do {
            _ = try await API.shared.poolQuote()
            // Пока шёл запрос, переключили организацию — ответ чужой, не пишем.
            guard Session.shared.activeShopId == sid else { return }
            available = true
            checkedShop = sid
            checkedAt = Date()
        } catch is CancellationError {
        } catch let e as APIError {
            guard Session.shared.activeShopId == sid else { return }
            switch e {
            // Ответ сервера «нет такой ручки» / «раздел недоступен» — скрываем.
            case .server, .decoding:
                available = false
                checkedShop = sid
                checkedAt = Date()
            // Сеть мигнула — оставляем как было и спросим в следующий раз.
            default: break
            }
        } catch {}
    }
}

// ── Вызовы ──────────────────────────────────────────────────────────────────
@MainActor
final class PoolCallsViewModel: ObservableObject {
    @Published var calls: [PoolCall] = []
    @Published var state: LoadState = .idle
    @Published var filter = "active"
    @Published var canLoadMore = false
    @Published var loadingMore = false

    private var page = 1
    private var gen = 0
    private static let perPage = 30   // CourierPool::sellerCalls, $per = 30

    var hasLive: Bool { calls.contains { $0.isLive } }
    var onFirstPage: Bool { page == 1 }

    func load(silent: Bool = false) async {
        gen += 1
        let my = gen
        if !silent || calls.isEmpty { state = .loading }
        do {
            let list = try await API.shared.poolCalls(status: filter, page: 1)
            guard my == gen else { return }
            calls = list
            page = 1
            canLoadMore = list.count >= Self.perPage
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard my == gen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard canLoadMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let my = gen
        do {
            let list = try await API.shared.poolCalls(status: filter, page: page + 1)
            guard my == gen else { return }
            page += 1
            let known = Set(calls.compactMap { $0.id })
            calls += list.filter { !known.contains($0.callId) }
            canLoadMore = list.count >= Self.perPage
        } catch {
            canLoadMore = false
        }
    }

    func replace(_ c: PoolCall) {
        if let i = calls.firstIndex(where: { $0.callId == c.callId }) { calls[i] = c }
    }
}

// ── Расчёты ─────────────────────────────────────────────────────────────────
@MainActor
final class PoolMoneyViewModel: ObservableObject {
    @Published var couriers: [PoolCourierBalance] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false

    /// Итоги — те же, что meta сервера (couriers_owe_total, shop_owes_total).
    var couriersOweTotal: Decimal { couriers.reduce(Decimal(0)) { $0 + ($1.courierOwes ?? 0) } }
    var shopOwesTotal: Decimal { couriers.reduce(Decimal(0)) { $0 + ($1.shopOwes ?? 0) } }

    func load() async {
        if couriers.isEmpty { state = .loading }
        do {
            couriers = try await API.shared.poolCouriers()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func decide(entryId: Int, approve: Bool) async {
        await act(approve ? "Приём денег записан" : "Курьер уведомлён") {
            _ = try await API.shared.poolDecide(entryId: entryId, approve: approve)
            return nil
        }
    }

    func confirmQr(callId: Int, received: Bool) async {
        await act(received ? "Оплата подтверждена" : "Курьер уведомлён") {
            let c = try await API.shared.poolConfirmQr(id: callId, received: received)
            // А87: повторное «Не пришла» — already: true, это успех (второго push нет).
            return received ? nil : PoolFmt.qrNoMessage(c)
        }
    }

    /// op возвращает текст по ответу сервера (nil — ok).
    private func act(_ ok: String, _ op: () async throws -> String?) async {
        guard !busy else { return }
        busy = true
        error = nil
        notice = nil
        defer { busy = false }
        do {
            notice = try await op() ?? ok
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }
}

struct PoolView: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var router: DeepLinkRouter
    @Environment(\.scenePhase) private var scenePhase

    private enum Tab: String, Hashable { case calls, money, qr }

    @State private var tab: Tab = .calls
    @StateObject private var callsVM = PoolCallsViewModel()
    @StateObject private var moneyVM = PoolMoneyViewModel()
    @State private var openCallId: Int?
    @State private var showManual = false
    @State private var settle: PoolSettleTarget?
    @State private var askQrNo: Int?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: $tab) {
                Text("Вызовы").tag(Tab.calls)
                Text("Расчёты").tag(Tab.money)
                if session.can("settings") { Text("QR").tag(Tab.qr) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            switch tab {
            case .calls: callsTab
            case .money: moneyTab
            case .qr: PoolQrPanel()
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Курьеры Yumurta")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(
            get: { openCallId != nil },
            set: { if !$0 { openCallId = nil } }
        )) {
            PoolCallDetailView(callId: openCallId ?? 0)
        }
        .sheet(isPresented: $showManual) {
            PoolCallSheet(orderId: nil) { call in
                callsVM.filter = "active"
                Task { await callsVM.load() }
                if call.callId > 0 { openCallId = call.callId }
            }
        }
        .sheet(item: $settle) { t in
            PoolSettleSheet(target: t) { Task { await moneyVM.load() } }
        }
        // Push pool_call: вызов без заказа — карточка вызова; расчёт — «Расчёты».
        // Забираем только при появлении: push всегда открывает новый экран
        // раздела (MoreView → openSection), уже открытый не должен уйти в карточку.
        .onAppear {
            guard let id = router.openPoolCallId else { return }
            router.openPoolCallId = nil
            if id > 0 { openCallId = id } else { tab = .money }
        }
        .onReceive(NotificationCenter.default.publisher(for: .poolCallPush)) { _ in
            if tab == .money { Task { await moneyVM.load() } }
            else if tab == .calls && callsVM.onFirstPage { Task { await callsVM.load(silent: true) } }
        }
        .task(id: callsPollKey) { await pollCalls() }
    }

    // ── Вызовы ───────────────────────────────────────────────────────────────
    private var callsTab: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach([("active", "Активные"), ("closed", "Завершённые"), ("all", "Все")], id: \.0) { f in
                        FilterChip(title: f.1, selected: callsVM.filter == f.0) {
                            guard callsVM.filter != f.0 else { return }
                            callsVM.filter = f.0
                            Task { await callsVM.load() }
                        }
                    }
                    Spacer(minLength: 0)
                }
                if session.can("orders") {
                    Button {
                        showManual = true
                    } label: {
                        Label("Вызвать к заказу по телефону", systemImage: "phone.arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.borderless)
                    .background(Brand.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if callsVM.calls.isEmpty, callsVM.state == .loaded {
                    EmptyState(icon: "car",
                               title: callsVM.filter == "active" ? "Сейчас вызовов нет" : "Вызовов пока не было",
                               subtitle: "Курьера к заказу с сайта вызывают из карточки заказа. Заказ, принятый по телефону, — кнопкой выше.")
                }
                ForEach(callsVM.calls) { c in
                    NavigationLink {
                        PoolCallDetailView(callId: c.callId, initial: c)
                    } label: {
                        PoolCallRow(call: c)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if c.callId == callsVM.calls.last?.callId { Task { await callsVM.loadMore() } }
                    }
                }
                if callsVM.loadingMore { ProgressView().padding() }
            }
            .padding(16)
        }
        .refreshable { await callsVM.load(silent: true) }
        // Пустой загруженный список — своя заглушка выше (с подсказкой про кнопку);
        // оверлей — только загрузка и ошибка, чтобы две заглушки не накладывались.
        .listState(callsVM.state, isEmpty: callsVM.calls.isEmpty && callsVM.state != .loaded,
                   emptyIcon: "car", emptyTitle: "Вызовов нет",
                   retry: { Task { await callsVM.load() } })
        .task { if callsVM.state == .idle { await callsVM.load() } }
    }

    /// Опрос раз в 15 с — только на вкладке вызовов, пока есть живые вызовы,
    /// приложение на экране и открыта первая страница (дальние не сбрасываем).
    private var callsPollKey: String {
        "\(tab.rawValue)-\(callsVM.filter)-\(callsVM.hasLive)-\(scenePhase == .active)"
    }

    private func pollCalls() async {
        guard tab == .calls, callsVM.hasLive, scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { return }
            if callsVM.onFirstPage { await callsVM.load(silent: true) }
        }
    }

    // ── Расчёты ──────────────────────────────────────────────────────────────
    private var moneyTab: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                Text("Все деньги клиента — ваши: курьер привозит наличные в заведение, оплату по QR вы получаете сами. За доставку курьеру платите вы. Сумму двигает тот, кто получает деньги: «Получили от курьера» записывается сразу, «Отдали за доставку» подтверждает курьер.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // А88: статья базы знаний о расчётах с курьерами.
                HelpLink(path: "help/kurery-yumurta-raschety")
                if !moneyVM.couriers.isEmpty {
                    SectionCard {
                        InfoRow(label: "Курьеры должны вам", value: Money.rub(moneyVM.couriersOweTotal))
                        InfoRow(label: "Вы должны курьерам", value: Money.rub(moneyVM.shopOwesTotal))
                    }
                }
                if let e = moneyVM.error {
                    Text(e).font(.footnote).foregroundColor(Brand.red).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let n = moneyVM.notice {
                    Text(n).font(.footnote.weight(.semibold)).foregroundColor(Brand.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if moneyVM.couriers.isEmpty, moneyVM.state == .loaded {
                    EmptyState(icon: "wallet.pass", title: "Расчётов пока нет")
                }
                ForEach(moneyVM.couriers) { c in courierCard(c) }
            }
            .padding(16)
        }
        .refreshable { await moneyVM.load() }
        .listState(moneyVM.state, isEmpty: moneyVM.couriers.isEmpty && moneyVM.state != .loaded,
                   emptyIcon: "wallet.pass", emptyTitle: "Расчётов пока нет",
                   retry: { Task { await moneyVM.load() } })
        // Один запрос на каждое открытие вкладки (свежие расчёты).
        .task { await moneyVM.load() }
        .alert("Оплата по QR не пришла?", isPresented: Binding(get: { askQrNo != nil }, set: { if !$0 { askQrNo = nil } })) {
            Button("Не пришла", role: .destructive) {
                if let id = askQrNo { Task { await moneyVM.confirmQr(callId: id, received: false) } }
            }
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text("Сумма останется долгом курьера, курьеру придёт уведомление.")
        }
    }

    private func courierCard(_ c: PoolCourierBalance) -> some View {
        let owes = (c.courierOwes ?? 0) > 0
        let shopOwes = (c.shopOwes ?? 0) > 0
        let canWork = session.can("orders")
        return SectionCard {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(c.name ?? "Курьер").font(.headline).foregroundColor(Brand.text)
                        if let r = PoolFmt.rating(c.rating) { Text(r).font(.caption).foregroundColor(Brand.amber) }
                    }
                    if let car = c.car, !car.isEmpty { Text(car).font(.subheadline).foregroundColor(Brand.text) }
                    if let phone = c.phone, !phone.isEmpty, let url = PoolFmt.telURL(phone) {
                        Link(destination: url) { Label(phone, systemImage: "phone.fill").font(.subheadline) }
                            .foregroundColor(Brand.green)
                    }
                    Text("Доставок у вас: \(c.deliveriesHere ?? 0)"
                         + (c.status != nil && c.status != "approved" ? " · " + PoolFmt.courierStatus(c.status) : ""))
                        .font(.caption).foregroundColor(Brand.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if owes {
                        Text("Курьер должен вам").font(.caption).foregroundColor(Brand.muted)
                        Text(Money.rub(c.courierOwes)).font(.title3.weight(.bold)).foregroundColor(Brand.text)
                        if let s = c.since, !s.isEmpty {
                            Text("с " + PoolFmt.short(s)).font(.caption2).foregroundColor(Brand.muted)
                        }
                    } else if shopOwes {
                        Text("Вы должны курьеру").font(.caption).foregroundColor(Brand.muted)
                        Text(Money.rub(c.shopOwes)).font(.title3.weight(.bold)).foregroundColor(Brand.text)
                    } else {
                        Text("В расчёте").font(.subheadline).foregroundColor(Brand.green)
                    }
                }
            }
            ForEach(c.qrPending ?? [], id: \.self) { q in
                VStack(alignment: .leading, spacing: 6) {
                    // А87: тексты — как в веб-кабинете (seller-pool.js). Старый сервер полей
                    // missing / counts_as_debt / debt_at не шлёт — «… — проверьте в банке.», как раньше.
                    Text("Оплата по QR " + Money.rub(q.amount) + " (доставка №\(q.callId ?? 0), "
                         + PoolFmt.short(q.deliveredAt) + ") — " + qrStateText(q))
                        .font(q.missing == true ? .footnote.weight(.semibold) : .footnote).foregroundColor(Brand.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = qrDebtNote(q) {
                        Text(note.text).font(.footnote.weight(.semibold)).foregroundColor(note.overdue ? Brand.red : Brand.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if canWork, let cid = q.callId, cid > 0 {
                        HStack(spacing: 8) {
                            smallButton("Пришла", primary: true) { Task { await moneyVM.confirmQr(callId: cid, received: true) } }
                            // Повтор «Не пришла» ничего не меняет, а курьеру уходит ещё один push.
                            if q.missing != true {
                                smallButton("Не пришла", primary: false) { askQrNo = cid }
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.amber.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            ForEach((c.pending ?? []).filter { $0.needsMyDecision == true }) { e in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Курьер пишет, что отдал вам " + Money.rub(abs(e.amount ?? 0)) + " (" + PoolFmt.short(e.createdAt) + ").")
                        .font(.footnote).foregroundColor(Brand.text)
                    if canWork, let eid = e.id {
                        HStack(spacing: 8) {
                            smallButton("Получили", primary: true) { Task { await moneyVM.decide(entryId: eid, approve: true) } }
                            smallButton("Не получали", primary: false) { Task { await moneyVM.decide(entryId: eid, approve: false) } }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            ForEach((c.pending ?? []).filter { $0.needsMyDecision != true }) { e in
                Text("Ждёт подтверждения курьера: отдали " + Money.rub(e.amount))
                    .font(.caption).foregroundColor(Brand.muted)
            }
            if canWork {
                HStack(spacing: 8) {
                    smallButton("Получили деньги", primary: false) {
                        settle = PoolSettleTarget(courierId: c.id, name: c.name ?? "Курьер", kind: "cash_received",
                                                  suggested: owes ? c.courierOwes : nil)
                    }
                    // А91: fee_max = 0 — за доставку курьеру больше ничего не должны (с учётом заявок,
                    // которые ждут курьера): кнопку прячем. Старый сервер поля не шлёт — как раньше.
                    if c.feeMax == nil || (c.feeMax ?? 0) > 0 {
                        smallButton("Отдали за доставку", primary: false) {
                            settle = PoolSettleTarget(courierId: c.id, name: c.name ?? "Курьер", kind: "fee_paid",
                                                      suggested: c.feeMax ?? (shopOwes ? c.shopOwes : nil), max: c.feeMax)
                        }
                    }
                }
            }
            NavigationLink {
                PoolLedgerView(courierId: c.id, name: c.name ?? "Курьер")
            } label: {
                Label("История расчётов", systemImage: "list.bullet.rectangle")
                    .font(.subheadline)
            }
            .foregroundColor(Brand.accent)
        }
        .disabled(moneyVM.busy)
    }

    /// Состояние неподтверждённого QR после «Оплата по QR … — » (А86/А87, как в seller-pool.js).
    private func qrStateText(_ q: PoolQrPending) -> String {
        guard q.missing == true else { return "проверьте в банке." }
        let when = (q.missingAt?.isEmpty == false) ? " (" + PoolFmt.short(q.missingAt) + ")" : ""
        return "вы отметили: не пришла" + when + " — сумма в долге курьера."
    }

    /// Срок по неподтверждённому QR (А86 counts_as_debt, А87 debt_at), как в seller-pool.js:
    /// текст и «уже в долге» (красным); nil — пояснять нечего (старый сервер или уже «не пришла»).
    private func qrDebtNote(_ q: PoolQrPending) -> (text: String, overdue: Bool)? {
        if q.missing == true { return nil }
        if q.countsAsDebt == true { return ("Не подтверждено вовремя — уже идёт в долг курьера.", true) }
        if let at = q.debtAt, !at.isEmpty { return ("Не подтвердите до " + PoolFmt.short(at) + " — пойдёт в долг курьера.", false) }
        return nil
    }

    private func smallButton(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.borderless)
        .background(primary ? Brand.accent : Brand.accent.opacity(0.15))
        .foregroundColor(primary ? .white : Brand.accent)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Строка списка вызовов.
struct PoolCallRow: View {
    let call: PoolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(call.displayTitle).font(.headline).foregroundColor(Brand.text)
                Spacer()
                StatusBadge(text: call.statusText, color: PoolColors.status(call.status))
            }
            if let a = call.dropAddress, !a.isEmpty {
                Text(a).font(.subheadline).foregroundColor(Brand.muted).lineLimit(2)
            }
            // А80: кузов, грузчики, межгород.
            let cargo = call.cargoSummary
            if !cargo.isEmpty {
                Label(cargo, systemImage: "truck.box").font(.caption).foregroundColor(Brand.text).lineLimit(2)
            }
            HStack {
                if let n = call.courier?.name, !n.isEmpty {
                    Label(n, systemImage: "car").font(.caption).foregroundColor(Brand.text)
                }
                Spacer()
                Text(Money.rub(call.fee)).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
            }
            Text(PoolFmt.short(call.createdAt)).font(.caption2).foregroundColor(Brand.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// ── Карточка вызова ─────────────────────────────────────────────────────────
struct PoolCallDetailView: View {
    let callId: Int
    var initial: PoolCall? = nil

    @Environment(\.scenePhase) private var scenePhase
    @State private var call: PoolCall?
    @State private var state: LoadState
    @State private var gen = 0
    /// Какой вызов на экране: после «Выбрать другого водителя» (А80) — новый.
    @State private var shownId: Int

    /// Открыли по id (push) — сразу «загрузка», а не «Вызов не найден» на миг.
    init(callId: Int, initial: PoolCall? = nil) {
        self.callId = callId
        self.initial = initial
        _call = State(initialValue: initial)
        _state = State(initialValue: initial == nil ? .loading : .loaded)
        _shownId = State(initialValue: callId)
    }

    var body: some View {
        ScrollView {
            if let c = call {
                VStack(spacing: 14) {
                    PoolCallCard(call: c, onChanged: { updated in
                        if let u = updated { call = u } else { Task { await load() } }
                    }, onNewCall: { created in
                        // Новый вызов с другим водителем — его карточка вместо прежней.
                        gen += 1
                        shownId = created.callId
                        call = created
                        state = .loaded
                    })
                    detailsCard(c)
                }
                .padding(16)
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(call?.displayTitle ?? "Вызов курьера")
        .navigationBarTitleDisplayMode(.inline)
        .listState(state, isEmpty: call == nil, emptyIcon: "car", emptyTitle: "Вызов не найден",
                   retry: { Task { await load() } })
        .refreshable { await load() }
        .task {
            if call == nil, let i = initial { call = i }
            await load()
        }
        .task(id: "\(call?.isLive == true)-\(scenePhase == .active)") { await poll() }
        .onReceive(NotificationCenter.default.publisher(for: .poolCallPush)) { n in
            let raw = n.userInfo?["call_id"]
            let id = (raw as? String).flatMap { Int($0) } ?? raw as? Int
            if id == nil || id == shownId { Task { await load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await load() }
        }
    }

    private func load() async {
        let id = shownId
        guard id > 0 else { state = .failed("Вызов не найден"); return }
        gen += 1
        let my = gen
        if call == nil { state = .loading }
        do {
            let fresh = try await API.shared.poolCall(id: id)
            guard my == gen else { return }
            call = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard my == gen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Пока вызов живой и экран на виду — раз в 15 с.
    private func poll() async {
        guard call?.isLive == true, scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { return }
            await load()
        }
    }

    private func detailsCard(_ c: PoolCall) -> some View {
        SectionCard(title: "Доставка") {
            if let a = c.pickupAddress, !a.isEmpty { InfoRow(label: "Откуда", value: a) }
            if let a = c.dropAddress, !a.isEmpty { InfoRow(label: "Куда", value: a) }
            if let km = PoolFmt.km(c.distanceKm) { InfoRow(label: "Расстояние", value: "~" + km) }
            if let n = c.clientName, !n.isEmpty { InfoRow(label: "Клиент", value: n) }
            if let p = c.clientPhone, !p.isEmpty, let url = PoolFmt.telURL(p) {
                Link(destination: url) {
                    HStack {
                        Image(systemName: "phone.fill")
                        Text(p).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("Позвонить клиенту").font(.caption).foregroundColor(Brand.muted)
                    }
                    .foregroundColor(Brand.green)
                }
            }
            if let n = c.itemsCount, n > 0 { InfoRow(label: "Позиций", value: "\(n)") }
            if let g = c.goodsAmount, g > 0 { InfoRow(label: "Сумма товаров", value: Money.rub(g)) }
            if let cm = c.comment, !cm.isEmpty { InfoRow(label: "Комментарий", value: cm) }
            if let rc = c.ratingComment, !rc.isEmpty { InfoRow(label: "Отзыв о курьере", value: rc) }
            InfoRow(label: "Создан", value: PoolFmt.short(c.createdAt))
            if let o = c.orderId, o > 0 {
                NavigationLink {
                    OrderDetailView(orderId: o)
                } label: {
                    Label("Открыть заказ №\(c.orderNumber ?? o)", systemImage: "bag")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(Brand.accent)
                .padding(.top, 4)
            }
        }
    }
}

// ── Получили от курьера / отдали за доставку ───────────────────────────────
struct PoolSettleTarget: Identifiable {
    let courierId: Int
    let name: String
    let kind: String          // cash_received | fee_paid
    let suggested: Decimal?
    /// А91: «Отдали за доставку» — не больше fee_max; nil — без предела (старый сервер, cash_received).
    var max: Decimal? = nil
    var id: String { "\(courierId)-\(kind)" }
}

struct PoolSettleSheet: View {
    let target: PoolSettleTarget
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amount = ""
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    /// Ключ повтора — на это окно (метка окна в отпечатке, как nonce на Android):
    /// повтор отсюда — тот же ключ, новое окно с той же суммой — новая запись,
    /// а не сохранённый ответ прошлого окна. Закрыли окно — ключ забыт.
    @State private var idem = PoolIdemKey(scope: "pool/settlements", window: UUID().uuidString)
    /// Исход последней попытки неизвестен (обрыв, таймаут, 5xx): сумма и примечание
    /// заблокированы — «Повторить» уходит тем же телом с тем же ключом.
    @State private var unsettled = false

    private var cash: Bool { target.kind == "cash_received" }
    /// А91: сумма больше fee_max — «Записать» недоступна (сервер ответил бы 422).
    private var over: Bool {
        guard let m = target.max, let s = PoolFmt.money(amount), let d = Money.strict(s) else { return false }
        return d > m
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Сумма, ₽", text: $amount).keyboardType(.decimalPad)
                        .disabled(busy || unsettled)
                    TextField("Примечание (необязательно)", text: $note)
                        .disabled(busy || unsettled)
                } header: {
                    Text(cash ? "Сколько денег вы получили от курьера" : "Сколько вы отдали курьеру за доставку")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(cash ? "Записывается сразу: долг курьера уменьшится."
                                  : "Курьер подтвердит в своём приложении — до этого запись ждёт.")
                        // А91: предел «Отдали за доставку» — сколько ещё должны курьеру (fee_max).
                        if let m = target.max {
                            Text("Не больше " + Money.rub(m) + " — столько вы ещё должны курьеру за доставку")
                                .foregroundColor(over ? Brand.red : Brand.muted)
                        }
                    }
                }
                if let e = error {
                    Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Пока запрос идёт — окно не закрываем: ключ повтора живёт с окном.
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(unsettled ? "Повторить" : "Записать") { save() }.disabled(busy || over)
                }
            }
            .onAppear { if amount.isEmpty { amount = PoolFmt.input(target.suggested) } }
        }
        .interactiveDismissDisabled(busy)
        .onDisappear { idem.forgetWindow() }
    }

    private func save() {
        error = nil
        guard let sum = PoolFmt.money(amount), let d = Money.strict(sum), d > 0 else {
            error = "Укажите сумму больше 0"
            return
        }
        if let m = target.max, d > m {
            error = "Не больше " + Money.rub(m) + " — столько вы ещё должны курьеру за доставку"
            return
        }
        let text = String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        let fp = PoolIdemKey.fingerprint(["courier_id": target.courierId, "kind": target.kind, "amount": sum, "note": text])
        let key = idem.key(for: fp)
        busy = true
        Task { @MainActor in
            do {
                _ = try await API.shared.poolSettle(courierId: target.courierId, kind: target.kind, amount: sum,
                                                    note: text, idempotencyKey: key)
                idem.settle(after: nil)
                busy = false
                unsettled = false
                onDone()
                dismiss()
            } catch is CancellationError {
                busy = false
            } catch {
                idem.settle(after: error)
                busy = false
                unsettled = !PoolIdemKey.isDefinitive(error)
                self.error = PoolIdemKey.isUnknownOutcome(error)
                    ? "Не известно, записался ли расчёт. Закройте окно и проверьте «История расчётов», прежде чем записывать снова."
                    : unsettled
                        ? error.localizedDescription + ". Нажмите «Повторить» — расчёт не запишется дважды."
                        : error.localizedDescription
            }
        }
    }
}

// ── История расчётов с курьером ─────────────────────────────────────────────
struct PoolLedgerView: View {
    let courierId: Int
    let name: String

    @State private var rows: [PoolLedgerEntry] = []
    @State private var state: LoadState = .idle
    @State private var page = 1
    @State private var canMore = false
    @State private var loadingMore = false

    private static let perPage = 50   // CourierPool::sellerLedger, $per = 50

    var body: some View {
        List {
            Section {
                Text("«+» — курьер должен вам больше, «−» — меньше (или вы должны ему).")
                    .font(.caption).foregroundColor(Brand.muted)
            }
            .listRowBackground(Brand.card)
            Section {
                ForEach(rows) { e in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((e.kindLabel ?? e.kind ?? "") + (e.callId.map { " · №\($0)" } ?? ""))
                                .font(.subheadline).foregroundColor(Brand.text)
                            if let n = e.note, !n.isEmpty, n != e.kindLabel {
                                Text(n).font(.caption).foregroundColor(Brand.muted)
                            }
                            HStack(spacing: 6) {
                                Text(PoolFmt.short(e.createdAt)).font(.caption2).foregroundColor(Brand.muted)
                                if let s = e.status, s != "active" {
                                    Text("(" + (PoolFmt.ledgerStatus[s] ?? s) + ")").font(.caption2).foregroundColor(Brand.amber)
                                }
                            }
                        }
                        Spacer()
                        Text(Money.signed(e.amountForMe))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor((e.amountForMe ?? 0) > 0 ? Brand.text : Brand.green)
                    }
                    .onAppear {
                        if e.id == rows.last?.id { Task { await loadMore() } }
                    }
                }
                if loadingMore { ProgressView().frame(maxWidth: .infinity) }
            }
            .listRowBackground(Brand.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .listState(state, isEmpty: rows.isEmpty, emptyIcon: "list.bullet.rectangle", emptyTitle: "Записей пока нет",
                   retry: { Task { await load() } })
        .refreshable { await load() }
        .task { if state == .idle { await load() } }
    }

    private func load() async {
        if rows.isEmpty { state = .loading }
        do {
            let list = try await API.shared.poolLedger(courierId: courierId, page: 1)
            rows = list
            page = 1
            canMore = list.count >= Self.perPage
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadMore() async {
        guard canMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let list = try await API.shared.poolLedger(courierId: courierId, page: page + 1)
            page += 1
            let known = Set(rows.compactMap { $0.id })
            rows += list.filter { !known.contains($0.id ?? 0) }
            canMore = list.count >= Self.perPage
        } catch {
            canMore = false
        }
    }
}

// ── QR СБП для оплаты у двери ───────────────────────────────────────────────
struct PoolQrPanel: View {
    @State private var image: UIImage?
    @State private var loading = false
    @State private var missing = false
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var showPicker = false
    @State private var askDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SectionCard(title: "QR для оплаты у двери") {
                    Text("Загрузите QR-код СБП из приложения вашего банка (для бизнеса, на расчётный счёт). Курьер Yumurta покажет его клиенту — деньги придут сразу вам, мимо курьера. Банки не блокируют такие оплаты: это оплата покупки, а не перевод между людьми. После доставки подтвердите, что оплата пришла.")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                    Group {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else if loading {
                            ProgressView()
                        } else if missing {
                            Text("QR ещё не загружен.").font(.subheadline).foregroundColor(Brand.muted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    if let e = error { Text(e).font(.footnote).foregroundColor(Brand.red) }
                    if let n = notice { Text(n).font(.footnote.weight(.semibold)).foregroundColor(Brand.green) }
                    Button {
                        showPicker = true
                    } label: {
                        Label(image == nil ? "Загрузить QR" : "Заменить QR", systemImage: "qrcode")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.borderless)
                    .background(Brand.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    if image != nil {
                        Button(role: .destructive) {
                            askDelete = true
                        } label: {
                            Text("Удалить QR")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .buttonStyle(.borderless)
                        .background(Brand.red.opacity(0.12))
                        .foregroundColor(Brand.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .disabled(busy)
            }
            .padding(16)
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showPicker) {
            PhotoLibraryPicker(onPick: { img in upload(img) }, onFail: { msg in error = msg })
        }
        .confirmationDialog("Удалить QR? Курьеры не смогут показать его клиенту.", isPresented: $askDelete,
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { remove() }
        }
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let data = try await API.shared.poolQrImage()
            image = UIImage(data: data)
            missing = image == nil
        } catch is CancellationError {
        } catch {
            // Только 404 «Фото нет» (CourierPool::streamImage) — QR ещё не загружали.
            // Остальное (нет сети, нет прав, сбой) — текстом, без «не загружен».
            let text = error.localizedDescription
            if text == "Фото нет" || text == API.statusText(404) {
                image = nil
                missing = true
            } else {
                self.error = text
            }
        }
    }

    private func upload(_ img: UIImage) {
        guard !busy else { return }
        busy = true
        error = nil
        notice = nil
        Task { @MainActor in
            // QR мелкий и контрастный — не ужимаем сильно, иначе банк его не прочтёт.
            // Сжатие — вне главного потока: большое фото на главном подвешивало экран.
            guard let jpeg = await Task.detached(operation: {
                ImageCompressor.jpegForUpload(img, maxSide: 2000, quality: 0.92)
            }).value else {
                busy = false
                error = "Не удалось подготовить картинку"
                return
            }
            do {
                _ = try await API.shared.poolUploadQr(jpeg: jpeg)
                busy = false
                notice = "QR сохранён"
                await load()
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }

    private func remove() {
        busy = true
        error = nil
        notice = nil
        Task { @MainActor in
            do {
                _ = try await API.shared.poolDeleteQr()
                busy = false
                image = nil
                missing = true
                notice = "QR удалён"
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
