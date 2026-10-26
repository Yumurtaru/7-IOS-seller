import SwiftUI
import Combine

// ============================================================================
//  Деталь заказа — GET /api/seller/orders/{id}.
//  Смена статуса только по допустимым переходам (машина статусов — зеркало
//  $allowed из routes/seller.php, сервер валидирует), отмена с причиной,
//  позиции с модификаторами, телефон клиента (tel:), лог статусов, чат.
// ============================================================================

@MainActor
final class OrderDetailViewModel: ObservableObject {
    @Published var order: OrderDetail?
    @Published var state: LoadState = .idle
    @Published var actionError: String?
    @Published var actionNotice: String?
    @Published var isActing = false

    let orderId: Int
    init(orderId: Int) { self.orderId = orderId }

    /// Номер последнего чтения: «потянуть вниз» во время смены статуса — и
    /// поздний ответ старого чтения возвращал на экран прежний статус и кнопки.
    private var loadGen = 0

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if order == nil { state = .loading }
        do {
            let fresh = try await API.shared.order(id: orderId)
            guard myGen == loadGen else { return }
            order = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// А78: тихое перечитывание для опроса блока «Курьер Yumurta». Заказ уже на
    /// экране — мигнувшая сеть не показывает красную полосу «Не обновилось»
    /// (ошибку просто пропускаем, следующий опрос через 15 с).
    func reloadSilently() async {
        guard order != nil else { await load(); return }
        loadGen += 1
        let myGen = loadGen
        guard let fresh = try? await API.shared.order(id: orderId), myGen == loadGen else { return }
        order = fresh
        state = .loaded
    }

    func setStatus(_ status: String) async -> Bool {
        // Двойной тап по кнопке статуса уходил двумя запросами: второй получал
        // «Недопустимый переход» и показывал ошибку при успешной смене.
        guard !isActing else { return false }
        isActing = true
        actionError = nil
        defer { isActing = false }
        do {
            _ = try await API.shared.setOrderStatus(id: orderId, status: status)
            await load()
            // Принятый заказ уходит из «новых» сразу, а не через 30 с опроса:
            // иначе следующий заказ в эти 30 с не менял счётчик (было 1 — стало 1)
            // и приходил без звонка.
            if status == "accepted" { await NewOrderPoller.shared.tick() }
            return true
        } catch {
            actionError = error.localizedDescription   // «Недопустимый переход статуса» и т.п.
            await load()   // статус мог уже смениться — показываем актуальный
            return false
        }
    }

    /// Правка состава: шлём только изменённые строки, суммы пересчитывает сервер.
    /// Любая ошибка (в том числе 409 «заказ уже изменили») заканчивается
    /// перечитыванием заказа — на экране всегда актуальные данные.
    func editItems(rev: Int, reason: String, lines: [(id: Int, qty: Decimal)]) async -> Bool {
        guard !lines.isEmpty, !isActing else { return false }
        isActing = true
        actionError = nil
        defer { isActing = false }
        actionNotice = nil
        do {
            let res = try await API.shared.editOrderItems(id: orderId, rev: rev,
                                                          reason: reason.isEmpty ? nil : reason, lines: lines)
            // Сервер предупреждает: заказ уже оплачен и сумма уменьшилась —
            // разницу клиенту нужно вернуть отдельно (сама она не вернётся).
            if res.paidWarning == true {
                actionNotice = "Заказ уже оплачен: разницу нужно вернуть клиенту отдельно (раздел «Возвраты»)."
            }
            await load()
            return true
        } catch {
            actionError = error.localizedDescription
            await load()
            return false
        }
    }

    func cancel(reason: String) async -> Bool {
        guard !isActing else { return false }
        isActing = true
        actionError = nil
        defer { isActing = false }
        do {
            _ = try await API.shared.cancelOrder(id: orderId, reason: reason)
            await load()
            await NewOrderPoller.shared.tick()   // отменённый новый — тоже не «новый» (см. setStatus)
            return true
        } catch {
            actionError = error.localizedDescription
            await load()
            return false
        }
    }
}

struct OrderDetailView: View {
    @StateObject private var vm: OrderDetailViewModel
    @State private var showCancelDialog = false
    @State private var showEditSheet = false
    @State private var cancelReason = ""
    @State private var showChat: Bool
    /// А78: опрос блока «Курьер Yumurta» — только пока приложение на экране.
    @Environment(\.scenePhase) private var scenePhase
    var onChanged: (() -> Void)?

