import SwiftUI
import Combine

// ============================================================================
//  Записи (type=service) — GET /api/seller/bookings (+фильтр статуса)
//  и POST /api/seller/bookings/{slot}/status (accepted | done | cancelled).
//  Запись = заказ, привязанный к слоту (service_slots.order_id).
// ============================================================================

@MainActor
final class BookingsViewModel: ObservableObject {
    @Published var items: [Booking] = []
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var statusFilter: String? {
        didSet { if statusFilter != oldValue { items = []; state = .loading; loadGen += 1; Task { await load() } } }
    }
    @Published var actionError: String?
    /// Пояснение после действия (не ошибка): например, «не пришёл» отмечен
    /// позже дня визита, и сервер закрыл запись как выполненную.
    @Published var actionNotice: String?

    static let statusChips: [(String?, String)] = [
        (nil, "Все"), ("new", "Новые"), ("accepted", "Подтверждены"),
        ("done", "Выполнены"), ("cancelled", "Отменены"),
    ]

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        do {
            let fresh = try await API.shared.bookings(status: statusFilter)
            guard myGen == loadGen else { return }
            items = fresh
            state = .loaded
            NewOrderPoller.shared.acknowledge()
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Переход уже идёт: двойное «Подтвердить» слало два, второй — с ошибкой.
    @Published var acting = false
    func setStatus(_ booking: Booking, to status: String) async {
        guard !acting else { return }
        acting = true
        defer { acting = false }
        actionError = nil
        actionNotice = nil
        do {
            let ack = try await API.shared.setBookingStatus(slotId: booking.slotId ?? 0, orderId: booking.orderId, status: status)
            // Отмену записи прошедшего дня сервер закрывает как ВЫПОЛНЕННУЮ
            // (routes/seller_services.php: late_no_show) — без пояснения запись
            // молча уезжала в «Выполнены».
            if status == "cancelled", ack.status == "done" {
                actionNotice = "Визит был не сегодня: «не пришёл» отмечается только в день визита, поэтому запись закрыта как выполненная"
            }
            await load()
        } catch {
            actionError = error.localizedDescription
            // «Недопустимый переход» (клиент отменил запись, её подтвердили с
            // другого телефона) или обрыв, при котором статус мог смениться:
            // перечитываем список — иначе кнопки старого статуса оставались, и
            // каждое нажатие давало ту же ошибку.
            await load()
        }
    }

    /// Группировка по датам для календарного вида списка.
    var grouped: [(date: String, bookings: [Booking])] {
        let dict = Dictionary(grouping: items) { $0.date ?? "" }
        return dict.keys.sorted(by: >).map { (date: $0, bookings: dict[$0] ?? []) }
    }
}

struct BookingsView: View {
    @StateObject private var vm = BookingsViewModel()
    @EnvironmentObject var router: DeepLinkRouter
    @EnvironmentObject var poller: NewOrderPoller
    @State private var chatOrderId: Int?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                chips
                if let err = vm.actionError { InlineErrorBar(message: err) }
                if let note = vm.actionNotice {
                    Text(note)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Brand.amber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                }
                List {
                    ForEach(vm.grouped, id: \.date) { group in
                        Section(DateFmt.day(group.date)) {
                            ForEach(group.bookings) { booking in
                                BookingRow(booking: booking,
                                           onStatus: { s in Task { await vm.setStatus(booking, to: s) } },
                                           onChat: { if let oid = booking.orderId { chatOrderId = oid } },
                                           busy: vm.acting)
                                    .listRowBackground(Brand.card)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .refreshable { await vm.load() }
                .listState(vm.state, isEmpty: vm.items.isEmpty,
                           emptyIcon: "calendar.badge.clock", emptyTitle: "Записей нет",
                           emptySubtitle: "Новые записи клиентов появятся здесь",
                           retry: { Task { await vm.load() } })
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Записи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { ShopSwitcherMenu() } }
            .sheet(isPresented: Binding(
                get: { chatOrderId != nil },
                set: { if !$0 { chatOrderId = nil } }
            )) {
                // .id: push о чате другой записи при открытом чате менял только
                // chatOrderId — лист оставался прежним, и переписка (и отправка)
                // шла в чат старой записи. С новым id экран чата создаётся заново.
                if let oid = chatOrderId { OrderChatView(orderId: oid).id(oid) }
            }
            .task { await vm.load() }
            // Поллер нашёл новую запись — открытый список перечитываем сам,
            // иначе звенело, а записи на экране не было до «потянуть вниз».
            .onChange(of: poller.newCount) { n in
                if n > 0 { Task { await vm.load() } }
            }
            // Push «новая запись» на открытом приложении: счётчик мог вернуться к
            // тому же числу (1→0→1), onChange(newCount) молчал — список оставался старым.
            .onChange(of: poller.pushArrivals) { _ in
                Task { await vm.load() }
            }
            // Из фона — перечитываем: отмены клиентов за это время не были видны,
            // и «Подтвердить» у отменённой записи заканчивалось ошибкой.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await vm.load() }
            }
            // Push «сообщение в чате» у услуг раньше только переключал вкладку.
            .onReceive(router.$openChatForOrderId.receive(on: DispatchQueue.main)) { id in
                guard let id else { return }
                router.openChatForOrderId = nil
                router.openOrderId = nil
                chatOrderId = id
            }
            // Тап по push («клиент отменил запись», новая запись) при уже открытом
            // списке только переключал вкладку: список оставался старым, у отменённой
            // записи висело «Подтвердить». Перечитываем и показываем «Все».
            .onReceive(router.$requestedTab.receive(on: DispatchQueue.main)) { t in
                guard t == "orders" else { return }
                if vm.statusFilter == nil { Task { await vm.load() } } else { vm.statusFilter = nil }
            }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(BookingsViewModel.statusChips, id: \.1) { value, title in
                    FilterChip(title: title, selected: vm.statusFilter == value) {
                        vm.statusFilter = value
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

struct BookingRow: View {
    let booking: Booking
    let onStatus: (String) -> Void
    let onChat: () -> Void
    var busy = false
    /// «Отменить» стоит вплотную к «Подтвердить» — одно касание отменяло запись
    /// клиента без вопроса.
    @State private var askCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(DateFmt.time(booking.timeStart))–\(DateFmt.time(booking.timeEnd))")
                    .font(.headline)
                    .foregroundColor(Brand.text)
                StatusBadge(text: Self.statusLabel(booking.status),
                            color: OrderStatuses.color(booking.status))
                Spacer()
                Text(Money.rub(booking.total ?? booking.price))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.text)
            }
            Text(booking.service ?? "Услуга")
                .font(.subheadline)
                .foregroundColor(Brand.text)
            // Гости и длительность: без них бронь на 6 человек на 2 часа
            // выглядела как обычная запись одного клиента.
            if (booking.guests ?? 0) > 1 || (booking.slots ?? 0) > 1 {
                HStack(spacing: 10) {
                    if let g = booking.guests, g > 1 {
                        Label("гостей: \(g)" + (booking.capacity.map { " из \($0)" } ?? ""), systemImage: "person.3")
                    }
                    if let sl = booking.slots, sl > 1 {
                        Label("окон: \(sl)", systemImage: "clock")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(Brand.muted)
            }
            HStack(spacing: 10) {
                if let m = booking.master, !m.isEmpty {
                    Label(m, systemImage: "person")
                }
                if let c = booking.client, !c.isEmpty {
                    Label(c, systemImage: "person.crop.circle")
                }
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
            // А63: комментарий клиента мастеру («аллергия на…», «приду с ребёнком»).
            if let cc = booking.clientComment?.trimmingCharacters(in: .whitespacesAndNewlines), !cc.isEmpty {
                Label(cc, systemImage: "text.bubble")
                    .font(.caption)
                    .foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let phone = booking.phone, !phone.isEmpty,
               let url = URL(string: "tel://" + phone.filter { "+0123456789".contains($0) }) {
                Link(destination: url) {
                    Label(phone, systemImage: "phone.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Brand.green)
                }
                // В строке List ссылка без стиля забирает тап по всей строке:
                // касание мимо кнопок набирало номер клиента.
                .buttonStyle(.borderless)
            }
            actions
        }
        .padding(.vertical, 4)
        .confirmationDialog("Отменить запись клиента?", isPresented: $askCancel, titleVisibility: .visible) {
            Button("Отменить запись", role: .destructive) { onStatus("cancelled") }
            Button("Не отменять", role: .cancel) {}
        } message: {
            if let hint = cancelHint { Text(hint) }
        }
    }

    /// Статус ЗАПИСИ (она — женского рода): плашка «Принят»/«Выполнен» стояла рядом
    /// с чипом «Подтверждены» и кнопкой «Выполнена». Слова — те же, что в чипах.
    private static func statusLabel(_ s: String?) -> String {
        switch s {
        case "new": return "Новая"
        case "accepted": return "Подтверждена"
        case "done": return "Выполнена"
        case "cancelled": return "Отменена"
        default: return OrderStatuses.label(s)
        }
    }

    /// Что сервер сделает с отменой уже начавшегося визита (seller_services.php,
    /// bookings/{slot}/status): в день визита — «Клиент не пришёл», позже —
    /// запись закрывается как выполненная (комиссия остаётся). Раньше продавец
    /// узнавал об этом только по тому, что запись оказалась в «Выполнены».
    private var cancelHint: String? {
        guard let day = booking.date, !day.isEmpty, let t = booking.timeStart, !t.isEmpty else { return nil }
        let full = t.count == 5 ? t + ":00" : String(t.prefix(8))
        guard let start = DateFmt.parse(day + " " + full), start <= Date() else { return nil }
        if DateFmt.ymdMoscow(Date()) > day {
            return "Визит был не сегодня: «не пришёл» отмечается только в день визита, поэтому запись закроется как выполненная."
        }
        return "Визит уже начался — запись будет отмечена «Клиент не пришёл»."
    }

    @ViewBuilder
    private var actions: some View {
        let s = booking.status
        // Права сотрудника, как в заказах и на Android: смена статуса —
        // orders.status, отмена — orders.cancel. Иначе нажатие кончалось 403.
        let canStatus = Session.shared.can("orders.status")
        let canCancel = Session.shared.can("orders.cancel")
        if s == "new" || s == "accepted" {
            HStack(spacing: 8) {
                if s == "new" && canStatus {
                    smallButton("Подтвердить", color: Brand.green) { onStatus("accepted") }
                }
                // Паритет с Android: сервер разрешает new → done (seller_services.php,
                // bookings status: $allowed['new']) — клиент пришёл без подтверждения.
                if canStatus {
                    smallButton("Выполнена", color: Brand.green) { onStatus("done") }
                }
                if canCancel {
                    smallButton("Отменить", color: Brand.red) { askCancel = true }
                }
                smallButton("Чат", color: Brand.chip, textColor: Brand.text) { onChat() }
            }
            .padding(.top, 2)
            .disabled(busy)
        }
    }

    private func smallButton(_ title: String, color: Color, textColor: Color = .white,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(color)
                .foregroundColor(textColor)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
