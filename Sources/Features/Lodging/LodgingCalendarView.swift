import SwiftUI

// ============================================================================
//  Календарь цен и доступности объекта.
// ----------------------------------------------------------------------------
//  Главное, зачем владельцу жилья телефон: поднять цену на праздники и
//  закрыть даты, когда номер занят вне площадки. Правка — диапазоном:
//  два касания задают «с» и «по», дальше одно окно на все выбранные дни.
//
//  В запрос попадают ТОЛЬКО включённые поля: сервер меняет пришедшие ключи,
//  поэтому «поднять цену на выходные» не сбрасывает минимальный срок.
// ============================================================================

@MainActor
final class LodgingCalendarViewModel: ObservableObject {
    @Published var month: Date = Date()
    @Published var days: [String: LodgingCalendarDay] = [:]
    @Published var basePrice: Decimal?
    @Published var weekendPrice: Decimal?
    @Published var inventory: Int = 1
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var saved: String?

    let unitId: Int
    /// Запрос в полёте: три быстрых нажатия «›» давали три ответа, и последний
    /// пришедший (за октябрь) перезатирал показанный декабрь — сетка оставалась
    /// без цен, будто календарь не загрузился.
    private var task: Task<Void, Never>?

    init(unitId: Int) { self.unitId = unitId }

    /// Первое число показанного месяца.
    var monthStart: Date {
        let cal = LodgingFormat.gregorian
        let c = cal.dateComponents([.year, .month], from: month)
        return cal.date(from: c) ?? month
    }

