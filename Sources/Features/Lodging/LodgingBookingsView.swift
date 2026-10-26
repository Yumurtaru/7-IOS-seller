import SwiftUI
import Combine

// ============================================================================
//  Брони жилья: кто заезжает сегодня, подтверждение, заселение, выселение.
// ----------------------------------------------------------------------------
//  Кнопки показываются ровно по переходам, которые разрешает сервер
//  (routes/seller_lodging.php), и только при нужном праве:
//      держим (hold)  → Подтвердить | Отменить      (заселить нельзя)
//      ожидает        → Подтвердить | Заселить | Отменить
//      подтверждена   → Заселить | Незаезд* | Отменить*
//      гость заехал   → Выселить
//  * по датам: незаезд — от дня заезда до конца проживания, отмена — только
//    до дня заезда (Lodging::cancelBlocked).
//  Иначе продавец жал бы кнопку и получал 422 «Из статуса … так нельзя».
//
//  Удержание при незаезде считает сервер и возвращает в ответе — показываем
//  его как есть, сами ничего не считаем.
// ============================================================================

@MainActor
final class LodgingBookingsViewModel: ObservableObject {
    @Published var items: [LodgingBooking] = []
    @Published var today: LodgingToday?
    @Published var status: String = ""
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var info: String?

    /// Запрос в полёте: быстрое переключение чипов давало гонку — ответ по
    /// «Ожидают» приходил последним и перезатирал список «Заселены».
    private var task: Task<Void, Never>?

    func load() async {
        task?.cancel()
        if items.isEmpty { state = .loading }
        error = nil
        info = nil
        let asked = status
        let t = Task { @MainActor in
            await self.reload(asked)
        }
        task = t
        await t.value
    }

