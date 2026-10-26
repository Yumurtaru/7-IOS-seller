import SwiftUI
import UIKit

// ============================================================================
//  «Курьеры Yumurta» (волна А78) — карточка вызова курьера площадки, окно
//  «Вызвать курьера Yumurta», оценка и «Проблема с доставкой».
//  Зеркало веб-кабинета: seller/assets/js/seller-pool.js (callCard, actions,
//  openCallModal, openRate, openProblem). Кнопки — строго по can сервера.
//  А80: кузов, грузчики и межгород — общий выбор машины PoolCargoPicker,
//  «Выбрать другого водителя» (can.choose_driver) — новый вызов с теми же данными.
//  А81: плашка правила «только грузы и посылки» (quote.rule) в окне вызова,
//  «Пожаловаться на курьера» (can.complain) и строка своей жалобы (complaint).
// ============================================================================

extension Notification.Name {
    /// Пришёл push pool_call при открытом приложении: открытые карточки вызова
    /// и заказа перечитываются сразу, не дожидаясь опроса. userInfo — data push.
    static let poolCallPush = Notification.Name("yumurta.poolCallPush")
}

/// Ключ повтора для формы: один на одно и то же содержимое формы (повтор после
/// обрыва не задваивает вызов или расчёт), новый — после окончательного ответа
/// сервера. Ключи без ответа живут в общем хранилище PoolPendingKeys, а не в
/// листе: закрыли окно вызова после таймаута и открыли снова с теми же данными —
/// уйдёт тот же ключ, и сервер не создаст второй вызов вручную. У расчётов ключ
/// с меткой окна (window): новое окно — новая запись, как на Android.
struct PoolIdemKey {
    /// Ручка: "pool/calls" | "pool/settlements" — входит в отпечаток.
    let scope: String
    /// Метка окна (как nonce формы на Android): с ней ключ живёт только в этом
    /// окне — новое окно с той же суммой уходит с новым ключом и пишет новую
    /// запись, а не получает сохранённый ответ прошлой. nil — общий ключ на
    /// одинаковое содержимое (вызов курьера: защита от второго вызова).
    let window: String?
    private var fingerprint = ""

    init(scope: String, window: String? = nil) {
        self.scope = scope
        self.window = window
    }

    mutating func key(for fp: String) -> String {
        fingerprint = scope + (window.map { "\n" + $0 } ?? "") + "\n" + fp
        // Ключ окна не истекает по времени, пока окно открыто (в «Повторить» можно
        // просидеть и дольше 30 минут): его снимает окончательный ответ или закрытие
        // окна (forgetWindow). 30 минут — только для общих ключей без окна.
        return PoolPendingKeys.key(for: fingerprint, expires: window == nil)
    }

    /// Окно закрыли — его ключ больше не нужен (только для ключа с меткой окна).
    func forgetWindow() {
        guard window != nil, !fingerprint.isEmpty else { return }
        PoolPendingKeys.forget(fingerprint)
    }

    /// Сервер ответил окончательно (успех или отказ с текстом) — ключ больше не нужен.
    /// Обрыв, таймаут, 5xx, «первый запрос ещё идёт» и «исход неизвестен» —
    /// ключ оставляем: повтор с ним не сделает дубль.
    func settle(after error: Error?) {
        if PoolIdemKey.isDefinitive(error) { PoolPendingKeys.forget(fingerprint) }
    }

    static func isDefinitive(_ error: Error?) -> Bool {
        guard let error else { return true }
        if let e = error as? IdempotencyError {
            return e.code != "idempotency_in_progress" && e.code != "idempotency_unknown_outcome"
        }
        // А80: отказ вызова с кодом и полями — окончательный, кроме 5xx (сервер
        // снимает отметку ключа, повтор с тем же ключом безопасен).
        if let e = error as? APIDetailedError { return e.status < 500 }
        if let e = error as? APIError {
            switch e {
            case .server, .decoding: return true
            default: return false
            }
        }
        return false
    }

    /// Сервер не знает, прошёл ли первый запрос с этим ключом.
    static func isUnknownOutcome(_ error: Error) -> Bool {
        (error as? IdempotencyError)?.code == "idempotency_unknown_outcome"
    }

    /// Отпечаток тела запроса — по нему видно, что форму поменяли.
    static func fingerprint(_ body: [String: Any?]) -> String {
        let clean = body.compactMapValues { $0 }
        guard let d = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
}

/// Ключи повтора, на которые сервер ещё не ответил окончательно, по отпечатку
/// формы. Общие ключи (без окна) живут 30 минут — дольше повтор той же формы уже
/// другое действие. Ключи окна (expires: false) по времени не истекают: их снимает
/// окончательный ответ сервера или закрытие окна.
enum PoolPendingKeys {
    private static let lock = NSLock()
    private static var keys: [String: (key: String, at: Date, expires: Bool)] = [:]

    static func key(for fp: String, expires: Bool = true) -> String {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        keys = keys.filter { !$0.value.expires || now.timeIntervalSince($0.value.at) < 1800 }
        if let k = keys[fp] { return k.key }
        let k = UUID().uuidString
        keys[fp] = (k, now, expires)
        return k
    }

    static func forget(_ fp: String) {
        lock.lock(); defer { lock.unlock() }
        keys.removeValue(forKey: fp)
    }
}

enum PoolColors {
    static func status(_ s: String?) -> Color {
        switch s {
        case "searching": return Brand.amber
        case "accepted", "picked": return .blue
        case "delivered": return Brand.green
        case "failed", "cancelled", "expired": return Brand.red
        default: return Brand.muted
        }
    }
}

// ── Фото курьера (картинка с Bearer — обычной ссылкой не открывается) ───────
struct PoolCourierPhoto: View {
    let callId: Int
    let courierId: Int
    var size: CGFloat = 48

    @State private var image: UIImage?
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 40
        return c
    }()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundColor(Brand.muted)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Ключ — вызов и курьер: после «снять курьера» у того же вызова другой курьер.
        .task(id: "\(callId)-\(courierId)") {
            let key = "\(callId)-\(courierId)" as NSString
            if let cached = Self.cache.object(forKey: key) { image = cached; return }
            guard callId > 0,
                  let data = try? await API.shared.poolCourierPhoto(callId: callId),
                  let img = UIImage(data: data) else { return }
            Self.cache.setObject(img, forKey: key)
            image = img
        }
    }
}

// ── Карточка вызова: статус, курьер, деньги, действия ──────────────────────
struct PoolCallCard: View {
    let call: PoolCall
    /// В карточке заказа заголовок «Курьер Yumurta», адрес клиента уже есть выше.
    var inOrder = false
    /// Сервер вернул новое состояние вызова (nil — перечитать).
    let onChanged: (PoolCall?) -> Void
    /// А80: создан новый вызов («Выбрать другого водителя») — показать его карточку.
    var onNewCall: ((PoolCall) -> Void)? = nil

    private enum Dialog: Identifiable {
        case cancel, unassign, fee, retry, qrNo
        var id: Int { hashValue }
    }

    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    /// Нейтральное сообщение (А81: «жалоба уже отправлена») — не зелёное, это не успех действия.
    @State private var info: String?
    @State private var dialog: Dialog?
    @State private var reasonText = ""
    @State private var feeText = ""
    @State private var showRate = false
    @State private var showProblem = false
    @State private var showChooseDriver = false
    @State private var showComplaint = false
    /// А81: жалоба получила отказ «вызов изменился» — перечитать вызов, когда окно закроют.
    @State private var complaintStale = false

