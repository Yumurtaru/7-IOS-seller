import SwiftUI

// ============================================================================
//  АZ (сайт А617): «Журнал записи на день» — GET /api/seller/slots/day?date=ГГГГ-ММ-ДД:
//  все окна всех услуг организации на дату, колонками по мастерам (или по услугам),
//  с записями в окнах. Пункт «Журнал» в хабе услуг (ServicesHubView) появляется, только
//  если пробный запрос на сегодня вернул успех с массивом columns (старый сервер — 404/405).
//  Запись клиента из журнала не делаем: ручки POST /api/seller/bookings в приложении нет.
// ============================================================================

@MainActor
final class BookingJournalViewModel: ObservableObject {
    /// Выбранный день (начало суток по часам устройства; в запрос идёт «ГГГГ-ММ-ДД»).
    @Published var date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard date != oldValue else { return }
            // Окна прежней даты под новой не показываем.
            day = nil
            state = .loading
            Task { await load() }
        }
    }
    @Published var day: SlotDay?
    /// "" — «Все»; иначе key колонки (параметр col окна).
    @Published var colFilter = ""
    @Published var state: LoadState = .loading

    /// Быстрое листание дат: ответ на прежнюю дату не применяем.
    private var gen = 0

    func load() async {
        gen += 1
        let my = gen
        if day == nil { state = .loading }
        do {
            let fresh = try await API.shared.slotsDay(date: DateFmt.ymd(date))
            guard my == gen else { return }
            day = fresh
            state = .loaded
            // Выбранной колонки в новом ответе нет (день другой) — «Все».
            if !colFilter.isEmpty, !fresh.columns.contains(where: { $0.key == colFilter }) { colFilter = "" }
        } catch is CancellationError {
        } catch {
            guard my == gen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func shift(days: Int) {
        date = Calendar.current.date(byAdding: .day, value: days, to: date) ?? date
    }

    func goToday() {
        date = Calendar.current.startOfDay(for: Date())
    }

    var isToday: Bool { Calendar.current.isDateInToday(date) }

    /// Окна с учётом чипа колонки.
    var visibleSlots: [SlotDaySlot] {
        guard let d = day else { return [] }
        return colFilter.isEmpty ? d.slots : d.slots.filter { $0.col == colFilter }
    }
}

struct BookingJournalView: View {
    @StateObject private var vm = BookingJournalViewModel()
    @EnvironmentObject var session: Session

    /// Один форматтер на экран, как в «Расписании».
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            controls
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let d = vm.day {
                        if !d.clientsVisible {
                            Text("Имена и телефоны клиентов видны с правом «Заказы».")
                                .font(.footnote)
                                .foregroundColor(Brand.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if vm.visibleSlots.isEmpty {
                            Text("На этот день окон нет.")
                                .font(.subheadline)
                                .foregroundColor(Brand.muted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            ForEach(vm.visibleSlots) { slot in
                                slotCard(slot)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .refreshable { await vm.load() }
            // Ошибка — текст сервера и «Повторить» (ErrorBanner); данных ещё нет — спиннер.
            .listState(vm.state, isEmpty: vm.day == nil,
                       emptyIcon: "calendar", emptyTitle: "На этот день окон нет.",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .task { await vm.load() }
    }

    // ── Дата и чипы колонок ──────────────────────────────────────────────────
    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { vm.shift(days: -1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(Self.dayFmt.string(from: vm.date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Button("Сегодня") { vm.goToday() }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(vm.isToday ? Brand.muted : Brand.accent)
                    .disabled(vm.isToday)
                Spacer()
                Button { vm.shift(days: 1) } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal, 24)
            if let cols = vm.day?.columns, !cols.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "Все", selected: vm.colFilter.isEmpty) { vm.colFilter = "" }
                        ForEach(cols) { col in
                            FilterChip(title: col.label ?? "—", selected: vm.colFilter == (col.key ?? "")) {
                                vm.colFilter = col.key ?? ""
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // ── Окно времени с записями ──────────────────────────────────────────────
    private func slotCard(_ slot: SlotDaySlot) -> some View {
        let closed = slot.closedBySeller == true
        let free = slot.free ?? 0
        let cap = slot.capacity ?? 1
        let stateText = Az.slotState(closed: closed, free: free, capacity: cap)
        let stateColor: Color = closed ? Brand.muted : (free > 0 ? Brand.green : Brand.amber)
        let master = (slot.master ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let service = (slot.service ?? "").isEmpty ? "Услуга" : (slot.service ?? "")
        let serviceLine = (!master.isEmpty && vm.colFilter.isEmpty) ? service + " · " + master : service
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(Az.slotRange(slot.timeStart, slot.timeEnd))
                    .font(.headline)
                    .foregroundColor(Brand.text)
                Spacer()
                StatusBadge(text: stateText, color: stateColor)
            }
            Text(serviceLine)
                .font(.subheadline)
                .foregroundColor(Brand.text)
            let list = slot.bookings
            if !list.isEmpty {
                Divider().overlay(Brand.border)
                ForEach(Array(list.enumerated()), id: \.offset) { _, b in
                    bookingRow(b)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func bookingRow(_ b: SlotDayBooking) -> some View {
        let cancelled = b.status == "cancelled"
        let line = Az.bookingLine(orderId: b.orderId ?? 0, dailyNumber: b.dailyNumber,
                                  client: b.client, guests: b.guests ?? 1)
        let phone = (b.phone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tel = phone.isEmpty ? nil : URL(string: "tel://" + phone.filter { "+0123456789".contains($0) })
        return VStack(alignment: .leading, spacing: 3) {
            // Тап — карточка заказа (нужно право «Заказы», иначе экран 403).
            if let oid = b.orderId, oid > 0, session.can("orders") {
                NavigationLink { OrderDetailView(orderId: oid) } label: { bookingHead(line, b) }
                    .buttonStyle(.plain)
            } else {
                bookingHead(line, b)
            }
            if let tel {
                Link(destination: tel) {
                    Label(phone, systemImage: "phone.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Brand.green)
                }
                .buttonStyle(.borderless)
            }
        }
        .opacity(cancelled ? 0.5 : 1)
    }

    private func bookingHead(_ line: String, _ b: SlotDayBooking) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line)
                .font(.subheadline.weight(.medium))
                .foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Text(BookingRow.statusLabel(b.status))
                .font(.caption)
                .foregroundColor(Brand.muted)
        }
        .contentShape(Rectangle())
    }
}
