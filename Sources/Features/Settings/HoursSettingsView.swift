import SwiftUI

// ============================================================================
//  Часы работы — GET /api/seller/settings/hours (shop_hours, day_of_week
//  1=Пн … 7=Вс, time "HH:mm:ss"), сохранение POST {hours:[…]} — полная замена.
// ============================================================================

struct EditableDayHours: Identifiable {
    let day: Int              // 1–7
    var isClosed: Bool
    var open: Date
    var close: Date
    var id: Int { day }

    static let dayNames = [1: "Понедельник", 2: "Вторник", 3: "Среда", 4: "Четверг",
                           5: "Пятница", 6: "Суббота", 7: "Воскресенье"]
}

@MainActor
final class HoursSettingsViewModel: ObservableObject {
    /// Любая правка после сохранения снимает «Сохранено»: раньше надпись
    /// висела и над несохранёнными изменениями.
    @Published var days: [EditableDayHours] = [] {
        didSet {
            success = false
            // Поправили день — его ошибка сервера уже не о нём; ошибки остальных дней остаются.
            guard !dayErrors.isEmpty else { return }
            for d in days {
                guard let old = oldValue.first(where: { $0.day == d.day }) else { continue }
                if old.isClosed != d.isClosed || old.open != d.open || old.close != d.close {
                    dayErrors[d.day] = nil
                }
            }
        }
    }
    /// АY (сайт А616): 422 с errors["hours.<день>.<open_time|close_time>"] — текст под днём.
    @Published var dayErrors: [Int: String] = [:]
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var success = false
    @Published var saving = false
    /// У новой организации графика на сервере нет вовсе, а форма показывала
    /// подставленные 09:00–21:00 как будто они уже сохранены — продавец не
    /// жал «Сохранить», и пункт «Часы работы» в чек-листе публикации не закрывался.
    @Published var notSaved = false

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Часы и минуты для сравнения времени открытия и закрытия.
    private static let hmFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func time(_ s: String?, fallback: String) -> Date {
        let str = (s?.isEmpty == false) ? s! : fallback
        return timeFmt.date(from: str)
            ?? timeFmt.date(from: str + ":00")
            ?? timeFmt.date(from: fallback)!
    }