    var monthDays: [Date] {
        let cal = LodgingFormat.gregorian
        let start = monthStart
        let count = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    func shift(_ months: Int) {
        if let d = LodgingFormat.gregorian.date(byAdding: .month, value: months, to: monthStart) {
            month = d
            // Пока новый месяц не пришёл, старые цифры показывать нельзя: они
            // от другого месяца, а числа в сетке уже новые.
            days = [:]
            Task { await load() }
        }
    }

    func load() async {
        task?.cancel()
        let t = Task { @MainActor in await self.reload() }
        task = t
        await t.value
    }

    private func reload() async {
        if days.isEmpty { state = .loading }
        error = nil
        saved = nil
        let cal = LodgingFormat.gregorian
        let asked = LodgingFormat.iso(monthStart)
        let last = cal.date(byAdding: .day, value: (monthDays.count - 1), to: monthStart) ?? monthStart
        do {
            let resp = try await API.shared.lodgingCalendar(unitId: unitId, from: asked, to: LodgingFormat.iso(last))
            // Ответ устаревшего запроса не применяем — иначе в шапке декабрь, а
            // в клетках ноябрьские цены.
            guard !Task.isCancelled, asked == LodgingFormat.iso(monthStart) else { return }
            var map: [String: LodgingCalendarDay] = [:]
            for d in resp.days ?? [] { map[d.date] = d }
            days = map
            basePrice = resp.basePrice
            weekendPrice = resp.weekendPrice
            inventory = resp.unit?.inventory ?? 1
            state = .loaded
        } catch is CancellationError {
        } catch {
            if days.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    /// true — правка принята сервером (даже если перечитать месяц не вышло).
    func bulk(from: String, to: String, body: [String: Any?]) async -> Bool {
        error = nil
        saved = nil
        var payload = body
        payload["from"] = from
        payload["to"] = to
        do {
            let ack = try await API.shared.lodgingCalendarBulk(unitId: unitId, body: payload)
            // Сообщение — после перечитывания: reload() начинает с saved = nil,
            // и «Изменено дней: N» раньше не появлялось никогда.
            await load()
            saved = "Изменено дней: \(ack.days ?? 0)"
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct LodgingCalendarView: View {
    @StateObject private var vm: LodgingCalendarViewModel
    let title: String

    @State private var rangeStart: Date?
    @State private var rangeEnd: Date?
    @State private var sheet: LodgingCalendarSheet?

    init(unitId: Int, title: String) {
        _vm = StateObject(wrappedValue: LodgingCalendarViewModel(unitId: unitId))
        self.title = title
    }

    private let weekdayNames = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]

    var body: some View {
        VStack(spacing: 0) {
            if let err = vm.error { InlineErrorBar(message: err) }
            header
            ScrollView {
                VStack(spacing: 10) {
                    weekdayRow
                    grid
                    legend
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            // Подсказка пустого календаря говорит «потяните вниз», а жеста не
            // было: цены после сбоя или правки с сайта не обновить без выхода.
            .refreshable { await vm.load() }
            if rangeStart != nil { selectionBar }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Календарь")
        .navigationBarTitleDisplayMode(.inline)
        .listState(vm.state, isEmpty: vm.days.isEmpty,
                   emptyIcon: "calendar", emptyTitle: "Календарь не загрузился",
                   emptySubtitle: "Потяните вниз или откройте месяц заново",
                   retry: { Task { await vm.load() } })
        .sheet(item: $sheet) { route in
            switch route {
            case .bulk:
                LodgingBulkSheet(vm: vm,
                                 from: rangeStart ?? Date(),
                                 to: rangeEnd ?? rangeStart ?? Date(),
                                 onDone: { rangeStart = nil; rangeEnd = nil })
                    // Отказ сервера (нет права «Цены», 422, нет связи) — в листе:
                    // полоса ошибки календаря под листом не видна.
                    .errorAlert($vm.error)
            case .day(let key):
                LodgingDaySheet(day: vm.days[key], date: key, inventory: vm.inventory)
            }
        }
        .task { await vm.load() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Button { vm.shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(LodgingFormat.monthTitle(vm.monthStart))
                    .font(.headline)
                    .foregroundColor(Brand.text)
                Spacer()
                Button { vm.shift(1) } label: { Image(systemName: "chevron.right") }
            }
            Text(title).font(.caption).foregroundColor(Brand.muted)
            if let base = vm.basePrice {
                Text("Базовая цена \(Money.rub(base))"
                     + ((vm.weekendPrice ?? 0) > 0 ? " · выходные \(Money.rub(vm.weekendPrice))" : ""))
                    .font(.caption2).foregroundColor(Brand.muted)
            }
            if let ok = vm.saved {
                Text(ok).font(.caption2.weight(.semibold)).foregroundColor(Brand.green)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Brand.card)
    }

    private var weekdayRow: some View {
        HStack(spacing: 4) {
            ForEach(weekdayNames, id: \.self) { n in
                Text(n).font(.caption2).foregroundColor(Brand.muted)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 8)
    }

    private var grid: some View {
        // Смещение до первого дня месяца: 1=Пн … 7=Вс (как date('N') на сервере).
        let lead = (LodgingFormat.gregorian.component(.weekday, from: vm.monthStart) + 5) % 7
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
            ForEach(0..<lead, id: \.self) { i in
                Color.clear.frame(height: 62).id("lead\(i)")
            }
            ForEach(vm.monthDays, id: \.self) { date in
                dayCell(date)
            }
        }
    }

    private func inRange(_ date: Date) -> Bool {
        guard let s = rangeStart else { return false }
        let e = rangeEnd ?? s
        let d = LodgingFormat.iso(date)
        return d >= LodgingFormat.iso(min(s, e)) && d <= LodgingFormat.iso(max(s, e))
    }

    private func dayCell(_ date: Date) -> some View {
        let key = LodgingFormat.iso(date)
        let day = vm.days[key]
        let closed = (day?.isClosed ?? 0) == 1
        let free = day?.free ?? vm.inventory
        let selected = inRange(date)
        let own = day?.ownPrice != nil
        let isToday = key == LodgingFormat.iso(Date())
        // Паритет с Android (решение прошлых волн): прошедшие даты бронировать
        // нельзя, править их бессмысленно — в сетке видны, но не выбираются.
        // «Сегодня» — по Москве, как у сервера.
        let past = key < DateFmt.ymdMoscow(Date())
        return Button {
            tap(date)
        } label: {
            VStack(spacing: 2) {
                // Число дня — григорианское, как ключ клетки: с исламским или
                // еврейским календарём телефона в клетке стояло чужое число.
                Text(String(LodgingFormat.gregorian.component(.day, from: date)))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(selected ? .white : (past ? Brand.muted : Brand.text))
                Text(closed ? "закр." : LodgingFormat.shortPrice(day?.price))
                    .font(.caption2)
                    .foregroundColor(selected ? .white.opacity(0.9)
                                     : (closed ? Brand.red : (own ? Brand.accent : Brand.muted)))
                Text(closed ? "" : (free <= 0 ? "нет" : "\(free)"))
                    .font(.caption2)
                    .foregroundColor(selected ? .white.opacity(0.9)
                                     : (free <= 0 ? Brand.red : Brand.muted))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(selected ? Brand.accent : Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .opacity(past ? 0.5 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isToday ? Brand.accent : (closed ? Brand.red.opacity(0.5) : Color.clear),
                            lineWidth: isToday ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        // Ограничения даты (запрет заезда/выезда, свой минимум ночей) в клетке
        // не помещаются, а узнать их с телефона было нельзя вовсе: держим палец.
        .onLongPressGesture { sheet = .day(key) }
    }

    /// Первое касание — начало диапазона, второе — конец. Третье начинает заново.
    private func tap(_ date: Date) {
        // Паритет с Android: прошедшая дата не выбирается (см. dayCell).
        guard LodgingFormat.iso(date) >= DateFmt.ymdMoscow(Date()) else { return }
        if rangeStart == nil || rangeEnd != nil {
            rangeStart = date
            rangeEnd = nil
        } else if let s = rangeStart {
            rangeEnd = date
            if date < s { rangeStart = date; rangeEnd = s }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("В клетке: цена и сколько свободно. Оранжевая цена — своя цена этой даты, «закр.» — дата закрыта.")
            Text("Коснитесь первой даты и последней — изменится весь выбранный диапазон. Прошедшие даты не меняются. Долгое нажатие — подробности дня.")
        }
        .font(.caption2)
        .foregroundColor(Brand.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    /// Подпись выбранного диапазона — без принудительных развёрток.
    private var selectionText: String {
        guard let s = rangeStart else { return "" }
        guard let e = rangeEnd else {
            return "Выбрано: \(LodgingFormat.dayMonth(LodgingFormat.iso(s)))"
        }
        return "С \(LodgingFormat.dayMonth(LodgingFormat.iso(min(s, e)))) по \(LodgingFormat.dayMonth(LodgingFormat.iso(max(s, e))))"
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionText)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.text)
                Text(rangeEnd == nil ? "Коснитесь последней даты или измените один день" : "Изменения применятся ко всем дням диапазона")
                    .font(.caption2).foregroundColor(Brand.muted)
            }
            Spacer()
            Button("Сбросить") { rangeStart = nil; rangeEnd = nil }
                .font(.footnote)
            Button { sheet = .bulk } label: {
                Text("Изменить").font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Brand.accent).foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Brand.card)
    }
}

/// Листы календаря — одним .sheet(item:).
enum LodgingCalendarSheet: Identifiable {
    case bulk
    case day(String)

    var id: String {
        switch self {
        case .bulk: return "bulk"
        case .day(let k): return "day-\(k)"
        }
    }
}

/// Карточка даты: то, чего не видно в клетке — запреты заезда и выезда и свой
/// минимум ночей. Их задают в веб-кабинете, и без этого экрана продавец не мог
/// понять, почему гость не может забронировать свободную с виду дату.
private struct LodgingDaySheet: View {
    let day: LodgingCalendarDay?
    let date: String
    let inventory: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Цена за ночь", Money.rub(day?.price))
                    row("Своя цена этой даты", day?.ownPrice != nil ? Money.rub(day?.ownPrice) : "нет, берётся базовая")
                    row("Номеров в продаже", "\(day?.inventory ?? inventory)")
                    row("Забронировано", "\(day?.booked ?? 0)")
                    row("Свободно", "\(day?.free ?? inventory)")
                    row("Дата закрыта", (day?.isClosed ?? 0) == 1 ? "да" : "нет")
                }
                Section {
                    row("Минимум ночей", (day?.minNights ?? 0) > 0 ? LodgingFormat.nights(day?.minNights) : "как у объекта")
                    row("Заезд в эту дату", (day?.cta ?? 0) == 1 ? "запрещён" : "разрешён")
                    row("Выезд в эту дату", (day?.ctd ?? 0) == 1 ? "запрещён" : "разрешён")
                    row("Выходной день", (day?.weekend ?? 0) == 1 ? "да" : "нет")
                } footer: {
                    Text("Эти ограничения гость видит как «нет свободных дат». Изменить их можно в массовой правке: выделите дату и нажмите «Изменить».")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(LodgingFormat.fullDate(date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Закрыть") { dismiss() } } }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundColor(Brand.text)
            Spacer()
            Text(value).foregroundColor(Brand.muted)
        }
        .font(.footnote)
        .listRowBackground(Brand.card)
    }
}

/// Массовая правка диапазона. Каждое поле включается тумблером — выключенные
/// в запрос не попадают и на сервере не меняются.
private struct LodgingBulkSheet: View {
    @ObservedObject var vm: LodgingCalendarViewModel
    let from: Date
    let to: Date
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var setPrice = false
    @State private var price = ""
    @State private var setClosed = false
    @State private var closed = false
    @State private var setFree = false
    @State private var free = ""
    @State private var setMinNights = false
    @State private var minNights = ""
    @State private var setCta = false
    @State private var cta = false
    @State private var setCtd = false
    @State private var ctd = false
    @State private var weekdays: Set<Int> = []
    @State private var isSaving = false
    /// «Снять все правки» стирает праздничные цены и закрытия всего диапазона
    /// одним касанием, а стоит под «Применить» — спрашиваем.
    @State private var confirmReset = false

    private let weekdayNames = [(1, "Пн"), (2, "Вт"), (3, "Ср"), (4, "Чт"), (5, "Пт"), (6, "Сб"), (7, "Вс")]

    private var fromIso: String { LodgingFormat.iso(min(from, to)) }
    private var toIso: String { LodgingFormat.iso(max(from, to)) }

    private var nothingToDo: Bool {
        !(setPrice || setClosed || setFree || setMinNights || setCta || setCtd)
    }

    /// Включённое поле с неразборчивым значением нельзя отправлять: пустое поле
    /// означает «вернуть значение по умолчанию», и опечатка («3.5.0») молча
    /// сбросила бы цены всего диапазона, а сервер ответил бы «изменено N дней».
    private var badInput: Bool {
        // Отрицательные «-3» номеров/ночей Int() принимал и отправлял.
        func num(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || (Int(t).map { $0 >= 0 } ?? false)
        }
        let priceText = price.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        // Строго: «3.5.0» Decimal(string:) читал как 3.5 и пропускал мусор.
        // Цена «0» уходила как бесплатная ночь на весь диапазон. Вернуть
        // базовую цену — пустое поле.
        if setPrice && !priceText.isEmpty && (Money.strict(priceText) ?? 0) <= 0 { return true }
        if setFree && !num(free) { return true }
        if setMinNights && !num(minNights) { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(LodgingFormat.fullDate(fromIso)) — \(LodgingFormat.fullDate(toIso))")
                        .font(.subheadline).foregroundColor(Brand.text)
                } header: {
                    Text("Диапазон")
                } footer: {
                    Text("Меняются только включённые ниже поля. Остальное у этих дат остаётся как было.")
                }
                Section("Только дни недели (иначе — все)") {
                    HStack(spacing: 6) {
                        ForEach(weekdayNames, id: \.0) { n, label in
                            Button {
                                if weekdays.contains(n) { weekdays.remove(n) } else { weekdays.insert(n) }
                            } label: {
                                Text(label)
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(weekdays.contains(n) ? Brand.accent : Brand.chip)
                                    .foregroundColor(weekdays.contains(n) ? .white : Brand.text)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                // Цена закрыта правом «Цены»: сервер отвечает 403 на всю правку.
                if Session.shared.can("products.price") {
                Section("Цена") {
                    Toggle("Изменить цену за ночь", isOn: $setPrice)
                    if setPrice {
                        HStack {
                            Text("Цена, ₽").foregroundColor(Brand.text)
                            Spacer()
                            TextField("как базовая", text: $price)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 120)
                        }
                        Text("Пустое поле вернёт этим датам базовую цену объекта.")
                            .font(.caption2).foregroundColor(Brand.muted)
                    }
                }
                }
                Section("Доступность") {
                    Toggle("Закрыть или открыть даты", isOn: $setClosed)
                    if setClosed { Toggle("Даты закрыты", isOn: $closed) }
                    Toggle("Изменить число номеров в продаже", isOn: $setFree)
                    if setFree {
                        HStack {
                            Text("Всего номеров на эти даты").foregroundColor(Brand.text)
                            Spacer()
                            TextField("\(vm.inventory)", text: $free)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                        }
                        // Это ОБЩЕЕ число номеров на дату, а не остаток: сервер
                        // считает свободные как «это число минус брони». Подпись
                        // «сколько свободно» приводила к тому, что продавец с
                        // тремя бронями ставил 2 и закрывал дату полностью.
                        Text("Это общее число номеров, выставленных в продажу в эти даты (у объекта — \(vm.inventory)). Уже забронированные вычитаются автоматически. Пустое поле вернёт значение объекта.")
                            .font(.caption2).foregroundColor(Brand.muted)
                    }
                }
                Section("Условия заезда") {
                    Toggle("Изменить минимум ночей", isOn: $setMinNights)
                    if setMinNights {
                        HStack {
                            Text("Минимум ночей").foregroundColor(Brand.text)
                            Spacer()
                            TextField("без ограничения", text: $minNights)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 120)
                        }
                    }
                    Toggle("Изменить запрет заезда", isOn: $setCta)
                    if setCta { Toggle("Заезд в эти даты запрещён", isOn: $cta) }
                    Toggle("Изменить запрет выезда", isOn: $setCtd)
                    if setCtd { Toggle("Выезд в эти даты запрещён", isOn: $ctd) }
                }
                Section {
                    Button {
                        Task { await apply(reset: false) }
                    } label: {
                        HStack { Spacer(); if isSaving { ProgressView() } else { Text("Применить").bold() }; Spacer() }
                    }
                    .disabled(isSaving || nothingToDo || badInput)
                } footer: {
                    Text(nothingToDo ? "Включите хотя бы одно поле — иначе менять нечего."
                         : (badInput ? "Проверьте числа во включённых полях: цена — больше нуля, номера и ночи — целые от нуля." : ""))
                }
                // reset удаляет строки календаря целиком — вместе с ценами дат.
                // Сервер проверяет право «Цены» только на присланное поле price,
                // поэтому кнопку прячем сами: иначе сотрудник без права цен
                // одним нажатием сносил праздничные цены на весь диапазон.
                if Session.shared.can("products.price") {
                    Section {
                        Button(role: .destructive) {
                            confirmReset = true
                        } label: {
                            Text("Снять все правки диапазона")
                        }
                        .disabled(isSaving)
                    } footer: {
                        Text("Даты вернутся к базовой цене и обычной доступности объекта. Брони это не затрагивает.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Изменить даты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } } }
            .confirmationDialog("Снять все правки с \(LodgingFormat.fullDate(fromIso)) по \(LodgingFormat.fullDate(toIso))?",
                                isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Снять правки", role: .destructive) {
                    Task { await apply(reset: true) }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Свои цены, закрытия и ограничения этих дат удалятся" + (weekdays.isEmpty ? "" : " (только в выбранные дни недели)") + ".")
            }
        }
    }

    @MainActor private func apply(reset: Bool) async {
        guard !isSaving else { return }   // двойной тап — одна массовая правка
        isSaving = true
        defer { isSaving = false }
        var body: [String: Any?] = [:]
        if !weekdays.isEmpty { body["weekdays"] = weekdays.sorted() }
        if reset {
            body["reset"] = true
        } else {
            // Пустая строка = «вернуть значение по умолчанию». Явный null
            // шлём через NSNull(): makeRequest выбрасывает из тела ключи со
            // значением nil, и сервер тогда просто не увидел бы поле.
            if setPrice {
                let t = price.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: " ", with: "")
                    .replacingOccurrences(of: "\u{202F}", with: "")
                    .replacingOccurrences(of: "\u{00A0}", with: "")
                    .replacingOccurrences(of: ",", with: ".")
                body["price"] = t.isEmpty ? NSNull() : t as Any
            }
            if setClosed { body["is_closed"] = closed ? 1 : 0 }
            if setFree {
                let t = free.trimmingCharacters(in: .whitespaces)
                body["inventory_left"] = Int(t).map { $0 as Any } ?? NSNull()
            }
            if setMinNights {
                let t = minNights.trimmingCharacters(in: .whitespaces)
                body["min_nights"] = Int(t).map { $0 as Any } ?? NSNull()
            }
            if setCta { body["cta"] = cta ? 1 : 0 }
            if setCtd { body["ctd"] = ctd ? 1 : 0 }
        }
        // Закрываем по результату самой правки: раньше сбой перечитывания
        // месяца оставлял лист открытым, хотя изменения уже сохранены.
        if await vm.bulk(from: fromIso, to: toIso, body: body) {
            onDone()
            dismiss()
        }
    }
}