    private func reload(_ asked: String) async {
        do {
            let resp = try await API.shared.lodgingBookings(status: asked.isEmpty ? nil : asked)
            // Ответ устаревшего запроса не применяем.
            guard !Task.isCancelled, asked == status else { return }
            items = resp.items ?? []
            today = resp.today
            state = .loaded
        } catch is CancellationError {
        } catch {
            // Ошибка запроса по прежнему чипу — уже не про то, что на экране.
            guard asked == status else { return }
            if items.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    func setStatus(_ s: String) {
        // Новый чип — старые брони убираем: при сбое под «Заселены» оставались «Ожидают».
        if s != status { items = [] }
        status = s
        Task { await load() }
    }

    /// Бронь, по которой уже идёт переход: двойное «Подтвердить» слало два.
    @Published var actingId: Int?
    /// true — переход принят сервером. Окно причины отмены/незаезда ждёт этого
    /// ответа: раньше оно закрывалось сразу, и при отказе набранная причина пропадала.
    @discardableResult
    func apply(_ booking: LodgingBooking, _ to: String, note: String? = nil) async -> Bool {
        // Старую ошибку сбрасываем: окно причины показывает error ?? info,
        // и при занятости вместо «Дождитесь…» всплывала прошлая ошибка.
        guard actingId == nil else { error = nil; info = "Дождитесь завершения предыдущего действия"; return false }
        actingId = booking.id
        defer { actingId = nil }
        error = nil
        info = nil
        do {
            let ack = try await API.shared.setLodgingBookingStatus(id: booking.id, status: to, note: note)
            // Три РАЗНЫЕ вещи (см. Lodging::cancel): penalty — сколько объект
            // ВПРАВЕ взять с гостя, paid — сколько реально прошло через
            // площадку, refund — возврат из полученного. За проживание площадка
            // денег не принимает, поэтому обычно paid = 0, и говорить
            // «удержано» нельзя: продавец решал, что деньги уже списаны, и не
            // выставлял счёт гостю сам.
            let paid = ack.paid ?? 0
            if let p = ack.penalty, p > 0 {
                if paid >= p {
                    info = "Удержано \(Money.rub(p))"
                        + ((ack.refund ?? 0) > 0 ? ", гостю возвращается \(Money.rub(ack.refund))" : "")
                } else if paid > 0 {
                    // Через площадку прошло меньше удержания: разница остаётся
                    // требованием объекта к гостю, а не списанием.
                    info = "Удержано \(Money.rub(paid)) из \(Money.rub(p)) — остаток объект вправе взять с гостя сам"
                } else {
                    info = "Объект вправе удержать \(Money.rub(p)) — через площадку оплаты не было, счёт гостю выставляете сами"
                }
            } else if (ack.refund ?? 0) > 0 {
                info = "Гостю возвращается \(Money.rub(ack.refund))"
            }
            // load() начинает с error = nil; info = nil — раньше текст об
            // удержании и возврате стирался, не успев появиться. Ставим после.
            let note = info
            await load()
            info = note
            return true
        } catch {
            let msg = error.localizedDescription
            // 409 «статус только что изменился» — список надо перечитать.
            await load()
            // Ошибку — после перезагрузки: иначе она стиралась, и кнопка
            // «Заселить» на 403/409/422 выглядела неработающей.
            self.error = msg
            return false
        }
    }

    /// keys — ключи повтора окна брони (живут, пока окно открыто).
    func createCounter(_ body: [String: Any?], keys: IdempotencyKeys? = nil) async -> Bool {
        error = nil
        do {
            let ack = try await API.shared.createLodgingBooking(body, keys: keys)
            await load()
            info = "Бронь создана на \(Money.rub(ack.total))"
            return true
        } catch {
            var msg = error.localizedDescription
            // Обрыв связи или таймаут: бронь могла уже создаться и занять даты.
            // Раньше список не перечитывался, и повторное «Создать бронь» давало
            // вторую бронь (или «всё занято» без объяснения). Перечитываем и
            // просим сверить список перед повтором. load() стирает error — текст после.
            if let e = error as? APIError {
                switch e {
                case .network, .timeout:
                    msg += ". Бронь могла создаться — проверьте список броней, прежде чем создавать снова."
                    await load()
                default: break
                }
            }
            self.error = msg
            return false
        }
    }
}

struct LodgingBookingsView: View {
    @StateObject private var vm = LodgingBookingsViewModel()
    @EnvironmentObject var poller: NewOrderPoller
    @EnvironmentObject var router: DeepLinkRouter
    @State private var sheet: LodgingBookingsSheet?

    private let filters: [(String, String)] = [
        ("", "Все"),
        ("pending", "Ожидают"),
        ("confirmed", "Подтверждены"),
        ("checked_in", "Заселены"),
        ("checked_out", "Выехали"),
        ("cancelled", "Отменены"),
        // Сервер принимает и эти два, а без чипов их было видно только в «Все».
        ("no_show", "Незаезды"),
        ("hold", "Держим"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let err = vm.error { InlineErrorBar(message: err) }
                if let ok = vm.info {
                    Text(ok).font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Brand.green)
                }
                todayBar
                filterRow
                List {
                    ForEach(vm.items) { b in
                        LodgingBookingCard(booking: b) { to in
                            if to == "cancelled" || to == "no_show" {
                                sheet = .note(LodgingNoteTarget(booking: b, status: to))
                            } else {
                                Task { await vm.apply(b, to) }
                            }
                        }
                        .listRowBackground(Brand.card)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable { await vm.load() }
                .listState(vm.state, isEmpty: vm.items.isEmpty,
                           emptyIcon: "calendar.badge.clock", emptyTitle: "Броней нет",
                           emptySubtitle: "Здесь появятся заявки гостей и брони, созданные от стойки",
                           retry: { Task { await vm.load() } })
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Брони")
            .toolbar {
                ToolbarItem(placement: .principal) { ShopSwitcherMenu() }
                // Бронь от стойки занимает даты — сервер требует право
                // «Заказы → смена статуса»; без него кнопка давала 403.
                if Session.shared.can("orders.status") {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        // Лист показывает vm.error: ошибка прошлого действия со
                        // списка («Заселить» и т.п.) не должна выглядеть отказом брони.
                        Button { vm.error = nil; sheet = .counter } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(item: $sheet) { route in
                switch route {
                case .note(let t):
                    LodgingNoteSheet(target: t, vm: vm)
                case .counter:
                    LodgingCounterBookingSheet(vm: vm)
                }
            }
            .task { await vm.load() }
            // Поллер нашёл новую бронь — открытый список перечитываем сам,
            // иначе звенело, а на экране её не было до «потянуть вниз».
            .onChange(of: poller.newCount) { n in
                if n > 0 { Task { await vm.load() } }
            }
            // Из фона — перечитываем: «Заезды/Выезды сегодня» и кнопки по датам
            // оставались вчерашними, отмены гостей не были видны до «потянуть вниз».
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await vm.load() }
            }
            // Push о брони (новая, отмена гостем, заявка) без type: на открытом
            // приложении поллер его не видит, и тап давал старый список.
            // Перечитываем и показываем «Все», чтобы бронь не пряталась за чипом.
            .onReceive(router.$requestedTab.receive(on: DispatchQueue.main)) { t in
                guard t == "orders" else { return }
                if vm.status.isEmpty { Task { await vm.load() } } else { vm.setStatus("") }
            }
        }
    }

    private var todayBar: some View {
        HStack(spacing: 0) {
            todayCell("Заезды", vm.today?.arrivals ?? 0, Brand.accent)
            todayCell("Выезды", vm.today?.departures ?? 0, Brand.amber)
            todayCell("Проживают", vm.today?.staying ?? 0, Brand.green)
        }
        .padding(.vertical, 10)
        .background(Brand.card)
    }

    private func todayCell(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.bold)).foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.0) { key, label in
                    FilterChip(title: label, selected: vm.status == key) { vm.setStatus(key) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

/// Листы экрана — одним .sheet(item:): несколько .sheet на одном view
/// SwiftUI отрабатывает непредсказуемо.
enum LodgingBookingsSheet: Identifiable {
    case note(LodgingNoteTarget)
    case counter

    var id: String {
        switch self {
        case .note(let t): return "note-\(t.id)"
        case .counter:     return "counter"
        }
    }
}

/// Бронь + статус, в который её переводят: нужен комментарий (причина).
struct LodgingNoteTarget: Identifiable {
    let booking: LodgingBooking
    let status: String
    var id: String { "\(booking.id)-\(status)" }
}

private struct LodgingBookingCard: View {
    let booking: LodgingBooking
    let onAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(booking.unitTitle ?? "Объект")
                        .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                    Text("\(LodgingFormat.fullDate(booking.dateFrom)) — \(LodgingFormat.fullDate(booking.dateTo)) · \(LodgingFormat.nights(booking.nights))")
                        .font(.caption).foregroundColor(Brand.muted)
                    Text(LodgingFormat.guests(booking.adults, booking.children)
                         + ((booking.rooms ?? 1) > 1 ? " · \(LodgingFormat.rooms(booking.rooms))" : ""))
                        .font(.caption).foregroundColor(Brand.muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Money.rub(booking.total)).font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.text)
                    LodgingPill(text: LodgingFormat.statusTitle(booking),
                                color: LodgingFormat.statusColor(booking.status))
                }
            }
            if let name = booking.guestName, !name.isEmpty {
                Text(name + (booking.guestPhone.map { " · \($0)" } ?? ""))
                    .font(.footnote).foregroundColor(Brand.text)
            }
            if let plan = booking.ratePlan, !plan.isEmpty {
                Text("Тариф: \(plan)").font(.caption).foregroundColor(Brand.muted)
            }
            if (booking.touristTax ?? 0) > 0 {
                Text("Туристический налог \(Money.rub(booking.touristTax)) — гость платит на месте")
                    .font(.caption).foregroundColor(Brand.muted)
            }
            if (booking.prepay ?? 0) > 0 {
                Text("Предоплата \(Money.rub(booking.prepay))"
                     + (booking.paymentStatus == "paid" ? " — оплачена" : " — не оплачена"))
                    .font(.caption)
                    .foregroundColor(booking.paymentStatus == "paid" ? Brand.green : Brand.amber)
            }
            if let c = booking.guestComment, !c.isEmpty {
                Text("Гость: \(c)").font(.caption).foregroundColor(Brand.muted)
            }
            if let n = booking.sellerNote, !n.isEmpty {
                Text("Заметка: \(n)").font(.caption).foregroundColor(Brand.muted)
            }
            if !actions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(actions, id: \.0) { status, title, color in
                            LodgingActionButton(title: title, color: color) { onAction(status) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Только переходы, которые разрешает сервер для текущего статуса И для
    /// текущей даты (Lodging::cancelBlocked):
    ///   • «Незаезд» — не раньше дня заезда и не позже конца проживания;
    ///   • «Отменить» подтверждённую — только до дня заезда, дальше сервер
    ///     отвечает «отметьте Заселён или Незаезд».
    /// Без этих окон продавец жал кнопку и получал 422 на ровном месте.
    private var actions: [(String, String, Color)] {
        // «Сегодня» по Москве: окна разрешённых действий сервер считает по
        // своему времени (DateFmt.ymdMoscow — тот же приём, что в продажах
        // кассы). У телефона в другом поясе кнопка появлялась бы на сутки
        // раньше или позже сервера.
        let today = DateFmt.ymdMoscow(Date())
        let from = String((booking.dateFrom ?? "").prefix(10))
        let to = String((booking.dateTo ?? "").prefix(10))
        // Права ровно те, что проверяет сервер: отмена и незаезд — «Отмена
        // заказов», остальные переходы — «Смена статуса». Иначе сотрудник жал
        // кнопку и получал «Недостаточно прав».
        let canStatus = Session.shared.can("orders.status")
        let canCancel = Session.shared.can("orders.cancel")
        var out: [(String, String, Color)] = []
        switch booking.status ?? "" {
        case "hold":
            // Из «Держим» сервер разрешает только подтверждение и отмену:
            // заселить неподтверждённую бронь нельзя.
            if canStatus { out.append(("confirmed", "Подтвердить", Brand.accent)) }
            if canCancel { out.append(("cancelled", "Отменить", Brand.red)) }
        case "pending":
            if canStatus {
                out.append(("confirmed", "Подтвердить", Brand.accent))
                out.append(("checked_in", "Заселить", Brand.green))
            }
            if canCancel { out.append(("cancelled", "Отменить", Brand.red)) }
        case "confirmed":
            if canStatus { out.append(("checked_in", "Заселить", Brand.green)) }
            if canCancel && today >= from && today <= to {
                out.append(("no_show", "Незаезд", Brand.amber))
            }
            if canCancel && today <= from {
                out.append(("cancelled", "Отменить", Brand.red))
            }
        case "checked_in":
            if canStatus { out.append(("checked_out", "Выселить", Brand.accent)) }
        default:
            break
        }
        return out
    }
}

/// Причина отмены или незаезда — уходит в заметку брони и в письмо гостю.
private struct LodgingNoteSheet: View {
    let target: LodgingNoteTarget
    @ObservedObject var vm: LodgingBookingsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    /// Окно закрывается только после ответа сервера: раньше оно закрывалось
    /// сразу, отказ (403/409/422, нет связи) уходил в полосу под листом, а
    /// набранная причина для гостя пропадала — её приходилось писать заново.
    @State private var sending = false
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Причина (её увидит гость)", text: $note, axis: .vertical).lineLimit(2...5)
                } footer: {
                    Text(target.status == "no_show"
                         ? "Незаезд: сервер посчитает удержание по правилам объекта и вернёт остаток гостю."
                         : "Отмена объектом — без удержания с гостя: оплаченное вернётся ему полностью.")
                }
                Section {
                    if let e = sendError {
                        Text(e).font(.footnote).foregroundColor(Brand.red)
                    }
                    Button(role: .destructive) {
                        guard !sending else { return }
                        sending = true
                        sendError = nil
                        let text = note
                        Task {
                            let ok = await vm.apply(target.booking, target.status, note: text)
                            sending = false
                            if ok { dismiss() } else { sendError = vm.error ?? vm.info }
                        }
                    } label: {
                        HStack {
                            Text(target.status == "no_show" ? "Отметить незаезд" : "Отменить бронь")
                            if sending { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(sending)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(target.status == "no_show" ? "Незаезд" : "Отмена брони")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Назад") { dismiss() } } }
        }
        // Причину для гостя смахивание листа вниз стирало без вопроса — её
        // писали заново. С набранным текстом закрыть — только кнопкой «Назад».
        .interactiveDismissDisabled(sending || !note.isEmpty)
    }
}

/// Бронь «от стойки»: гость позвонил или пришёл. Оплата — на месте, поэтому
/// заказ и комиссия площадки тут не создаются (так сделано на сервере).
private struct LodgingCounterBookingSheet: View {
    @ObservedObject var vm: LodgingBookingsViewModel
    @Environment(\.dismiss) private var dismiss
    /// Ключ повтора — на это окно брони (закрыли — пропал).
    @State private var idem = IdempotencyKeys.form()

    @State private var units: [LodgingUnit] = []
    @State private var unitsError: String?
    @State private var unitId: Int = 0
    @State private var from = Date()
    @State private var to = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var adults = 2
    @State private var children = 0
    @State private var rooms = 1
    @State private var guestName = ""
    @State private var guestPhone = ""
    @State private var comment = ""
    @State private var plans: [LodgingRatePlan] = []
    @State private var planId: Int = 0
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Только опубликованные и сдающиеся посуточно: по остальным
                    // сервер отвечает 409 («Объект снят с публикации» /
                    // «сдаётся только на длительный срок») — и делал это уже
                    // после того, как администратор заполнил всю форму.
                    Picker("Объект", selection: $unitId) {
                        Text("Выберите").tag(0)
                        ForEach(units) { u in Text(u.unitTitle).tag(u.id) }
                    }
                    if !plans.isEmpty {
                        Picker("Тариф", selection: $planId) {
                            Text("Базовый").tag(0)
                            ForEach(plans) { p in Text(p.name ?? "Тариф").tag(p.id) }
                        }
                    }
                } header: {
                    Text("Объект")
                } footer: {
                    if let e = unitsError {
                        Text(e).foregroundColor(Brand.red)
                    } else if units.isEmpty {
                        Text("Нет объектов, которые можно забронировать: нужен опубликованный объект с посуточной сдачей.")
                    }
                }
                Section {
                    // Прошедшие даты сервер не принимает («Эти даты уже прошли»),
                    // выезд — строго позже заезда.
                    DatePicker("Заезд", selection: $from, in: Date()..., displayedComponents: .date)
                    // Нижняя граница — следующий день: выезд в день заезда колесо
                    // давало выбрать, а «Создать бронь» молча становилась серой.
                    DatePicker("Выезд", selection: $to, in: minCheckout..., displayedComponents: .date)
                } header: {
                    Text("Даты")
                }
                Section("Гости") {
                    Stepper("Взрослых: \(adults)", value: $adults, in: 1...20)
                    Stepper("Детей: \(children)", value: $children, in: 0...20)
                    Stepper("Номеров: \(rooms)", value: $rooms, in: 1...20)
                }
                Section {
                    TextField("Имя гостя", text: $guestName)
                    TextField("Телефон", text: $guestPhone.phoneInput).keyboardType(.phonePad)
                    TextField("Комментарий", text: $comment, axis: .vertical).lineLimit(2...4)
                } header: {
                    Text("Гость")
                } footer: {
                    Text("Бронь сразу подтверждена и занимает даты в календаре. Оплата — на месте: заказ и сервисный сбор площадки по ней не создаются.")
                }
                Section {
                    // Ошибку показываем здесь: баннер родительского экрана
                    // спрятан под листом, и отказ сервера («На эти даты всё
                    // занято», «Минимальный срок проживания больше») выглядел
                    // как сломанная кнопка — форма просто не закрывалась.
                    if let err = vm.error {
                        Text(err).font(.footnote).foregroundColor(Brand.red)
                    }
                    if datesInPast {
                        Text("Заезд не может быть в прошлом по времени площадки (Москва).")
                            .font(.footnote).foregroundColor(Brand.red)
                    }
                    // Причина серой кнопки: выбран пункт «Выберите» вместо объекта.
                    if unitId == 0 && !units.isEmpty {
                        Text("Выберите объект — без него бронь не создать.")
                            .font(.footnote).foregroundColor(Brand.amber)
                    }
                    Button {
                        Task { await save() }
                    } label: {
                        HStack { Spacer(); if isSaving { ProgressView() } else { Text("Создать бронь").bold() }; Spacer() }
                    }
                    .disabled(isSaving || unitId == 0 || datesInPast
                              || LodgingFormat.iso(to) <= LodgingFormat.iso(from))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Бронь от стойки")
            .navigationBarTitleDisplayMode(.inline)
            // Пока бронь уходит — не закрываем (ключ повтора живёт с окном).
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() }.disabled(isSaving) } }
            .task {
                do {
                    let resp = try await API.shared.lodgingUnits()
                    // Фильтр здесь, а не в списке: подставлять первый объект по
                    // порядку нельзя — им запросто окажется черновик.
                    units = (resp.items ?? []).filter {
                        ($0.isActive ?? 0) == 1 && ($0.rentDaily ?? 1) == 1
                    }
                } catch {
                    // Список объектов закрыт правом «Товары», а бронь — правом
                    // «Заказы»: у администратора стойки без «Товаров» сервер
                    // ответит 403, и об этом надо сказать прямо.
                    unitsError = error.localizedDescription
                }
                if unitId == 0, let first = units.first { unitId = first.id }
                await loadPlans()
            }
            .onChange(of: unitId) { _ in
                planId = 0
                Task { await loadPlans() }
            }
            .onChange(of: from) { newFrom in
                // Выезд не может быть раньше заезда: сдвигаем на сутки вперёд.
                if LodgingFormat.iso(to) <= LodgingFormat.iso(newFrom) {
                    to = Calendar.current.date(byAdding: .day, value: 1, to: newFrom) ?? newFrom
                }
            }
            // Паритет с Android: длины — как у сервера (гость 190, телефон 32,
            // комментарий 1000); длиннее сервер молча обрезает.
            .onChange(of: guestName) { v in if v.count > 190 { guestName = String(v.prefix(190)) } }
            .onChange(of: guestPhone) { v in if v.count > 32 { guestPhone = String(v.prefix(32)) } }
            .onChange(of: comment) { v in if v.count > 1000 { comment = String(v.prefix(1000)) } }
        }
        // Гость на телефоне диктует данные: случайное смахивание листа стирало
        // имя, телефон и комментарий без вопроса. Закрыть — кнопкой «Отмена».
        .interactiveDismissDisabled(isSaving || !guestName.isEmpty || !guestPhone.isEmpty || !comment.isEmpty)
    }

    /// Сервер сравнивает дату заезда со своим «сегодня» (МСК). У телефона
    /// западнее Москвы поздним вечером выбранное «сегодня» уходило вчерашним
    /// числом и получался отказ «Эти даты уже прошли».
    private var datesInPast: Bool {
        LodgingFormat.iso(from) < DateFmt.ymdMoscow(Date())
    }

    /// Самый ранний выезд — начало следующего за заездом дня (сервер требует
    /// выезд строго позже заезда). Начало дня — чтобы время суток не мешало.
    private var minCheckout: Date {
        let cal = LodgingFormat.gregorian
        return cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: from)) ?? from
    }

    @MainActor private func loadPlans() async {
        guard unitId > 0 else { plans = []; return }
        let asked = unitId
        // Выключенные тарифы сервер при брони игнорирует (берёт только
        // is_active = 1) — бронь молча уходила по базовой цене, а стойка была
        // уверена, что продала «С завтраком». В списке их не показываем.
        let all = (try? await API.shared.lodgingRatePlans(unitId: asked)) ?? []
        // Объект успели сменить — тарифы прежнего не подставляем (ушёл бы чужой rate_plan_id).
        guard asked == unitId else { return }
        plans = all.filter { ($0.isActive ?? 1) == 1 }
    }

    @MainActor private func save() async {
        // Двойной тап «Создать бронь» создавал две брони.
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        var body: [String: Any?] = [
            "unit_id": unitId,
            "date_from": LodgingFormat.iso(from),
            "date_to": LodgingFormat.iso(to),
            "adults": adults,
            "children": children,
            "rooms": rooms,
            "guest_name": guestName,
            "guest_phone": guestPhone,
            "guest_comment": comment,
        ]
        if planId > 0 { body["rate_plan_id"] = planId }
        if await vm.createCounter(body, keys: idem) { dismiss() }
    }
}
