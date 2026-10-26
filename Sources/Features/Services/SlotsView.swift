import SwiftUI

// ============================================================================
//  Расписание — GET /api/seller/slots?service_id=&from=&to= (сетка слотов),
//  генерация POST /api/seller/slots/generate (диапазон, окно, дни недели),
//  PUT /api/seller/slots/{id} (is_available), DELETE /api/seller/slots/{id}.
//  Слот с order_id занят записью — сервер запрещает менять/удалять (422).
// ============================================================================

@MainActor
final class SlotsViewModel: ObservableObject {
    @Published var services: [ServiceItem] = []
    @Published var selectedServiceId: Int? {
        didSet { if selectedServiceId != oldValue { slots = []; Task { await loadSlots() } } }
    }
    @Published var weekStart = Calendar.current.startOfDay(for: Date()) {
        // Другая неделя — слоты прежней не показываем (были под новым заголовком).
        didSet { if weekStart != oldValue { slots = [] }; Task { await loadSlots() } }
    }
    @Published var slots: [ServiceSlot] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var generateResult: String?

    func loadServices() async {
        // Пока услуги грузятся — спиннер, а не «Услуг пока нет» на полсекунды.
        if services.isEmpty && selectedServiceId == nil { state = .loading }
        do {
            services = try await API.shared.services()
            if selectedServiceId == nil { selectedServiceId = services.first?.serviceId }
            if services.isEmpty { state = .loaded }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Быстрое переключение услуги/недели: ответ на прежний выбор не применяем.
    private var slotsGen = 0
    func loadSlots() async {
        guard let sid = selectedServiceId else { return }
        slotsGen += 1; let my = slotsGen
        state = .loading
        let from = DateFmt.ymd(weekStart)
        let to = DateFmt.ymd(Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart)
        do {
            let fresh = try await API.shared.slots(serviceId: sid, from: from, to: to)
            guard my == slotsGen else { return }
            slots = fresh; state = .loaded
        } catch is CancellationError {
        } catch {
            guard my == slotsGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Слоты, по которым запрос уже в пути. Клетка меняется только после
    /// ответа, и меню слота открывали ещё раз: второе «Удалить» получало 404
    /// («Не найдено») поверх удачного удаления. Повтор во время запроса — мимо.
    private var busySlotIds: Set<Int> = []

    func toggle(_ slot: ServiceSlot) async {
        guard !busySlotIds.contains(slot.slotId) else { return }
        busySlotIds.insert(slot.slotId)
        defer { busySlotIds.remove(slot.slotId) }
        error = nil
        do {
            try await API.shared.setSlotAvailability(id: slot.slotId, available: !(slot.isAvailable ?? true))
            await loadSlots()
        } catch {
            self.error = error.localizedDescription   // «Слот занят записью» и т.п.
            // Слот успел занять клиент (или его удалили): перечитываем неделю —
            // иначе клетка оставалась «Свободен», и действие снова падало.
            await loadSlots()
        }
    }

    func remove(_ slot: ServiceSlot) async {
        guard !busySlotIds.contains(slot.slotId) else { return }   // см. busySlotIds
        busySlotIds.insert(slot.slotId)
        defer { busySlotIds.remove(slot.slotId) }
        error = nil
        do {
            try await API.shared.deleteSlot(id: slot.slotId)
            slots.removeAll { $0.slotId == slot.slotId }
        } catch {
            self.error = error.localizedDescription
            await loadSlots()   // то же: слот мог стать занятым записью
        }
    }

    func generate(from: Date, to: Date, timeFrom: String, timeTo: String, weekdays: [Int]) async -> Bool {
        guard let sid = selectedServiceId else { return false }
        error = nil
        do {
            let res = try await API.shared.generateSlots(serviceId: sid,
                                                         from: DateFmt.ymd(from), to: DateFmt.ymd(to),
                                                         timeFrom: timeFrom, timeTo: timeTo, weekdays: weekdays)
            // Ноль — не ошибка: сервер пропускает окна, которые уже есть или
            // пересекаются с существующими (routes/seller_services.php,
            // slots/generate). «Создано слотов: 0» выглядело как сбой.
            let made = res.created ?? 0
            generateResult = made > 0
                ? "Создано слотов: \(made)"
                : "Новых слотов нет: окна уже есть, пересекаются с существующими или рабочее окно короче услуги"
            // Пояснение сервера (seller_services.php, slots/generate): сетка
            // создана не целиком (partial + note — нажать ещё раз) или окна
            // пропущены из-за пересечений (note_overlap).
            if let extra = res.note ?? res.noteOverlap, !extra.isEmpty {
                generateResult = (generateResult ?? "") + ". " + extra
            }
            await loadSlots()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    var grouped: [(date: String, slots: [ServiceSlot])] {
        let dict = Dictionary(grouping: slots) { $0.date ?? "" }
        return dict.keys.sorted().map { (date: $0, slots: dict[$0] ?? []) }
    }
}

struct SlotsView: View {
    @StateObject private var vm = SlotsViewModel()
    @State private var showGenerate = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let err = vm.error { InlineErrorBar(message: err) }
            if let ok = vm.generateResult {
                Text(ok)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.green)
                    .padding(.vertical, 4)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(vm.grouped, id: \.date) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(DateFmt.day(group.date))
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(Brand.text)
                            let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(group.slots) { slot in
                                    slotCell(slot)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            // Услуг ещё нет — жест вниз перечитывает их (раньше молчал: слоты
            // без выбранной услуги не грузятся).
            .refreshable { if vm.services.isEmpty { await vm.loadServices() } else { await vm.loadSlots() } }
            // Без услуг экран звал «сгенерировать кнопкой ниже», а кнопка серая —
            // расписание строится для услуги, её надо сначала добавить.
            .listState(vm.state, isEmpty: vm.slots.isEmpty,
                       emptyIcon: "calendar",
                       emptyTitle: vm.services.isEmpty ? "Услуг пока нет" : "Слотов нет",
                       emptySubtitle: vm.services.isEmpty
                           ? "Сначала добавьте услугу во вкладке «Услуги» — расписание строится для неё"
                           : "Сгенерируйте расписание кнопкой ниже",
                       // Не загрузились услуги — «Повторить» грузит их (раньше ничего не делал).
                       retry: { Task { if vm.services.isEmpty { await vm.loadServices() } else { await vm.loadSlots() } } })
        }
        .safeAreaInset(edge: .bottom) {
            Button { showGenerate = true } label: {
                Label("Сгенерировать слоты", systemImage: "wand.and.stars")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .background(vm.selectedServiceId == nil ? Brand.muted : Brand.accent)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(16)
            .disabled(vm.selectedServiceId == nil)
        }
        .sheet(isPresented: $showGenerate) {
            GenerateSlotsSheet(vm: vm)
                .errorAlert($vm.error)
        }
        .task {
            await vm.loadServices()
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(vm.services) { s in
                        FilterChip(title: s.name ?? "—", selected: vm.selectedServiceId == s.serviceId) {
                            vm.selectedServiceId = s.serviceId
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                Button {
                    vm.weekStart = Calendar.current.date(byAdding: .day, value: -7, to: vm.weekStart) ?? vm.weekStart
                } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(weekTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Spacer()
                Button {
                    vm.weekStart = Calendar.current.date(byAdding: .day, value: 7, to: vm.weekStart) ?? vm.weekStart
                } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 8)
    }

    /// Один форматтер на экран: раньше новый DateFormatter на каждую перерисовку.
    private static let weekFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f
    }()

    private var weekTitle: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: vm.weekStart) ?? vm.weekStart
        return "\(Self.weekFmt.string(from: vm.weekStart)) – \(Self.weekFmt.string(from: end))"
    }

    private func slotCell(_ slot: ServiceSlot) -> some View {
        let busy = slot.orderId != nil
        let off = slot.isAvailable != true && !busy
        return Menu {
            if busy {
                Text("Занят записью — управление на экране «Записи»")
            } else {
                Button {
                    Task { await vm.toggle(slot) }
                } label: {
                    Label(off ? "Открыть слот" : "Закрыть слот",
                          systemImage: off ? "lock.open" : "lock")
                }
                Button(role: .destructive) {
                    Task { await vm.remove(slot) }
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }
        } label: {
            VStack(spacing: 2) {
                Text(DateFmt.time(slot.timeStart))
                    .font(.subheadline.weight(.bold))
                Text(busy ? "Запись" : (off ? "Закрыт" : "Свободен"))
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(busy ? Brand.accent.opacity(0.25) : (off ? Brand.chip : Brand.green.opacity(0.18)))
            .foregroundColor(busy ? Brand.accent : (off ? Brand.muted : Brand.green))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct GenerateSlotsSheet: View {
    @ObservedObject var vm: SlotsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var from = Date()
    @State private var to = Calendar.current.date(byAdding: .day, value: 13, to: Date()) ?? Date()
    @State private var timeFrom = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var timeTo = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5, 6]
    @State private var isGenerating = false

    private let dayNames = [1: "Пн", 2: "Вт", 3: "Ср", 4: "Чт", 5: "Пт", 6: "Сб", 7: "Вс"]

    /// Последний день, который примет сервер (диапазон — не больше 92 дней).
    private var maxTo: Date { Calendar.current.date(byAdding: .day, value: 91, to: from) ?? from }

    /// Конец окна раньше начала (или равен ему): сервер отказывал или не
    /// создавал ни одного слота, а кнопка оставалась активной.
    private var windowOK: Bool {
        let c = Calendar.current
        let a = c.component(.hour, from: timeFrom) * 60 + c.component(.minute, from: timeFrom)
        let b = c.component(.hour, from: timeTo) * 60 + c.component(.minute, from: timeTo)
        return b > a
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Даты (макс. 92 дня)") {
                    DatePicker("С", selection: $from, displayedComponents: .date)
                    DatePicker("По", selection: $to, in: from...maxTo, displayedComponents: .date)
                }
                // Сдвинули «С» — «По» держим в допустимом окне: раньше оставалось
                // раньше начала или дальше 92 дней, и генерация падала с 422.
                .onChange(of: from) { f in
                    let limit = Calendar.current.date(byAdding: .day, value: 91, to: f) ?? f
                    if to < f { to = f }
                    if to > limit { to = limit }
                }
                Section {
                    DatePicker("Начало", selection: $timeFrom, displayedComponents: .hourAndMinute)
                    DatePicker("Конец", selection: $timeTo, displayedComponents: .hourAndMinute)
                    Text("Шаг слотов = длительность услуги + буфер (считает сервер)")
                        .font(.caption).foregroundColor(Brand.muted)
                } header: {
                    Text("Рабочее окно")
                } footer: {
                    if !windowOK {
                        Text("Конец рабочего окна должен быть позже начала.").foregroundColor(Brand.red)
                    }
                }
                Section("Дни недели") {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { day in
                            Button {
                                if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                            } label: {
                                Text(dayNames[day] ?? "")
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(weekdays.contains(day) ? Brand.accent : Brand.chip)
                                    .foregroundColor(weekdays.contains(day) ? .white : Brand.text)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Button {
                        // Флаг — до Task: флаг внутри Task ставился позже, и два
                        // быстрых тапа запускали две генерации (дубли слотов).
                        guard !isGenerating, windowOK else { return }
                        isGenerating = true
                        Task {
                            // Время уходит на сервер: формат фиксированный, без
                            // «AM/PM» при 12-часовой настройке телефона (QA1480).
                            let tf = DateFormatter(); tf.locale = Locale(identifier: "en_US_POSIX"); tf.dateFormat = "HH:mm"
                            let ok = await vm.generate(from: from, to: to,
                                                       timeFrom: tf.string(from: timeFrom),
                                                       timeTo: tf.string(from: timeTo),
                                                       weekdays: Array(weekdays).sorted())
                            isGenerating = false
                            if ok { dismiss() }
                        }
                    } label: {
                        HStack { Spacer(); if isGenerating { ProgressView() } else { Text("Сгенерировать").bold() }; Spacer() }
                    }
                    .disabled(isGenerating || weekdays.isEmpty || !windowOK)
                } footer: {
                    // Сняли все дни — кнопка гасла молча, причины видно не было.
                    if weekdays.isEmpty {
                        Text("Выберите хотя бы один день недели.").foregroundColor(Brand.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Генерация слотов")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
        }
    }
}
