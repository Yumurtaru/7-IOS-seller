import SwiftUI
import Combine

// ============================================================================
//  Листы ожидания — кто ждёт товар и кто ждёт снижения цены.
//  GET /api/seller/waitlist → {waitlist, price_alerts}. Только чтение:
//  уведомления рассылает сервер, когда товар появляется или цена падает.
// ============================================================================

@MainActor
final class WaitlistViewModel: ObservableObject {
    @Published var waiting: [WaitlistEntry] = []
    @Published var alerts: [PriceAlertEntry] = []
    @Published var state: LoadState = .idle

    var isEmpty: Bool { waiting.isEmpty && alerts.isEmpty }

    func load() async {
        if isEmpty { state = .loading }
        do {
            let res = try await API.shared.waitlist()
            waiting = res.waitlist ?? []
            alerts = res.priceAlerts ?? []
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct WaitlistView: View {
    @StateObject private var vm = WaitlistViewModel()

    var body: some View {
        List {
            if !vm.waiting.isEmpty {
                Section("Ждут поступления") {
                    ForEach(vm.waiting) { row in
                        HStack {
                            Text(row.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                            Spacer()
                            StatusBadge(text: "\(row.waiting ?? 0)", color: Brand.accent)
                        }
                    }
                }
                .listRowBackground(Brand.card)
            }
            if !vm.alerts.isEmpty {
                Section("Ждут снижения цены") {
                    ForEach(vm.alerts) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                                Text("до \(Money.rub(row.targetPrice))")
                                    .font(.caption).foregroundColor(Brand.muted)
                            }
                            Spacer()
                            StatusBadge(text: "\(row.watchers ?? 0)", color: Brand.amber)
                        }
                    }
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Листы ожидания")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.load() } }
        .listState(vm.state, isEmpty: vm.isEmpty,
                   emptyIcon: "hourglass", emptyTitle: "Список пуст",
                   emptySubtitle: "Здесь появятся клиенты, которые ждут товар или снижения цены",
                   retry: { Task { await vm.load() } })
    }
}

// ============================================================================
//  Брони столов — GET /api/seller/reservations, смена статуса.
//  Статусы принимает сервер: confirmed | rejected | cancelled | seated.
// ============================================================================

@MainActor
final class ReservationsViewModel: ObservableObject {
    @Published var items: [TableReservation] = []
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var error: String?
    @Published var statusFilter: String? { didSet { if statusFilter != oldValue { items = []; state = .loading; loadGen += 1; Task { await load() } } } }
    @Published var busyId: Int?

    // П-22.8: «ожидает» на сервере — pending (status=new отдавал пустой список);
    // добавлены «Отклонены» и «Не пришли» (rejected, no_show).
    static let chips: [(String?, String)] = [
        (nil, "Все"), ("pending", "Новые"), ("confirmed", "Подтверждены"),
        ("seated", "За столом"), ("rejected", "Отклонены"), ("cancelled", "Отменены"),
        ("no_show", "Не пришли"),
    ]

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        do {
            let fresh = try await API.shared.reservations(status: statusFilter)
            guard myGen == loadGen else { return }
            items = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func setStatus(_ r: TableReservation, _ status: String) async {
        // Кнопка гаснет только к следующему кадру: два быстрых тапа слали два
        // запроса, второй возвращал ошибку поверх удачного действия.
        guard busyId == nil else { return }
        busyId = r.reservationId
        defer { busyId = nil }
        // Прежняя ошибка не висит красной полосой над следующим удачным действием.
        error = nil
        do {
            try await API.shared.setReservationStatus(id: r.reservationId, status: status)
            await load()
        } catch {
            self.error = error.localizedDescription
            // 409/422 — бронь уже изменили (гость отменил, хостес на другом
            // устройстве) — или обрыв связи: перечитываем, иначе у брони
            // оставались кнопки прежнего статуса и каждое нажатие давало ошибку.
            let msg = self.error
            await load()
            self.error = msg
        }
    }
}

struct ReservationsView: View {
    @StateObject private var vm = ReservationsViewModel()
    /// Паритет с Android: «Отклонить»/«Отменить» — с подтверждением. Кнопка стоит
    /// вплотную к «Подтвердить», и промах отклонял бронь гостя без возврата.
    @State private var confirmReject: TableReservation?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReservationsViewModel.chips, id: \.1) { value, title in
                        FilterChip(title: title, selected: vm.statusFilter == value) { vm.statusFilter = value }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            if let e = vm.error { InlineErrorBar(message: e) }
            List {
                ForEach(vm.items) { r in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.name?.isEmpty == false ? r.name! : "Без имени")
                                    .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                                Text("\(DateFmt.day(r.date)) в \(DateFmt.time(r.time)) · гостей: \(r.guests ?? 0)")
                                    .font(.caption).foregroundColor(Brand.muted)
                                if let t = r.tableNumber, !t.isEmpty {
                                    Text("стол №\(t)").font(.caption2).foregroundColor(Brand.muted)
                                }
                                if let c = r.comment, !c.isEmpty {
                                    Text(c).font(.caption2).foregroundColor(Brand.muted).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            StatusBadge(text: ReservationLabels.label(r.status),
                                        color: ReservationLabels.color(r.status))
                        }
                        // Телефон делаем кликабельным: бронь чаще всего надо
                        // подтвердить звонком, а не кнопкой.
                        if let phone = r.phone, !phone.isEmpty,
                           let url = URL(string: "tel:\(phone.filter { $0.isNumber || $0 == "+" })") {
                            Link(destination: url) {
                                Label(phone, systemImage: "phone").font(.caption)
                            }
                            // Без стиля ссылка в строке List срабатывает от тапа по всей
                            // строке — касание рядом с «Подтвердить» звонило гостю.
                            .buttonStyle(.borderless)
                        }
                        if r.status == "new" || r.status == "pending" || r.status == "confirmed" {
                            HStack(spacing: 8) {
                                if r.status != "confirmed" {
                                    actionButton("Подтвердить", .green, r, "confirmed")
                                }
                                if r.status == "confirmed" {
                                    actionButton("Гости пришли", .green, r, "seated")
                                    // Подтверждённую бронь сервер не даёт «отклонить»
                                    // (tables.php: confirmed → seated|cancelled|no_show,
                                    // иначе 409) — только отменить.
                                    rejectButton("Отменить", r)
                                } else {
                                    rejectButton("Отклонить", r)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "calendar", emptyTitle: "Броней нет",
                       emptySubtitle: "Заявки на бронь столов появятся здесь",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Брони столов")
        .navigationBarTitleDisplayMode(.inline)
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.load() } }
        // Из фона — перечитываем: новые брони и отмены гостей за это время не
        // были видны до «потянуть вниз», и «Подтвердить» у отменённой брони
        // заканчивалось ошибкой (как уже сделано в «Записях» и «Бронях» жилья).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await vm.load() }
        }
        .confirmationDialog(
            Text(confirmReject?.status == "confirmed" ? "Отменить бронь?" : "Отклонить бронь?"),
            isPresented: Binding(get: { confirmReject != nil }, set: { if !$0 { confirmReject = nil } }),
            titleVisibility: .visible,
            presenting: confirmReject
        ) { r in
            // Подтверждённую бронь сервер только отменяет (cancelled), новую — отклоняет.
            let cancel = r.status == "confirmed"
            Button(cancel ? "Отменить бронь" : "Отклонить", role: .destructive) {
                confirmReject = nil
                Task { await vm.setStatus(r, cancel ? "cancelled" : "rejected") }
            }
            Button("Не менять", role: .cancel) { confirmReject = nil }
        } message: { r in
            Text(rejectSubtitle(r))
        }
    }

    private func rejectSubtitle(_ r: TableReservation) -> String {
        let who = (r.name ?? "").isEmpty ? "Гость" : (r.name ?? "")
        return who + ", " + DateFmt.day(r.date) + " в " + DateFmt.time(r.time)
    }

    private func rejectButton(_ title: String, _ r: TableReservation) -> some View {
        Button(title) { confirmReject = r }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            .disabled(vm.busyId != nil)
    }

    private func actionButton(_ title: String, _ color: Color, _ r: TableReservation, _ status: String) -> some View {
        Button(title) { Task { await vm.setStatus(r, status) } }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderless)
            .foregroundColor(color)
            .disabled(vm.busyId != nil)   // нажатие на другую бронь во время запроса молча терялось
    }
}