    init(orderId: Int, openChat: Bool = false, onChanged: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: OrderDetailViewModel(orderId: orderId))
        _showChat = State(initialValue: openChat)
        self.onChanged = onChanged
    }

    var body: some View {
        ScrollView {
            if let o = vm.order {
                VStack(spacing: 14) {
                    headerCard(o)
                    if let err = vm.actionError {
                        Text(err)
                            .font(.footnote)
                            .foregroundColor(Brand.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    if let note = vm.actionNotice {
                        Text(note)
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Brand.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                    actionsCard(o)
                    // А78 «Курьеры Yumurta»: вызов курьера площадки и его статус.
                    PoolOrderBlock(orderId: o.id ?? vm.orderId, call: o.poolCall?.call,
                                   available: o.poolCallAvailable == true) {
                        Task { await vm.load(); onChanged?() }
                    }
                    if let ch = o.changes, !ch.isEmpty { changesCard(ch) }
                    itemsCard(o)
                    totalsCard(o)
                    clientCard(o)
                    logCard(o)
                }
                .padding(16)
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(vm.order.map { "Заказ №\($0.dailyNumber ?? $0.id ?? vm.orderId)" } ?? "Заказ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showChat = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
            }
        }
        .sheet(isPresented: $showChat) {
            OrderChatView(orderId: vm.orderId)
        }
        .sheet(isPresented: $showEditSheet) {
            if let o = vm.order {
                OrderEditSheet(order: o, busy: vm.isActing) { reason, lines in
                    // Лист закрываем только после успеха: раньше он закрывался до
                    // ответа, и при обрыве связи или отказе набранные количества
                    // и причина пропадали — правку приходилось вводить заново.
                    Task {
                        if await vm.editItems(rev: o.rev ?? 0, reason: reason, lines: lines) {
                            showEditSheet = false
                            onChanged?()
                        } else if (vm.order?.rev ?? 0) != (o.rev ?? 0) {
                            // паритет с Android: заказ уже изменили (409) — лист закрываем.
                            // Иначе повторное «Сохранить» ушло бы с новой ревизией и
                            // старыми количествами и затёрло бы чужую правку.
                            // Алерт ошибки уходит вместе с листом — причину пишем на экране.
                            vm.actionNotice = "Заказ уже изменили — проверьте состав и повторите правку"
                            // Текст 409 уже сказан подсказкой выше — красной строкой его не
                            // дублируем (на экране было два сообщения об одном отказе).
                            vm.actionError = nil
                            showEditSheet = false
                        }
                    }
                }
                .errorAlert($vm.actionError)
            }
        }
        .alert("Отменить заказ", isPresented: $showCancelDialog) {
            TextField("Причина отмены", text: $cancelReason)
            Button("Отменить заказ", role: .destructive) {
                // Причину сервер требует (422) — проверяем сразу.
                let r = cancelReason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !r.isEmpty else { vm.actionError = "Укажите причину отмены"; return }
                Task {
                    if await vm.cancel(reason: r) {
                        cancelReason = ""
                        onChanged?()
                    }
                }
            }
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text("Укажите причину — её увидит клиент")
        }
        .listState(vm.state, isEmpty: vm.order == nil,
                   emptyIcon: "bag", emptyTitle: "Заказ не найден",
                   retry: { Task { await vm.load() } })
        .refreshable { await vm.load() }
        .task { await vm.load() }
        // Карточка оставалась открытой, пока приложение было свёрнуто: клиент мог
        // отменить заказ, коллега — принять. Кнопки были от старого статуса, и
        // нажатие кончалось «Недопустимый переход». Перечитываем при возврате.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Пока открыт лист правки состава, не перечитываем: иначе сохранение
            // уйдёт с новой ревизией и старыми количествами и молча откатит правку коллеги.
            guard !showEditSheet else { return }
            Task { await vm.load() }
        }
        // А78: курьер Yumurta ищется или едет — перечитываем карточку раз в 15 с,
        // пока она на экране и приложение не свёрнуто (task снимается сам).
        .task(id: poolPollKey) { await pollPool() }
        // Push pool_call по этому заказу при открытом приложении — сразу.
        .onReceive(NotificationCenter.default.publisher(for: .poolCallPush)) { n in
            let raw = n.userInfo?["order_id"]
            let id = (raw as? String).flatMap { Int($0) } ?? raw as? Int
            guard id == vm.orderId, !showEditSheet else { return }
            Task { await vm.load() }
        }
    }

    private var poolPollKey: String {
        "\(vm.order?.poolCall?.call?.isLive == true)-\(scenePhase == .active)"
    }

    private func pollPool() async {
        guard vm.order?.poolCall?.call?.isLive == true, scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { return }
            // Открыт лист правки состава — не перечитываем (см. willEnterForeground).
            guard !showEditSheet, !showCancelDialog else { continue }
            await vm.reloadSilently()
        }
    }

    // ── Шапка ────────────────────────────────────────────────────────────────
    private func headerCard(_ o: OrderDetail) -> some View {
        SectionCard {
            HStack {
                // П-26.7: подпись статуса сервера (status_title), иначе словарь приложения.
                StatusBadge(text: o.statusText(o.status), color: OrderStatuses.color(o.status))
                if o.paymentStatus == "paid" { StatusBadge(text: "Оплачен", color: Brand.green) }
                // Деньги по заказу вернули — без бейджа заказ выглядел просто неоплаченным.
                if o.paymentStatus == "refunded" { StatusBadge(text: PaymentLabels.status("refunded"), color: Brand.amber) }
                // К-18: наличные за заказ ещё у курьера — без бейджа заказ выглядел
                // просто неоплаченным, и деньги с курьера легко забыть спросить.
                if o.paymentStatus == "awaiting_courier_cash" {
                    StatusBadge(text: PaymentLabels.status("awaiting_courier_cash"), color: Brand.amber)
                }
                Spacer()
                Text(DateFmt.short(o.createdAt)).font(.caption).foregroundColor(Brand.muted)
            }
            // Предзаказ — сразу под статусом и крупно: время «к которому»
            // решает, когда готовить, а строка в середине карточки терялась.
            if let pre = o.preorderAt, !pre.isEmpty {
                preorderBanner(pre)
            }
            InfoRow(label: "Получение", value: PaymentLabels.delivery(o.deliveryType))
            InfoRow(label: "Оплата", value: PaymentLabels.type(o.paymentType))
            // паритет с Android: «нужна сдача с …» (payment_note, cart.php change_from) —
            // курьеру нужно знать заранее; раньше на iPhone не показывалось.
            if let note = o.paymentNote, !note.isEmpty {
                InfoRow(label: "Сдача с", value: note)
            }
            // А60/П-23.8: строка адреса и квартира/подъезд/этаж/домофон — из
            // address_text/address_details; без них — прежний разбор address.
            if !o.addressLine.isEmpty {
                InfoRow(label: "Адрес", value: o.addressLine)
            }
            if !o.addressExtras.isEmpty {
                InfoRow(label: "Детали", value: o.addressExtras)
            }
            if let table = o.tableNumber, !table.isEmpty {
                InfoRow(label: "Стол", value: table)
            }
            commentBlock(o)
            if let reason = o.cancelReason, !reason.isEmpty {
                InfoRow(label: "Причина отмены", value: reason)
            }
        }
    }

    private func preorderBanner(_ pre: String) -> some View {
        Label("Ко времени: " + DateFmt.short(pre), systemImage: "clock.fill")
            .font(.headline)
            .foregroundColor(Brand.amber)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Brand.amber.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// А63: комментарий клиента к записи приходит отдельно (client_comment) —
    /// показываем его своей строкой «Комментарий клиента».
    @ViewBuilder
    private func commentBlock(_ o: OrderDetail) -> some View {
        let note = orderNote(o)
        if !note.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Комментарий").font(.subheadline).foregroundColor(Brand.muted)
                Text(note).font(.subheadline).foregroundColor(Brand.text)
            }
        }
        if let cc = o.clientComment?.trimmingCharacters(in: .whitespacesAndNewlines), !cc.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Комментарий клиента").font(.subheadline).foregroundColor(Brand.muted)
                Text(cc).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
            }
        }
    }

    /// Тот же текст клиента сервер дописывает хвостом в comment
    /// (« · Комментарий: …») — убираем хвост, чтобы не показывать дважды.
    private func orderNote(_ o: OrderDetail) -> String {
        let c = o.comment ?? ""
        guard let cc = o.clientComment, !cc.isEmpty else { return c }
        let tail = " · Комментарий: " + cc
        guard c.hasSuffix(tail) else { return c }
        return String(c.dropLast(tail.count))
    }

    // ── Действия по статусу ──────────────────────────────────────────────────
    private func actionsCard(_ o: OrderDetail) -> some View {
        // Смена статуса и отмена — разные права внутри «Заказов»: сборщику
        // статусы нужны, а отменять заказ он не должен.
        // Заказ-бронь жилья: статусами управляет раздел «Брони» на сайте, и
        // сервер переходы отсюда отклоняет. Кнопки, которые всё равно вернут
        // ошибку, не показываем — вместо них состояние брони.
        let lodging = o.lodging
        // «Передать в доставку» у самовывоза и заказа в зале переводило заказ
        // в «В пути»: клиент видел курьера, которого нет. Таким заказам после
        // «Готов» остаётся только «Выполнен».
        let noCourier = o.deliveryType == "pickup" || o.deliveryType == "dine_in"
        // Паритет с Android: курьер Yumurta уже вызван (вызов жив) — «Передать
        // в доставку» руками не нужна: заказ уйдёт «в путь», когда курьер нажмёт
        // «Забрал» (CourierPool), как в вебе.
        let poolLive = o.poolCall?.call?.isLive == true
        let next = (lodging == nil && Session.shared.can("orders.status"))
            ? OrderStatuses.next(o.status).filter { !(noCourier && $0 == "in_delivery") }
                .filter { !(poolLive && $0 == "in_delivery") } : []
        // паритет с Android: «В пути» тоже отменяется, если курьера на заказе нет
        // (не назначали или он вернул заказ) — seller.php, /cancel.
        let noCourierOnRoute = o.status == "in_delivery" && (o.courierId ?? 0) <= 0
        let cancellable = lodging == nil && (OrderStatuses.canCancel(o.status) || noCourierOnRoute)
            && Session.shared.can("orders.cancel")
        return Group {
            if let lg = lodging {
                VStack(alignment: .leading, spacing: 4) {
                    Text([lg.unitTitle?.isEmpty == false ? lg.unitTitle! : nil, lg.datesText]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundColor(Brand.text)
                    Text("Бронь: " + lg.statusText
                         + (lg.roomsValue > 1 ? ", номеров \(lg.roomsValue)" : ""))
                        .font(.caption).foregroundColor(Brand.muted)
                    Text("Заезд, выезд и отмену отмечайте в кабинете на сайте — раздел «Брони». "
                         + "Заказ закроется сам на выезде гостя.")
                        .font(.caption).foregroundColor(Brand.muted)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !next.isEmpty || cancellable {
                VStack(spacing: 8) {
                    ForEach(next, id: \.self) { status in
                        Button {
                            Task { if await vm.setStatus(status) { onChanged?() } }
                        } label: {
                            Text(OrderStatuses.actionLabel(status))
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .background(status == "done" ? Brand.green : Brand.accent)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(vm.isActing)
                    }
                    // Правка состава: не оказалось товара — уменьшаем количество,
                    // сервер пересчитывает сумму, клиент видит, что изменилось.
                    if lodging == nil, (o.canEdit ?? false), (o.items ?? []).contains(where: { ($0.lineId ?? 0) > 0 }) {
                        Button {
                            showEditSheet = true
                        } label: {
                            Text("Изменить состав заказа")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .background(Brand.accent.opacity(0.15))
                        .foregroundColor(Brand.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(vm.isActing)
                    }
                    if cancellable {
                        Button {
                            showCancelDialog = true
                        } label: {
                            Text("Отменить заказ")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                        }
                        .background(Brand.red.opacity(0.15))
                        .foregroundColor(Brand.red)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .disabled(vm.isActing)
                    }
                }
            }
        }
    }

    // ── Позиции ──────────────────────────────────────────────────────────────
    private func itemsCard(_ o: OrderDetail) -> some View {
        SectionCard(title: "Состав заказа") {
            ForEach(o.items ?? []) { item in
                // modifiers — разбор JSON при каждом обращении: раньше он шёл
                // (число добавок + 1) раз на строку при каждой перерисовке.
                let mods = item.modifiers
                VStack(alignment: .leading, spacing: 3) {
                    if item.quantityChanged {
                        Text("изменено: было \(qtyString(item.qtyOrdered))\(unitSuffix(item.unit))")
                            .font(.caption)
                            .foregroundColor(Brand.accent)
                    }
                    HStack(alignment: .top) {
                        Text(item.name ?? "Позиция")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Brand.text)
                        Spacer()
                        // паритет с Android: у весового товара единица рядом с количеством
                        // («×0,375 кг»), иначе читалось как штуки.
                        Text("×\(qtyString(item.qty))\(item.unit == "шт" ? "" : unitSuffix(item.unit))")
                            .font(.subheadline)
                            .foregroundColor(Brand.muted)
                        Text(Money.rub(item.price))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Brand.text)
                    }
                    ForEach(mods.indices, id: \.self) { i in
                        let m = mods[i]
                        Text("+ \(m.name)\(m.price.map { p in p > 0 ? " (" + Money.rub(p) + ")" : "" } ?? "")")
                            .font(.caption)
                            .foregroundColor(Brand.muted)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func unitSuffix(_ u: String?) -> String {
        guard let u = u, !u.isEmpty else { return "" }
        return " " + u
    }

    // ── Что изменилось в заказе (то же видит клиент) ─────────────────────────
    private func changesCard(_ changes: [OrderChangeEntry]) -> some View {
        SectionCard(title: "Изменения заказа") {
            Text("Это же видит клиент в своём заказе.")
                .font(.caption)
                .foregroundColor(Brand.muted)
            ForEach(changes) { ch in
                VStack(alignment: .leading, spacing: 3) {
                    Divider().overlay(Brand.border)
                    // Время правки приходит «2026-10-14 12:00:00» — показываем как в
                    // остальной карточке («14 окт, 12:00»), а не сырой строкой сервера.
                    Text(joinedNonEmpty([DateFmt.short(ch.at), ch.actor], separator: " · "))
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                    ForEach(ch.lines ?? []) { l in
                        Text(changeLineText(l))
                            .font(.subheadline)
                            .foregroundColor(Brand.text)
                    }
                    if let r = ch.reason, !r.isEmpty {
                        Text("Причина: \(r)").font(.caption).foregroundColor(Brand.muted)
                    }
                    InfoRow(label: "Сумма заказа",
                            value: Money.rub(ch.totalBefore) + " → " + Money.rub(ch.totalAfter))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func changeLineText(_ l: OrderChangeLine) -> String {
        let unit = unitSuffix(l.unit)
        let before = qtyString(l.qtyBefore) + unit
        let after = qtyString(l.qtyAfter) + unit
        let name = l.name ?? "Позиция"
        return l.op == "remove" ? "\(name) — убрано (было \(before))" : "\(name): \(before) → \(after)"
    }

    private func qtyString(_ qty: Decimal?) -> String {
        // «0,7 кг», а не «0.7»: дробь по-русски, как в остальных экранах.
        QtyFmt.qty(qty ?? 1)
    }

    // ── Суммы ────────────────────────────────────────────────────────────────
    private func totalsCard(_ o: OrderDetail) -> some View {
        SectionCard {
            InfoRow(label: "Товары", value: Money.rub(o.subtotal))
            if let d = o.deliveryPrice, d > 0 { InfoRow(label: "Доставка", value: Money.rub(d)) }
            if let f = o.serviceFee, f > 0 { InfoRow(label: "Сервисный сбор", value: Money.rub(f)) }
            if let disc = o.discount, disc > 0 { InfoRow(label: "Скидка", value: "−" + Money.rub(disc)) }
            if let t = o.tip, t > 0 { InfoRow(label: "Чаевые курьеру", value: "+" + Money.rub(t)) }
            // Без этой строки итог не сходился с разбивкой (см. комментарий в модели).
            if let pts = o.pointsSpent, pts > 0 { InfoRow(label: "Оплачено баллами", value: "−" + Money.rub(pts)) }
            if let promo = o.promoCode, !promo.isEmpty { InfoRow(label: "Промокод", value: promo) }
            Divider().overlay(Brand.border)
            HStack {
                Text("Итого").font(.headline).foregroundColor(Brand.text)
                Spacer()
                Text(Money.rub(o.total)).font(.headline).foregroundColor(Brand.text)
            }
        }
    }

    // ── Клиент ───────────────────────────────────────────────────────────────
    private func clientCard(_ o: OrderDetail) -> some View {
        Group {
            if o.client != nil || o.clientPhone != nil {
                SectionCard(title: "Клиент") {
                    if let name = o.client, !name.isEmpty {
                        InfoRow(label: "Имя", value: name)
                    }
                    if let phone = o.clientPhone, !phone.isEmpty,
                       let url = URL(string: "tel://" + phone.filter { "+0123456789".contains($0) }) {
                        Link(destination: url) {
                            HStack {
                                Image(systemName: "phone.fill")
                                Text(phone).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("Позвонить").font(.caption).foregroundColor(Brand.muted)
                            }
                            .foregroundColor(Brand.green)
                        }
                    }
                }
            }
        }
    }

    // ── Лог статусов ─────────────────────────────────────────────────────────
    private func logCard(_ o: OrderDetail) -> some View {
        Group {
            if let log = o.log, !log.isEmpty {
                SectionCard(title: "История статусов") {
                    ForEach(log) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(OrderStatuses.color(entry.status))
                                .frame(width: 8, height: 8)
                                .padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                // П-26.7: журнал подписан словарём сервера (status_titles).
                                Text(o.statusText(entry.status))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(Brand.text)
                                if let c = entry.comment, !c.isEmpty {
                                    Text(c).font(.caption).foregroundColor(Brand.muted)
                                }
                            }
                            Spacer()
                            Text(DateFmt.short(entry.createdAt))
                                .font(.caption)
                                .foregroundColor(Brand.muted)
                        }
                    }
                }
            }
        }
    }
}

// ============================================================================
//  Правка состава заказа.
//
//  Меняется ТОЛЬКО количество: цена — не поле сотрудника, иначе история правок
//  перестаёт быть честной, а у персонала появляется способ «дарить» скидки.
//  0 убирает позицию; убрать все позиции нельзя — для этого есть отмена заказа.
//  Итог считает сервер, здесь показываем лишь предварительную сумму товаров.
// ============================================================================
struct OrderEditSheet: View {
    let order: OrderDetail
    let busy: Bool
    /// (причина, [(id строки, новое количество)]) — только изменённые строки.
    let onSave: (String, [(id: Int, qty: Decimal)]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var qty: [Int: String] = [:]
    @State private var reason: String = ""

    private var editable: [OrderItem] { (order.items ?? []).filter { ($0.lineId ?? 0) > 0 } }

    private func parsed(_ it: OrderItem) -> Decimal? {
        let raw = (qty[it.lineId ?? 0] ?? "").replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return 0 }
        // Целиком, а не начало строки: «2,,5» раньше читалось как 2, «1 5» — как 1.
        // Пробел внутри количества — опечатка («1 5»), а не разряды: не угадываем.
        guard !raw.contains(" "), let d = Money.strict(raw, maxFraction: 3), d >= 0 else { return nil }
        return d
    }

    private var goods: Decimal {
        editable.reduce(Decimal(0)) { acc, it in acc + (it.price ?? 0) * (parsed(it) ?? 0) }
    }
    private var allValid: Bool { editable.allSatisfy { parsed($0) != nil } }
    private var anyLeft: Bool { editable.contains { (parsed($0) ?? 0) > 0 } }
    private var changed: Bool { editable.contains { parsed($0) != ($0.qty ?? 0) } }
    /// паритет с Android: сервер (core/OrderEdit.php, paid_increase) у оплаченного заказа
    /// и у заказа с наличными у курьера разрешает только уменьшать количество —
    /// раньше отказ приходил уже после «Сохранить».
    private var increased: Bool {
        let onlyDecrease = order.paymentStatus == "paid" || order.paymentStatus == "awaiting_courier_cash"
        guard onlyDecrease else { return false }
        return editable.contains { it in
            guard let q = parsed(it) else { return false }
            return q > (it.qty ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Меняется только количество. Поставьте 0, чтобы убрать позицию. "
                         + "Сумму пересчитает сервер, клиент увидит, что именно изменилось.")
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
                Section("Позиции") {
                    ForEach(editable) { it in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.name ?? "Позиция").font(.subheadline)
                                Text(Money.rub(it.price) + " / " + ((it.unit?.isEmpty == false) ? it.unit! : "шт"))
                                    .font(.caption).foregroundColor(Brand.muted)
                            }
                            Spacer()
                            TextField("0", text: Binding(
                                get: { qty[it.lineId ?? 0] ?? "" },
                                set: { qty[it.lineId ?? 0] = $0 }
                            ))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .foregroundColor(parsed(it) == nil ? Brand.red : Brand.text)
                        }
                    }
                }
                Section {
                    HStack {
                        Text("Товары после правки")
                        Spacer()
                        Text(Money.rub(goods)).fontWeight(.semibold)
                    }
                    if !anyLeft {
                        Text("Нельзя убрать все позиции — отмените заказ целиком.")
                            .font(.caption).foregroundColor(Brand.red)
                    }
                    if order.paymentStatus == "paid" {
                        Text("Заказ уже оплачен: разницу нужно вернуть клиенту отдельно.")
                            .font(.caption).foregroundColor(Brand.red)
                    }
                    if increased {
                        Text("Заказ уже оплачен — количество можно только уменьшить.")
                            .font(.caption).foregroundColor(Brand.red)
                    }
                }
                Section("Причина (увидит клиент)") {
                    TextField("Например: не оказалось нужного количества", text: $reason)
                }
            }
            .navigationTitle("Изменить состав")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let lines: [(id: Int, qty: Decimal)] = editable.compactMap { it in
                            guard let q = parsed(it), q != (it.qty ?? 0), let lid = it.lineId else { return nil }
                            return (id: lid, qty: q)
                        }
                        onSave(reason.trimmingCharacters(in: .whitespacesAndNewlines), lines)
                    }
                    .disabled(busy || !allValid || !changed || !anyLeft || increased)
                }
            }
            .onAppear {
                for it in editable {
                    qty[it.lineId ?? 0] = qtyText(it.qty ?? 0)
                }
            }
        }
    }

    /// «1» вместо «1.000», «0,7» вместо «0.700» — с запятой, как на русской
    /// клавиатуре: правка «0.7» запятой давала «0.7,5» и красное поле.
    private func qtyText(_ v: Decimal) -> String {
        if v == Decimal(Int(truncating: v as NSDecimalNumber)) {
            return "\(Int(truncating: v as NSDecimalNumber))"
        }
        return "\(v)".replacingOccurrences(of: ".", with: ",")
    }
}