    var body: some View {
        SectionCard {
            header
            if !inOrder {
                let addr = [call.dropAddress, call.clientPhone].compactMap { $0 }.filter { !$0.isEmpty }
                if !addr.isEmpty {
                    Text(addr.joined(separator: " · ")).font(.subheadline).foregroundColor(Brand.muted)
                }
            }
            // А101: вызов «на потом» ищет до времени забора — срок может быть через несколько часов.
            // Часы раз в 30 с, пока вызов в поиске: когда до конца поиска останется 60 мин и меньше,
            // строка «Ищем курьера до …» уступит прежнему «ждём до ЧЧ:ММ».
            if call.status == "searching" && !call.hasFixedTarget {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    // Две строки — в своём столбце с тем же шагом, что у карточки (SectionCard: 10).
                    VStack(alignment: .leading, spacing: 10) { timeBlock(now: ctx.date) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                timeBlock(now: Date())
            }
            // А80: машина и маршрут — «Кузов M, 300 кг · грузчики: 1 · межгород → …».
            let cargo = call.cargoSummary
            if !cargo.isEmpty {
                Label(cargo, systemImage: "truck.box")
                    .font(.subheadline)
                    .foregroundColor(Brand.text)
            }
            if let t = call.target, call.courier == nil, call.status == "searching" {
                targetLine(t)
            }
            if call.can?.chooseDriver == true {
                Text("Выбранный водитель не подтвердил поездку — выберите другого.")
                    .font(.footnote).foregroundColor(Brand.red)
            }
            if call.status == "searching" && (call.offeredTo ?? 0) == 0 && !call.hasFixedTarget {
                Text("Сейчас на линии нет подходящих курьеров. Как только кто-то выйдет — получит вызов. Можно поднять цену.")
                    .font(.footnote)
                    .foregroundColor(Brand.text)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.amber.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let c = call.courier { courierRow(c) }
            moneyLines
            if let r = call.cancelReason, !r.isEmpty {
                Text("Причина: " + r).font(.caption).foregroundColor(Brand.muted)
            }
            if let r = call.failReason, !r.isEmpty {
                Text("Не доставлен: " + r).font(.footnote).foregroundColor(Brand.red)
            }
            if let r = call.rating, r > 0 {
                Text("Ваша оценка: " + String(repeating: "★", count: min(5, r)))
                    .font(.caption).foregroundColor(Brand.amber)
            }
            // А81: своя жалоба — «Жалоба: Грубил — Рассматривает администратор» (как в веб-кабинете).
            if let p = call.complaint, !p.line.isEmpty {
                Text("Жалоба: " + p.line).font(.caption).foregroundColor(Brand.muted)
            }
            if let e = error {
                Text(e).font(.footnote).foregroundColor(Brand.red)
            }
            if let n = notice {
                Text(n).font(.footnote.weight(.semibold)).foregroundColor(Brand.green)
            }
            if let i = info {
                Text(i).font(.footnote).foregroundColor(Brand.muted)
            }
            actions
        }
        .alert(dialogTitle, isPresented: Binding(get: { dialog != nil }, set: { if !$0 { dialog = nil } }),
               presenting: dialog) { d in
            dialogButtons(d)
        } message: { d in
            Text(dialogMessage(d))
        }
        .sheet(isPresented: $showRate) {
            PoolRateSheet(callId: call.callId) { updated in
                notice = "Спасибо за оценку"
                info = nil
                onChanged(updated)
            }
        }
        .sheet(isPresented: $showProblem) {
            PoolProblemSheet(callId: call.callId) { updated in
                notice = "Отмечено. Администратор рассмотрит"
                info = nil
                onChanged(updated)
            }
        }
        .sheet(isPresented: $showComplaint, onDismiss: {
            // Курьера сняли, срок вышел и т. п. — кнопка могла пропасть: перечитываем.
            if complaintStale { complaintStale = false; onChanged(nil) }
        }) {
            PoolComplaintSheet(callId: call.callId, onDone: { outcome in
                switch outcome {
                case .sent(let updated):
                    complaintStale = false
                    error = nil
                    info = nil
                    notice = "Жалоба отправлена администратору"
                    onChanged(updated)
                case .exists(let message):
                    // Уже жаловались (другой сотрудник, кабинет, касса) — текст сервера и свежая карточка.
                    complaintStale = false
                    error = nil
                    notice = nil
                    info = message
                    onChanged(nil)
                }
            }, onStale: { complaintStale = true })
        }
        // «Выбрать другого водителя» — новый вызов с теми же адресом, машиной и городом.
        .sheet(isPresented: $showChooseDriver) {
            PoolCallSheet(orderId: (call.orderId ?? 0) > 0 ? call.orderId : nil, onDone: { created in
                if let open = onNewCall, created.callId > 0 {
                    open(created)
                } else {
                    notice = "Вызов отправлен"
                    info = nil
                    onChanged(nil)
                }
            }, prefill: call)
        }
    }

    /// «Ждём ответа водителя: Иван П. ★ 4,8 · Кузов M · Газель, белая».
    private func targetLine(_ t: PoolTarget) -> some View {
        var parts: [String] = []
        if let l = t.vehicleLabel, !l.isEmpty { parts.append(l) }
        if let c = t.car, !c.isEmpty { parts.append(c) }
        let name = (t.name ?? "водитель") + (PoolFmt.rating(t.rating).map { " " + $0 } ?? "")
        return VStack(alignment: .leading, spacing: 2) {
            Text("Ждём ответа водителя: " + name).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
            if !parts.isEmpty {
                Text(parts.joined(separator: " · ")).font(.caption).foregroundColor(Brand.muted)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            Text(inOrder ? "Курьер Yumurta" : call.displayTitle)
                .font(.headline)
                .foregroundColor(Brand.text)
            Spacer()
            StatusBadge(text: call.statusText, color: PoolColors.status(call.status))
        }
    }

    /// А101: в поиске и до конца поиска больше 60 мин — «Ищем курьера до ЧЧ:ММ» («до ДД.ММ ЧЧ:ММ»,
    /// если не сегодня) отдельной строкой; иначе nil — «ждём до ЧЧ:ММ» в строке времени, как было.
    /// Выбранный водитель межгорода (ждём его ответа, intercity_wait_min) — тоже как было.
    private func searchUntil(now: Date) -> String? {
        call.status == "searching" && !call.hasFixedTarget ? PoolFmt.searchUntil(call.expiresAt, now: now) : nil
    }

    /// Строка времени и «Ищем курьера до …» на момент now.
    @ViewBuilder
    private func timeBlock(now: Date) -> some View {
        let until = searchUntil(now: now)
        let when = timeline(searchUntil: until)
        if !when.isEmpty {
            Text(when.joined(separator: " · ")).font(.caption).foregroundColor(Brand.muted)
        }
        if let until {
            Text(until).font(.footnote.weight(.semibold)).foregroundColor(Brand.text)
        }
    }

    private func timeline(searchUntil: String?) -> [String] {
        var w: [String] = []
        if let p = call.pickupAt, !p.isEmpty { w.append("забрать к " + PoolFmt.time(p, withDate: call.isIntercity)) }
        if call.status == "searching" {
            var s = "предложено курьерам: \(call.offeredTo ?? 0)"
            if let e = call.expiresAt, !e.isEmpty, searchUntil == nil { s += " · ждём до " + PoolFmt.time(e, withDate: call.isIntercity) }
            w.append(s)
        }
        if let a = call.acceptedAt, !a.isEmpty { w.append("принят " + PoolFmt.time(a)) }
        if let a = call.arrivedAt, !a.isEmpty, call.status == "accepted" { w.append("курьер на месте с " + PoolFmt.time(a)) }
        if let p = call.pickedAt, !p.isEmpty { w.append("забрал " + PoolFmt.time(p)) }
        if let d = call.deliveredAt, !d.isEmpty { w.append("доставлен " + PoolFmt.time(d)) }
        return w
    }

    private func courierRow(_ c: PoolCourierInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if c.hasPhoto == true {
                PoolCourierPhoto(callId: call.callId, courierId: c.userId ?? 0)
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 40))
                    .foregroundColor(Brand.muted)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.name ?? "Курьер").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                    if let r = PoolFmt.rating(c.rating) {
                        Text(r).font(.caption).foregroundColor(Brand.amber)
                    }
                }
                let carLine = [c.carText, (call.vehicleClass ?? "car") != "car" ? (c.vehicleLabel ?? "") : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                if !carLine.isEmpty {
                    Text(carLine).font(.subheadline).foregroundColor(Brand.text)
                }
                if let plate = c.carPlate, !plate.isEmpty {
                    Text(plate.uppercased())
                        .font(.system(.subheadline, design: .monospaced).weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Brand.text.opacity(0.6), lineWidth: 1))
                        .foregroundColor(Brand.text)
                }
                HStack(spacing: 8) {
                    if let phone = c.phone, !phone.isEmpty, let url = PoolFmt.telURL(phone) {
                        Link(destination: url) {
                            Label(phone, systemImage: "phone.fill").font(.subheadline.weight(.semibold))
                        }
                        .foregroundColor(Brand.green)
                    }
                    if let eta = c.etaMinutes, call.isLive {
                        Text("~\(eta) мин").font(.caption).foregroundColor(Brand.muted)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var moneyLines: some View {
        VStack(alignment: .leading, spacing: 4) {
            InfoRow(label: "Курьеру за доставку",
                    value: Money.rub(call.fee) + (call.feePayer == "client" ? " (в счёте клиента)" : " (платит заведение)"))
            if call.paymentMode == "collect" {
                InfoRow(label: "Взять с клиента", value: Money.rub(call.collectAmount))
            } else {
                InfoRow(label: "Оплата", value: "Клиент уже оплатил")
            }
            if call.paidMethod == "cash" {
                Text("Курьер взял наличными — сдаст в заведение").font(.caption).foregroundColor(Brand.muted)
            }
            if call.paidMethod == "qr" {
                Text(qrLine)
                    .font(call.qrConfirmed == true ? .caption : .footnote.weight(.semibold))
                    .foregroundColor(call.qrConfirmed == true ? Brand.muted : Brand.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Строка оплаты по QR. А87: отметка «Не пришла» (qr_missing) — как в расчётах веб-кабинета.
    private var qrLine: String {
        if call.qrConfirmed == true { return "Оплата по QR подтверждена" }
        if call.qrMissing == true {
            let when = (call.qrMissingAt?.isEmpty == false) ? " (" + PoolFmt.short(call.qrMissingAt) + ")" : ""
            return "Оплата по QR — вы отметили: не пришла" + when + " — сумма в долге курьера"
        }
        return "Оплата по QR — проверьте поступление"
    }

    // ── Действия по can ──────────────────────────────────────────────────────
    @ViewBuilder
    private var actions: some View {
        let a = call.can
        let canWork = Session.shared.can("orders")
        if canWork {
            VStack(spacing: 8) {
                if a?.confirmQr == true {
                    HStack(spacing: 8) {
                        actionButton("Оплата по QR пришла", style: .primary) {
                            run("Оплата подтверждена") { try await API.shared.poolConfirmQr(id: call.callId, received: true) }
                        }
                        // А87: после отметки сервер шлёт can.qr_missing = false — «Не пришла» прячем
                        // («Пришла» остаётся). Старый сервер поля не шлёт (nil) — как раньше.
                        if a?.qrMissing != false {
                            actionButton("Не пришла", style: .plain) { dialog = .qrNo }
                        }
                    }
                }
                // Водитель выбран заранее (межгород): цена — по его тарифу, сервер
                // ответил бы 409 target_fixed — кнопки цены не показываем.
                if a?.changeFee == true && !call.hasFixedTarget {
                    actionButton("Поднять цену", style: .secondary) {
                        feeText = PoolFmt.input(call.fee); dialog = .fee
                    }
                }
                if a?.retry == true && !call.hasFixedTarget {
                    actionButton("Повторить поиск", style: .primary) {
                        feeText = PoolFmt.input(call.fee); dialog = .retry
                    }
                }
                if a?.chooseDriver == true {
                    actionButton("Выбрать другого водителя", style: .primary) { showChooseDriver = true }
                }
                if a?.unassign == true {
                    actionButton("Курьер не едет — снять", style: .secondary) { dialog = .unassign }
                }
                if a?.cancel == true {
                    actionButton("Отменить вызов", style: .danger) { reasonText = ""; dialog = .cancel }
                }
                if a?.rate == true && (call.rating ?? 0) == 0 {
                    actionButton("Оценить курьера", style: .secondary) { showRate = true }
                }
                if a?.problem == true {
                    actionButton("Проблема с доставкой", style: .plain) { showProblem = true }
                }
                // А81: жалоба на поведение курьера — без денег (деньги — «Проблема с доставкой»).
                if a?.complain == true {
                    actionButton("Пожаловаться на курьера", style: .plain) { showComplaint = true }
                }
            }
            .disabled(busy)
            .opacity(busy ? 0.6 : 1)
        }
    }

    private enum ButtonKind { case primary, secondary, danger, plain }

    private func actionButton(_ title: String, style: ButtonKind, action: @escaping () -> Void) -> some View {
        let fg: Color, bg: Color
        switch style {
        case .primary: fg = .white; bg = Brand.accent
        case .secondary: fg = Brand.accent; bg = Brand.accent.opacity(0.15)
        case .danger: fg = Brand.red; bg = Brand.red.opacity(0.12)
        case .plain: fg = Brand.text; bg = Brand.chip
        }
        return Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
        }
        .buttonStyle(.borderless)
        .background(bg)
        .foregroundColor(fg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var dialogTitle: String {
        switch dialog {
        case .cancel: return "Отменить вызов курьера?"
        case .unassign: return "Снять курьера?"
        case .fee: return "Новая цена доставки"
        case .retry: return "Повторить поиск"
        case .qrNo: return "Оплата по QR не пришла?"
        case nil: return ""
        }
    }

    private func dialogMessage(_ d: Dialog) -> String {
        switch d {
        case .cancel: return "Причина — необязательно."
        case .unassign: return "Снять курьера с доставки и искать другого?"
        case .fee: return "Цена для курьера, ₽. Вызов разошлём всем заново."
        case .retry: return "Цена доставки для курьера, ₽ (можно поднять)."
        case .qrNo: return "Сумма останется долгом курьера, курьеру придёт уведомление."
        }
    }

    @ViewBuilder
    private func dialogButtons(_ d: Dialog) -> some View {
        switch d {
        case .cancel:
            TextField("Причина", text: $reasonText)
            Button("Отменить вызов", role: .destructive) {
                let r = reasonText.trimmingCharacters(in: .whitespacesAndNewlines)
                run("Вызов отменён") { try await API.shared.poolCancel(id: call.callId, reason: r) }
            }
            Button("Закрыть", role: .cancel) {}
        case .unassign:
            Button("Снять и искать другого", role: .destructive) {
                run("Ищем другого курьера") { try await API.shared.poolUnassign(id: call.callId, reason: "Курьер не едет") }
            }
            Button("Закрыть", role: .cancel) {}
        case .fee, .retry:
            TextField("Цена, ₽", text: $feeText).keyboardType(.decimalPad)
            Button(d == .retry ? "Искать снова" : "Сохранить") {
                let fee = PoolFmt.money(feeText)
                if d == .fee && fee == nil { error = "Укажите новую цену"; return }
                if let f = fee, Money.strict(f) == nil { error = "Проверьте цену доставки"; return }
                run(d == .retry ? "Снова ищем курьера" : "Цена изменена — разослали заново") {
                    try await API.shared.poolChangeFee(id: call.callId, fee: fee)
                }
            }
            Button("Закрыть", role: .cancel) {}
        case .qrNo:
            Button("Не пришла", role: .destructive) {
                run("Курьер уведомлён", okOf: PoolFmt.qrNoMessage) { try await API.shared.poolConfirmQr(id: call.callId, received: false) }
            }
            Button("Закрыть", role: .cancel) {}
        }
    }

    /// okOf — текст по ответу сервера (А87: повторное «Не пришла» — already: true); nil — всегда ok.
    private func run(_ ok: String, okOf: ((PoolCall) -> String)? = nil, _ op: @escaping () async throws -> PoolCall) {
        guard !busy else { return }
        busy = true
        error = nil
        notice = nil
        info = nil
        Task { @MainActor in
            do {
                let updated = try await op()
                busy = false
                notice = okOf?(updated) ?? ok
                onChanged(updated)
            } catch is CancellationError {
                busy = false
            } catch {
                busy = false
                self.error = error.localizedDescription
                // Вызов мог уже измениться (409) — показываем актуальный.
                onChanged(nil)
            }
        }
    }
}

// ── Окно «Вызвать курьера Yumurta» ─────────────────────────────────────────
struct PoolCallSheet: View {
    /// nil — вызов вручную (заказ, принятый по телефону).
    let orderId: Int?
    let onDone: (PoolCall) -> Void
    /// А80: «Выбрать другого водителя» — адрес, машина и город из прежнего вызова.
    let prefill: PoolCall?

    init(orderId: Int?, onDone: @escaping (PoolCall) -> Void, prefill: PoolCall? = nil) {
        self.orderId = orderId
        self.onDone = onDone
        self.prefill = prefill
        _cargo = State(initialValue: prefill.map { PoolCargoState(call: $0) } ?? PoolCargoState())
    }

    @Environment(\.dismiss) private var dismiss
    @State private var quote: PoolQuote?
    @State private var loadError: String?
    @State private var error: String?
    @State private var busy = false
    @State private var filled = false
    @State private var idem = PoolIdemKey(scope: "pool/calls")

    @State private var address = ""
    @State private var phone = ""
    @State private var name = ""
    @State private var goods = ""
    @State private var fee = ""
    @State private var payer = "client"
    @State private var mode = "collect"
    @State private var collect = ""
    @State private var pickupIn = 0
    @State private var comment = ""

    // ── А80: машина, межгород ──────────────────────────────────────────────
    @State private var cargo: PoolCargoState
    @State private var quoteLoading = false
    @State private var quoteError: String?
    /// Ключ последних полученных подсказок — тот же ключ повторно не запрашиваем.
    @State private var queriedKey = ""
    /// +1 — перечитать подсказки (409 price_changed, «Повторить»).
    @State private var refreshTick = 0
    @State private var cities: [PoolCity] = []
    @State private var citiesLoading = false
    @State private var citiesError: String?
    /// Цена из тарифа заведения (легковая по городу — как было).
    @State private var fee0 = ""
    /// Последняя цена, подставленная автоматически: цену, введённую вручную, не перетираем.
    @State private var lastAutoFee = ""
    /// Выбран водитель межгорода — цена по его тарифу, поле только для чтения.
    @State private var feeLocked = false
    /// Ошибки полей из ответа 422.
    @State private var fieldErrors: [String: String] = [:]
    @State private var pickupDate = Date().addingTimeInterval(3600)
    /// Минуты «к дате», уже ушедшие с ключом повтора: повтор после обрыва
    /// уходит с тем же телом (иначе сервер увидит другой запрос с тем же ключом).
    @State private var frozenPickup: FrozenPickup?

    private struct FrozenPickup { let date: Date; let minutes: Int }

    private var manual: Bool { (orderId ?? 0) <= 0 }
    private static let pickupOptions = [0, 10, 15, 20, 30, 45, 60]
    /// А101: сервер знает вызов «на потом» (scheduled_search) — по городу до 4 ч, как в веб-кабинете
    /// (сервер принимает pickup_in_min ≤ 240). Старый сервер — pickupOptions, как было.
    private static let schedPickup = [0, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240]
    /// Межгород — до 7 суток (pickup_in_min до 10080); -1 — своя дата и время.
    private static let intercityPickup = [0, 60, 120, 180, 240, 360, 480, 720, 1440, 2880, 4320, pickAtDate]
    private static let pickAtDate = -1

    private var cargoOn: Bool { quote?.cargoSupported == true }
    /// Цена по машине ещё не посчитана (идёт запрос, ошибка или форму поменяли) —
    /// вызывать нельзя: ушла бы цена прежней машины или минимальная.
    private var priceStale: Bool {
        guard cargoOn else { return false }
        let key = requeryKey
        return quoteLoading || quoteError != nil || (!key.isEmpty && key != queriedKey)
    }
    private var pickupChoices: [Int] {
        if cargoOn && cargo.intercity { return Self.intercityPickup }
        return quote?.scheduledSearch != nil ? Self.schedPickup : Self.pickupOptions
    }

    /// Выбранный водитель межгорода из последних подсказок.
    private var selectedDriver: PoolDriver? {
        guard cargoOn, cargo.intercity, let id = cargo.courierId else { return nil }
        return quote?.drivers?.first { $0.courierId == id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let q = quote {
                    form(q)
                } else if let e = loadError {
                    ErrorBanner(message: e) { Task { await loadQuote() } }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Вызвать курьера Yumurta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .task { if quote == nil { await loadQuote() } }
    }

    private func loadQuote() async {
        loadError = nil
        do {
            // «Выбрать другого водителя»: сразу с прежней машиной и городом.
            let q = try await API.shared.poolQuote(orderId: orderId, extra: prefill != nil ? cargo.query : [:])
            quote = q
            if !filled {
                filled = true
                let d = q.defaults
                fee = PoolFmt.input(d?.fee)
                fee0 = fee
                lastAutoFee = fee
                payer = d?.feePayer == "shop" ? "shop" : "client"
                mode = d?.paymentMode == "prepaid" ? "prepaid" : "collect"
                collect = PoolFmt.input(d?.collectAmount)
                if manual { goods = PoolFmt.input(d?.goodsAmount) }
                if let p = prefill { applyPrefill(p, quote: q) }
                // Без прежнего вызова и своей машины подсказки уже актуальны; иначе — перечитаем.
                if prefill == nil && !cargo.wantsCargo { queriedKey = requeryKey }
                if cargo.intercity && q.cargoSupported { loadCities() }
                applyCargo()
            }
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Данные прежнего вызова (выбранный водитель не подтвердил межгород).
    private func applyPrefill(_ p: PoolCall, quote q: PoolQuote) {
        comment = p.comment ?? ""
        // Межгород выключили или такого кузова больше нет — не застреваем на скрытом выборе.
        if q.cargoSupported {
            if cargo.intercity && q.intercityEnabled != true {
                cargo.trip = "city"
                cargo.destCityId = nil
                cargo.destCityName = ""
            }
            if !(q.vehicles ?? []).contains(where: { $0.code == cargo.vehicleClass }) { cargo.vehicleClass = "car" }
        }
        guard manual else { return }
        address = p.dropAddress ?? ""
        phone = p.clientPhone ?? ""
        name = p.clientName ?? ""
        goods = PoolFmt.input(p.goodsAmount)
        payer = p.feePayer == "shop" ? "shop" : "client"
        mode = p.paymentMode == "prepaid" ? "prepaid" : "collect"
    }

    @ViewBuilder
    private func form(_ q: PoolQuote) -> some View {
        Form {
            if q.enabled == false {
                Section {
                    Text("Курьеры Yumurta сейчас выключены администратором площадки.")
                        .font(.subheadline).foregroundColor(Brand.amber)
                }
            } else if let active = q.order?.activeCallId, active > 0 {
                Section {
                    Text("По этому заказу курьер уже вызван.")
                        .font(.subheadline).foregroundColor(Brand.amber)
                }
            } else {
                formSections(q)
            }
        }
        .scrollContentBackground(.hidden)
        // Вызов вручную: сумма с клиента = товары + доставка, если её платит клиент (как на сайте).
        .onChange(of: goods) { _ in recalc() }
        .onChange(of: fee) { _ in recalc() }
        .onChange(of: payer) { _ in recalc() }
        // А80: подсказки по машине — с паузой после ввода; прежний запрос отменяется.
        .task(id: requeryKey) { await requery(requeryKey) }
        .onChange(of: cargo) { _ in
            fieldErrors = fieldErrors.filter { !PoolCargoFields.all.contains($0.key) }
        }
        .onChange(of: cargo.courierId) { _ in applyCargo() }
        .onChange(of: cargo.trip) { _ in
            if !pickupChoices.contains(pickupIn) { pickupIn = 0 }
            if cargo.intercity && cities.isEmpty { loadCities() }
        }
    }

    @ViewBuilder
    private func formSections(_ q: PoolQuote) -> some View {
        let online = q.couriersOnline ?? 0
        let d = q.defaults
        Section {
            Text(online > 0
                 ? "Курьеров на линии в городе: \(online). Сначала вызов получат ближайшие, через минуту — все. Кто первый нажмёт «Беру» — тот и везёт."
                 : "Сейчас на линии никого нет. Вызов всё равно разошлём — его получит первый, кто выйдет на линию. Ждём \(q.searchMinutes ?? 5) мин"
                    + (q.scheduledSearch != nil ? ", а если забрать позже — до времени забора." : "."))
                .font(.footnote)
                .foregroundColor(online > 0 ? Brand.text : Brand.amber)
            // А81: правило сервиса — плашка (старый сервер rule не шлёт — плашки нет).
            if let rule = q.rule?.trimmingCharacters(in: .whitespacesAndNewlines), !rule.isEmpty {
                PoolRuleBanner(rule: rule)
            }
        }
        if manual {
            Section("Куда и кому") {
                TextField("Адрес: улица, дом, квартира, подъезд", text: $address, axis: .vertical)
                    .lineLimit(2...4)
                fieldError("drop_address")
                TextField("Телефон клиента", text: $phone.phoneInput).keyboardType(.phonePad)
                fieldError("client_phone")
                TextField("Имя клиента", text: $name)
                TextField("Сумма заказа (товары), ₽", text: $goods).keyboardType(.decimalPad)
                fieldError("goods_amount")
            }
        } else if let addr = d?.dropAddress, !addr.isEmpty {
            Section("Куда") {
                Text(addr + (PoolFmt.km(d?.distanceKm).map { " · ~" + $0 } ?? ""))
                    .font(.subheadline)
            }
        }
        if q.cargoSupported {
            cargoSections(q)
        }
        Section {
            TextField("Цена доставки для курьера, ₽", text: $fee)
                .keyboardType(.decimalPad)
                .disabled(feeLocked)
                .foregroundColor(feeLocked ? Brand.muted : Brand.text)
            fieldError("fee")
            Picker("Доставку оплачивает", selection: $payer) {
                Text("Клиент (в его счёте)").tag("client")
                Text("Заведение" + ((d?.freeFrom ?? 0) > 0 ? " (бесплатно от " + Money.rub(d?.freeFrom) + ")" : "")).tag("shop")
            }
            fieldError("fee_payer")
        } header: {
            Text("Курьеру за доставку")
        } footer: {
            Text(feeFooter(q))
        }
        Section {
            Picker("Оплата", selection: $mode) {
                Text("Взять с клиента").tag("collect")
                Text("Клиент уже оплатил").tag("prepaid")
            }
            .pickerStyle(.segmented)
            if mode == "collect" {
                TextField("Сколько взять с клиента, ₽", text: $collect).keyboardType(.decimalPad)
            }
            fieldError("collect_amount")
            fieldError("payment_mode")
        } header: {
            Text("Оплата клиента")
        } footer: {
            if mode == "collect" {
                Text("Наличными — курьер привезёт деньги в заведение; или клиент оплатит по вашему QR СБП"
                     + (q.qrSet == true ? "." : " (загрузите QR в разделе «Курьеры Yumurta»)."))
            }
        }
        pickupSection
        if let e = error {
            Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
        }
        Section {
            Button {
                submit()
            } label: {
                HStack {
                    Spacer()
                    if busy { ProgressView() } else { Label("Вызвать курьера", systemImage: "car.fill").font(.headline) }
                    Spacer()
                }
            }
            .disabled(busy || priceStale)
        } footer: {
            if priceStale && quoteError == nil {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Считаем цену…") }
            } else if quoteError != nil {
                Text("Цена не посчитана — нажмите «Повторить» выше.").foregroundColor(Brand.red)
            }
        }
    }

    /// А80: выбор машины + ошибка подсказок.
    @ViewBuilder
    private func cargoSections(_ q: PoolQuote) -> some View {
        PoolCargoPicker(state: $cargo, quote: q, loading: quoteLoading,
                        fieldErrors: fieldErrors.filter { PoolCargoFields.all.contains($0.key) },
                        cities: cities, citiesLoading: citiesLoading, citiesError: citiesError,
                        loadCities: { loadCities() }, pickupNow: pickupIn == 0)
        if let e = quoteError {
            Section {
                Text("Не удалось обновить цену: " + e).font(.footnote).foregroundColor(Brand.red)
                Button("Повторить") { refreshTick += 1 }
            }
        }
    }

    private var pickupSection: some View {
        Section("Когда забрать") {
            Picker("Когда забрать", selection: $pickupIn) {
                ForEach(pickupChoices, id: \.self) { n in
                    Text(Self.pickupLabel(n)).tag(n)
                }
            }
            if pickupIn == Self.pickAtDate {
                DatePicker("Дата и время", selection: $pickupDate,
                           in: Date().addingTimeInterval(5 * 60)...Date().addingTimeInterval(Double(10080 - 5) * 60),
                           displayedComponents: [.date, .hourAndMinute])
                    .environment(\.locale, Locale(identifier: "ru_RU"))
            }
            // А101: «Ищем курьера до ЧЧ:ММ — за N мин до забора; курьерам напомним…» (старый сервер — нет).
            if let hint = PoolFmt.whenHint(sched: quote?.scheduledSearch, pickupIn: hintMinutes,
                                           searchMinutes: quote?.searchMinutes, driverChosen: selectedDriver != nil) {
                Text(hint).font(.footnote).foregroundColor(Brand.muted)
            }
            fieldError("pickup_in_min")
            TextField("Комментарий курьеру: подъезд, домофон…", text: $comment, axis: .vertical)
                .lineLimit(1...3)
        }
    }

    /// Минуты до забора для подсказки: «Дата и время…» — до выбранного момента.
    private var hintMinutes: Int {
        guard pickupIn == Self.pickAtDate else { return pickupIn }
        return max(0, Int((pickupDate.timeIntervalSinceNow / 60).rounded(.up)))
    }

    private static func pickupLabel(_ n: Int) -> String {
        switch n {
        case pickAtDate: return "Дата и время…"
        case 0: return "Сейчас — заказ готов"
        case 90: return "Через 1,5 ч"
        case 1440: return "Завтра (через сутки)"
        case 2880: return "Через 2 суток"
        case 4320: return "Через 3 суток"
        default: return n <= 60 ? "Через \(n) мин" : "Через \(n / 60) ч"
        }
    }

    @ViewBuilder
    private func fieldError(_ key: String) -> some View {
        if let e = fieldErrors[key], !e.isEmpty {
            Text(e).font(.footnote).foregroundColor(Brand.red)
        }
    }

    private func feeFooter(_ q: PoolQuote) -> String {
        if let d = selectedDriver {
            return "Цена — по тарифу водителя " + (d.name ?? "") + " (" + PoolCargoFmt.rub(d.kmPrice)
                + " за км). Предложение получит только он."
        }
        if q.cargoSupported, let s = q.cargo?.suggestedFee, s > 0 {
            var t = "Подсказка для выбранной машины"
            if let km = q.cargo?.distanceKm, km > 0 { t += " (≈ \(Int(km.rounded())) км)" }
            return t + ", до " + PoolCargoFmt.rub(q.cargo?.maxFee) + ". Можно предложить больше — быстрее возьмут."
        }
        return "От " + Money.rub(q.minFee) + " до " + Money.rub(q.maxFee)
            + ". Курьеру платит заведение — отдайте при получении заказа или пусть оставит из выручки."
    }

    // ── А80: подсказки по машине ────────────────────────────────────────────
    /// Ключ подсказок: машина и город; для межгорода — ещё оплата (водители,
    /// которые могут везти наличные клиента). Пусто — подсказки не нужны.
    private var requeryKey: String {
        guard filled, let q = quote, q.cargoSupported, q.enabled != false,
              (q.order?.activeCallId ?? 0) <= 0 else { return "" }
        var k = cargo.queryKey
        if cargo.intercity { k += "|" + mode + (manual ? "|" + goods + "|" + payer : "") }
        return k + "|#\(refreshTick)"
    }

    /// Параметры quote: машина + оплата (как quote() в seller-pool.js).
    private func quoteParams() -> [String: String] {
        var p = cargo.query
        if mode == "prepaid" {
            p["payment_mode"] = "prepaid"
        } else if manual {
            let g = PoolFmt.money(goods).flatMap { Money.strict($0) } ?? 0
            p["collect_amount"] = "\(g)"
            p["fee_payer"] = payer
        }
        return p
    }

    private func requery(_ key: String) async {
        guard !key.isEmpty else { return }
        // Вернулись к уже полученным подсказкам (прежний запрос отменён) — крутилку снимаем.
        if key == queriedKey { quoteLoading = false; return }
        try? await Task.sleep(nanoseconds: 450_000_000)
        if Task.isCancelled { return }
        quoteLoading = true
        do {
            let q = try await API.shared.poolQuote(orderId: orderId, extra: quoteParams())
            // Пока шёл запрос, форму поменяли — ответ устарел, ждём следующий.
            if Task.isCancelled { return }
            quote = q
            queriedKey = key
            quoteError = nil
            quoteLoading = false
            // Выбранный водитель пропал из списка (сменили кузов, оплату, город) — выбор снимаем явно.
            if let id = cargo.courierId, !(q.drivers ?? []).contains(where: { $0.courierId == id }) {
                cargo.courierId = nil
            }
            applyCargo()
        } catch is CancellationError {
        } catch {
            if Task.isCancelled { return }
            quoteLoading = false
            quoteError = error.localizedDescription
        }
    }

    /// Цена по выбранной машине (onChange в seller-pool.js): водитель — его цена,
    /// поле только для чтения; грузовая/межгород — подсказка, если цену не меняли
    /// руками; легковая по городу — тариф заведения, как было.
    private func applyCargo() {
        guard filled, let q = quote, q.cargoSupported else { return }
        let driver = selectedDriver
        let untouched = fee.isEmpty || fee == lastAutoFee || feeLocked
        let auto: String
        if let t = driver?.total, t > 0 {
            auto = PoolFmt.input(PoolCargoFmt.whole(t))
        } else if driver == nil, let s = q.cargo?.suggestedFee, s > 0 {
            auto = PoolFmt.input(PoolCargoFmt.whole(s))
        } else {
            auto = fee0
        }
        if driver != nil || untouched {
            fee = auto
            lastAutoFee = auto
        }
        feeLocked = driver != nil
    }

    private func loadCities() {
        guard !citiesLoading else { return }
        citiesLoading = true
        citiesError = nil
        Task { @MainActor in
            do {
                cities = try await API.shared.poolCities()
            } catch is CancellationError {
            } catch {
                citiesError = "Не удалось загрузить города: " + error.localizedDescription
            }
            citiesLoading = false
        }
    }

    private func recalc() {
        guard manual, filled else { return }
        let g = PoolFmt.money(goods).flatMap { Money.strict($0) } ?? 0
        let f = PoolFmt.money(fee).flatMap { Money.strict($0) } ?? 0
        collect = PoolFmt.input(g + (payer == "client" ? f : 0))
    }

    /// Ошибки полей 422 — по одному человеческому тексту на поле.
    private static func fieldTexts(_ fields: [String: [String]]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in fields {
            if let m = v.first(where: { SellerErrorText.isHuman($0) }) { out[k] = m }
        }
        return out
    }

    private func submit() {
        guard !busy, !priceStale else { return }
        error = nil
        fieldErrors = [:]
        // Деньги — строго: «1,5,0» и буквы не уходят на сервер.
        for (v, label) in [(fee, "цену доставки"), (collect, "сумму с клиента"), (goods, "сумму заказа")] {
            if let m = PoolFmt.money(v), Money.strict(m) == nil { error = "Проверьте " + label; return }
        }
        if cargoOn && cargo.intercity && (cargo.destCityId ?? 0) <= 0 {
            fieldErrors["dest_city_id"] = "Выберите город доставки"
            error = "Выберите город доставки"
            return
        }
        // «Когда забрать» к дате — минуты от сейчас; для повтора той же формы — те же минуты.
        var pick = pickupIn
        if pickupIn == Self.pickAtDate {
            if let f = frozenPickup, f.date == pickupDate {
                pick = f.minutes
            } else {
                let m = Int((pickupDate.timeIntervalSinceNow / 60).rounded(.up))
                guard m >= 1 else {
                    fieldErrors["pickup_in_min"] = "Выберите время позже текущего"
                    error = "Выберите время позже текущего"
                    return
                }
                pick = min(10080, m)
                frozenPickup = FrozenPickup(date: pickupDate, minutes: pick)
            }
        }
        var payload: [String: Any?] = [
            "fee": PoolFmt.money(fee),
            "fee_payer": payer,
            "payment_mode": mode,
            "pickup_in_min": pick,
        ]
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { payload["comment"] = c }
        if mode == "collect" { payload["collect_amount"] = PoolFmt.money(collect) }
        if let o = orderId, o > 0 {
            payload["order_id"] = o
        } else {
            payload["drop_address"] = address.trimmingCharacters(in: .whitespacesAndNewlines)
            payload["client_phone"] = phone.trimmingCharacters(in: .whitespacesAndNewlines)
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { payload["client_name"] = n }
            payload["goods_amount"] = PoolFmt.money(goods)
        }
        // А80: машина и маршрут — только серверу, который их знает (иначе — как раньше).
        if cargoOn {
            payload["vehicle_class"] = cargo.vehicleClass
            payload["loaders"] = cargo.loaders
            payload["trip"] = cargo.trip
            if let kg = cargo.kg { payload["cargo_kg"] = kg }
            if cargo.intercity { payload["dest_city_id"] = cargo.destCityId ?? 0 }
            if let d = selectedDriver, let id = d.courierId {
                payload["courier_id"] = id
                // Цена, которую видел продавец: изменилась — сервер ответит 409 price_changed.
                if let t = d.total { payload["expected_fee"] = "\(t)" }
            }
        }
        let key = idem.key(for: PoolIdemKey.fingerprint(payload))
        busy = true
        Task { @MainActor in
            do {
                let call = try await API.shared.poolCreateCall(body: payload, idempotencyKey: key)
                idem.settle(after: nil)
                frozenPickup = nil
                busy = false
                onDone(call)
                dismiss()
            } catch is CancellationError {
                busy = false
            } catch {
                idem.settle(after: error)
                if PoolIdemKey.isDefinitive(error) { frozenPickup = nil }
                busy = false
                if let e = error as? APIDetailedError {
                    if e.code == "price_changed" {
                        // Водитель поменял тариф или уточнилась точка: новая цена — сразу
                        // в поле, водители и цены — перечитываем.
                        if selectedDriver != nil,
                           let v = e.fields["fee"]?.first.flatMap({ Decimal(string: $0) }), v > 0 {
                            fee = PoolFmt.input(PoolCargoFmt.whole(v))
                            lastAutoFee = fee
                        }
                        refreshTick += 1
                    } else {
                        fieldErrors = Self.fieldTexts(e.fields)
                    }
                    self.error = e.message
                    return
                }
                self.error = PoolIdemKey.isUnknownOutcome(error)
                    ? "Не известно, создан ли вызов. Проверьте список «Вызовы» в разделе «Курьеры Yumurta», прежде чем вызывать снова."
                    : error.localizedDescription
            }
        }
    }
}

// ── А81: плашка правила сервиса (ruleBox в seller-pool.js) ─────────────────
struct PoolRuleBanner: View {
    let rule: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "nosign")
                .font(.subheadline.weight(.semibold))
            (Text(rule.hasSuffix(".") ? rule : rule + ".").bold() + Text(" Людей и животных курьеры не возят."))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Светло-янтарная, как в вебе (#fef3c7); тёмный текст читается и в тёмной теме.
        .foregroundColor(Color(red: 0x78 / 255, green: 0x35 / 255, blue: 0x0F / 255))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0xFE / 255, green: 0xF3 / 255, blue: 0xC7 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// ── А81: «Пожаловаться на курьера» (openComplaint в seller-pool.js) ────────
/// Причины — complaint_reasons.courier из GET /api/v1/pool/rules (кэш до
/// перезапуска), комментарий обязателен для «Другое». Отказ — текстом в окне,
/// набранное не теряется; 409 complaint_exists — окно закрывается, карточка
/// перечитывается. Это не «Проблема с доставкой»: денег жалоба не касается.
struct PoolComplaintSheet: View {
    enum Outcome {
        case sent(PoolCall)
        case exists(String)
    }

    let callId: Int
    let onDone: (Outcome) -> Void
    /// Отказ «вызов изменился» (409/404/503): карточку перечитать после закрытия окна.
    let onStale: () -> Void

    /// CourierPool::complaintIn: комментарий до 500 символов, для «Другое» — не короче 3.
    static let maxComment = 500
    static let minOther = 3

    @Environment(\.dismiss) private var dismiss
    @State private var rules: PoolRules?
    @State private var loadError: String?
    /// Причину выбирают явно: случайная «пассажиры» по умолчанию — серьёзное обвинение.
    @State private var reason: String?
    @State private var comment = ""
    @State private var busy = false
    @State private var error: String?
    @State private var fieldErrors: [String: String] = [:]

    private var text: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var needComment: Bool { reason == "other" }
    private var valid: Bool {
        rules != nil && reason != nil && (!needComment || text.count >= Self.minOther)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let r = rules {
                    form(r)
                } else if let e = loadError {
                    ErrorBanner(message: e) { Task { await load() } }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Пожаловаться на курьера")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy {
                        ProgressView()
                    } else {
                        Button("Отправить") { send() }.disabled(!valid)
                    }
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .task { if rules == nil { await load() } }
    }

    private func load() async {
        loadError = nil
        do {
            rules = try await API.shared.poolRules()
        } catch is CancellationError {
        } catch {
            loadError = "Не удалось загрузить причины жалобы: " + error.localizedDescription
        }
    }

    @ViewBuilder
    private func form(_ r: PoolRules) -> some View {
        Form {
            Section {
                ForEach(r.courierReasons, id: \.code) { item in
                    Button {
                        reason = item.code
                        fieldErrors["reason"] = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: reason == item.code ? "largecircle.fill.circle" : "circle")
                                .foregroundColor(reason == item.code ? Brand.accent : Brand.muted)
                            Text(item.label).foregroundColor(Brand.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                }
                if let e = fieldErrors["reason"] {
                    Text(e).font(.footnote).foregroundColor(Brand.red)
                }
            } header: {
                Text("Что случилось")
            }
            Section {
                TextField(needComment ? "Опишите, что случилось" : "Необязательно", text: $comment, axis: .vertical)
                    .lineLimit(2...6)
                    .disabled(busy)
                    .onChange(of: comment) { v in
                        if v.count > Self.maxComment { comment = String(v.prefix(Self.maxComment)) }
                        fieldErrors["comment"] = nil
                    }
                if let e = fieldErrors["comment"] {
                    Text(e).font(.footnote).foregroundColor(Brand.red)
                }
            } header: {
                Text("Подробности")
            } footer: {
                Text((needComment ? "Обязательно для «Другое» · " : "") + "\(comment.count)/\(Self.maxComment)")
            }
            Section {
                Text(footerText(r)).font(.footnote).foregroundColor(Brand.muted)
            }
            if let e = error {
                Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func footerText(_ r: PoolRules) -> String {
        var rule = (r.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while rule.hasSuffix(".") { rule.removeLast() }
        return (rule.isEmpty ? "" : rule + ". ")
            + "Жалобу рассмотрит администратор площадки: предупредит или заблокирует курьера. "
            + "Курьер не видит, кто пожаловался. Деньги за испорченный заказ — через «Проблема с доставкой»."
    }

    private func send() {
        // busy — сразу: второй быстрый тап не отправит вторую жалобу.
        guard !busy, valid, let code = reason else { return }
        busy = true
        error = nil
        fieldErrors = [:]
        let body = String(text.prefix(Self.maxComment))
        Task { @MainActor in
            do {
                let updated = try await API.shared.poolComplaint(id: callId, reason: code, comment: body)
                busy = false
                onDone(.sent(updated))
                dismiss()
            } catch is CancellationError {
                busy = false
            } catch let e as APIDetailedError {
                busy = false
                if e.code == "complaint_exists" {
                    onDone(.exists(e.message))
                    dismiss()
                    return
                }
                // Ошибки полей — у полей; общий текст — ниже формы (набранное остаётся).
                var own: [String: String] = [:]
                for k in ["reason", "comment"] {
                    if let m = e.fields[k]?.first(where: { !$0.isEmpty }) { own[k] = m }
                }
                // Сервер не принял причину (текст с кодами по-английски) — понятный текст,
                // а список причин устарел: при следующем открытии перечитаем.
                if own["reason"] != nil {
                    own["reason"] = "Выберите причину из списка"
                    PoolRulesCache.shared.clear()
                }
                fieldErrors = own
                // Все ошибки — у полей: сверху коротко, без повтора тех же текстов.
                let onlyOwn = !own.isEmpty && e.fields.keys.allSatisfy { $0 == "reason" || $0 == "comment" }
                self.error = onlyOwn ? "Проверьте жалобу" : e.message
                if e.status == 409 || e.status == 404 || e.status == 503 { onStale() }
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}

// ── Оценка курьера ──────────────────────────────────────────────────────────
struct PoolRateSheet: View {
    let callId: Int
    let onDone: (PoolCall) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rating = 0
    @State private var comment = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Оценка") {
                    HStack(spacing: 14) {
                        ForEach(1...5, id: \.self) { n in
                            Button {
                                rating = n
                            } label: {
                                Image(systemName: n <= rating ? "star.fill" : "star")
                                    .font(.system(size: 30))
                                    .foregroundColor(Brand.amber)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                Section("Комментарий") {
                    TextField("Необязательно", text: $comment, axis: .vertical).lineLimit(1...4)
                }
                if let e = error {
                    Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Оценка курьера")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.disabled(rating == 0 || busy)
                }
            }
        }
    }

    private func save() {
        busy = true
        error = nil
        let text = String(comment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(255))
        Task { @MainActor in
            do {
                let updated = try await API.shared.poolRate(id: callId, rating: rating, comment: text)
                busy = false
                onDone(updated)
                dismiss()
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}

// ── «Проблема с доставкой» ─────────────────────────────────────────────────
struct PoolProblemSheet: View {
    let callId: Int
    let onDone: (PoolCall) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = "damaged"
    @State private var comment = ""
    @State private var amount = ""
    @State private var photo: UIImage?
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Что случилось") {
                    Picker("Причина", selection: $reason) {
                        ForEach(PoolFmt.problemReasons, id: \.code) { r in
                            Text(r.label).tag(r.code)
                        }
                    }
                    TextField(reason == "other" ? "Опишите, что случилось" : "Подробности", text: $comment, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    TextField("0 — без возмещения", text: $amount).keyboardType(.decimalPad)
                } header: {
                    Text("Сумма к возмещению курьером, ₽")
                } footer: {
                    Text("Сумма сразу ложится в долг курьера. Курьер получит уведомление, окончательное решение — за администратором площадки.")
                }
                Section("Фото (необязательно)") {
                    if let photo {
                        HStack {
                            Image(uiImage: photo).resizable().scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Spacer()
                            Button("Убрать", role: .destructive) { self.photo = nil }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button {
                        showCamera = true
                    } label: {
                        Label("Сфотографировать", systemImage: "camera")
                    }
                    .sheet(isPresented: $showCamera) {
                        CameraPicker { img in photo = img }
                    }
                    Button {
                        showLibrary = true
                    } label: {
                        Label("Выбрать из галереи", systemImage: "photo")
                    }
                    .sheet(isPresented: $showLibrary) {
                        PhotoLibraryPicker(onPick: { img in photo = img }, onFail: { msg in error = msg })
                    }
                }
                if let e = error {
                    Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Проблема с доставкой")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Отправить") { send() }.disabled(busy)
                }
            }
        }
    }

    private func send() {
        error = nil
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason == "other" && text.isEmpty { error = "Опишите, что случилось"; return }
        let sum = PoolFmt.money(amount) ?? "0"
        guard Money.strict(sum) != nil else { error = "Проверьте сумму возмещения"; return }
        let picked = photo
        busy = true
        Task { @MainActor in
            // Сжатие фото — вне главного потока: на главном экран подвисал.
            let jpeg = await Task.detached(operation: { picked.flatMap { ImageCompressor.jpegForUpload($0) } }).value
            do {
                let updated = try await API.shared.poolProblem(id: callId, reason: reason, comment: String(text.prefix(500)),
                                                               amount: sum, photoJPEG: jpeg)
                busy = false
                onDone(updated)
                dismiss()
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}

// ── Блок в карточке заказа ──────────────────────────────────────────────────
/// pool_call (последний вызов) и pool_call_available (показать кнопку) из
/// GET /api/seller/orders/{id}. Старый сервер полей не шлёт — блока нет.
struct PoolOrderBlock: View {
    let orderId: Int
    let call: PoolCall?
    let available: Bool
    /// Перечитать заказ (вызов изменился или создан).
    let reload: () -> Void

    @State private var showCall = false

    var body: some View {
        let canCall = available && Session.shared.can("orders")
        if call != nil || canCall {
            VStack(spacing: 14) {
                if let c = call {
                    PoolCallCard(call: c, inOrder: true) { _ in reload() }
                }
                if canCall {
                    SectionCard(title: "Курьер Yumurta") {
                        Text("Нет своего курьера? Вызовите курьера площадки — водители и курьеры на линии в вашем городе.")
                            .font(.footnote)
                            .foregroundColor(Brand.muted)
                        Button {
                            showCall = true
                        } label: {
                            Label("Вызвать курьера Yumurta", systemImage: "car.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.borderless)
                        .background(Brand.accent)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .sheet(isPresented: $showCall) {
                PoolCallSheet(orderId: orderId) { _ in reload() }
            }
        }
    }
}