    func load() async {
        state = .loading
        do {
            let rows = try await API.shared.shopHours()
            notSaved = rows.isEmpty
            days = (1...7).map { day in
                if let row = rows.first(where: { $0.dayOfWeek == day }) {
                    return EditableDayHours(day: day,
                                            isClosed: row.isClosed ?? false,
                                            open: Self.time(row.openTime, fallback: "09:00:00"),
                                            close: Self.time(row.closeTime, fallback: "21:00:00"))
                }
                return EditableDayHours(day: day, isClosed: false,
                                        open: Self.time(nil, fallback: "09:00:00"),
                                        close: Self.time(nil, fallback: "21:00:00"))
            }
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func save() async {
        // Двойной тап слал два одинаковых запроса.
        // Часы не загрузились (загрузка идёт или упала) — дней нет, и сервер,
        // заменяющий расписание целиком, получал hours: [] и стирал его.
        guard !saving, state == .loaded, days.count == 7 else { return }
        saving = true
        defer { saving = false }
        error = nil
        dayErrors = [:]
        success = false
        // Открытие = закрытие сервер понимает как «открыто одну минуту»
        // (core/helpers.php: shopOpenAt/attachShopOpen) — заведение весь день
        // считалось закрытым, и заказы не принимались. Круглосуточно — 00:00–23:59.
        let hm = Self.hmFmt
        if let same = days.first(where: { !$0.isClosed && hm.string(from: $0.open) == hm.string(from: $0.close) }) {
            let dayName = EditableDayHours.dayNames[same.day] ?? "День \(same.day)"
            error = "\(dayName): открытие и закрытие в одно время — заведение будет закрыто весь день. Для круглосуточной работы укажите 00:00–23:59."
            return
        }
        // «ЧЧ:ММ» без секунд — сервер (сайт А616) принимает его как есть;
        // MySQL TIME принимает это и на старом сервере. У выходного — те же
        // корректные часы из выбора времени (не пустая строка и не «:00»).
        let payload: [[String: Any]] = days.map { d in
            [
                "day_of_week": d.day,
                "open_time": hm.string(from: d.open),
                "close_time": hm.string(from: d.close),
                "is_closed": d.isClosed ? 1 : 0,
            ]
        }
        do {
            try await API.shared.saveShopHours(payload)
            success = true
            notSaved = false
        } catch let e as APIDetailedError where e.status == 422 {
            // Ошибки по дням — под строкой дня; набранное не сбрасываем.
            let perDay = Self.dayErrors(e.fields)
            dayErrors = perDay
            self.error = perDay.isEmpty ? e.localizedDescription : (e.serverError ?? e.localizedDescription)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// errors["hours.3.open_time"] = ["Укажите время открытия для Ср…"] → [3: "…"].
    /// Оба поля одного дня — через перенос строки, открытие первым.
    static func dayErrors(_ fields: [String: [String]]) -> [Int: String] {
        var out: [Int: String] = [:]
        for key in fields.keys.sorted() {
            let parts = key.split(separator: ".")
            guard parts.count == 3, parts[0] == "hours", let day = Int(parts[1]), (1...7).contains(day) else { continue }
            let text = (fields[key] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !text.isEmpty else { continue }
            out[day] = out[day].map { text + "\n" + $0 } ?? text
        }
        return out
    }

    /// Скопировать часы понедельника на все дни.
    func applyMondayToAll() {
        guard let monday = days.first(where: { $0.day == 1 }) else { return }
        days = days.map { d in
            var copy = d
            copy.isClosed = monday.isClosed
            copy.open = monday.open
            copy.close = monday.close
            return copy
        }
    }
}

struct HoursSettingsView: View {
    @StateObject private var vm = HoursSettingsViewModel()

    var body: some View {
        Form {
            if vm.notSaved && vm.state == .loaded {
                Section {
                    Text("График ещё не задан. Ниже — предложение 09:00–21:00: поправьте дни и нажмите «Сохранить» внизу.")
                        .font(.footnote).foregroundColor(Brand.amber)
                }
                .listRowBackground(Brand.card)
            }
            Section {
                Button("Как в понедельник — на всю неделю") { vm.applyMondayToAll() }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.accent)
            }
            .listRowBackground(Brand.card)

            ForEach($vm.days) { $day in
                Section(EditableDayHours.dayNames[day.day] ?? "День \(day.day)") {
                    Toggle("Выходной", isOn: $day.isClosed).tint(Brand.red)
                    if !day.isClosed {
                        DatePicker("Открытие", selection: $day.open, displayedComponents: .hourAndMinute)
                        DatePicker("Закрытие", selection: $day.close, displayedComponents: .hourAndMinute)
                    }
                    if let dayErr = vm.dayErrors[day.day] {
                        Text(dayErr).font(.footnote).foregroundColor(Brand.red)
                    }
                }
                .listRowBackground(Brand.card)
            }

            Section {
                Button("Сохранить") { Task { await vm.save() } }
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.accent)
                    .disabled(vm.saving || vm.state != .loaded || vm.days.count != 7)
                if vm.success {
                    Text("Сохранено").font(.footnote).foregroundColor(Brand.green)
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .listRowBackground(Brand.card)
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Часы работы")
        .navigationBarTitleDisplayMode(.inline)
        .listState(vm.state, isEmpty: vm.days.isEmpty,
                   emptyIcon: "clock", emptyTitle: "Загрузка…",
                   retry: { Task { await vm.load() } })
        // Только первая загрузка (или повтор после ошибки): .task срабатывает
        // при каждом возврате на экран (из «Часов работы», с другой вкладки) и
        // затирал несохранённые правки данными сервера.
        .task {
            // Пропускаем, только если загрузка ЗАВЕРШИЛАСЬ: ушли с экрана посреди
            // первой загрузки — она отменилась, состояние осталось .loading, и
            // экран висел со спиннером навсегда.
            if vm.state != .loaded { await vm.load() }
        }
    }
}
