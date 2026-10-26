import SwiftUI

// ============================================================================
//  Станции и кассы (cafe/ресторан) — routes/stations.php:
//   GET /api/v1/seller/stations (аккаунты станций: кухня/бар/киоск/…)
//   GET /api/v1/seller/stations/health (heartbeat касс: online < 5 мин,
//   версия, статус ФН, смена, отложенные чеки, последняя ошибка).
//   POST/PUT станции, блокировка, сброс сессий, удаление.
//  Конверт обычный {ok,data}. Доступно только mode=restaurant (иначе 403 —
//  текст сервера показываем как есть).
//
//  Логин и тип станции после создания не меняются: по логину станция входит,
//  а тип задаёт набор прав. Пароль в правке пустой — значит «не менять»;
//  смена пароля и блокировка гасят активные сессии станции.
//
//  Право — «Настройки» (settings), как размечено на сервере.
// ============================================================================

@MainActor
final class StationsViewModel: ObservableObject {
    @Published var stations: [StationAccount] = []
    @Published var health: [StationHealth] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    /// Логин и адрес экрана только что созданной станции — их надо показать.
    @Published var createdHint: String?

    func load() async {
        if stations.isEmpty { state = .loading }
        do {
            async let s = API.shared.stations()
            stations = try await s
            // health может быть пуст до миграции pos_advanced — не роняем экран.
            health = (try? await API.shared.stationsHealth()) ?? []
            state = .loaded
            error = nil   // старая ошибка обновления не висит после удачного повтора
        } catch is CancellationError {
        } catch {
            if stations.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    func health(for stationId: Int) -> StationHealth? {
        health.first(where: { $0.stationAccountId == stationId })
    }

    func create(type: String, login: String, password: String, displayName: String,
                stationNumber: String, permissions: [String], pin: String) async -> String? {
        do {
            let ack = try await API.shared.createStation(
                type: type, login: login, password: password,
                displayName: displayName, stationNumber: stationNumber,
                permissions: permissions, pin: pin)
            createdHint = "Станция «\(ack.login ?? login)» создана. Экран: \(ack.url ?? "/\(type)/")"
            await load()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func update(id: Int, displayName: String, password: String,
                permissions: [String], pin: String?, clearPin: Bool = false) async -> String? {
        do {
            try await API.shared.updateStation(id: id, displayName: displayName,
                                               password: password, permissions: permissions,
                                               pin: pin, clearPin: clearPin)
            await load()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setBlocked(_ s: StationAccount, unblock: Bool) async {
        error = nil
        do {
            _ = try await API.shared.setStationBlocked(id: s.id, unblock: unblock)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resetSessions(_ s: StationAccount) async {
        error = nil
        do {
            try await API.shared.resetStationSessions(id: s.id)
            // паритет с Android: это сообщение об успехе — зелёным, а не красной ошибкой.
            createdHint = "Сессии станции сброшены — потребуется войти заново"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ s: StationAccount) async {
        error = nil
        do {
            try await API.shared.deleteStation(id: s.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Обёртка для .sheet(item:) — nil внутри означает «создаём станцию».
struct StationEditTarget: Identifiable {
    let station: StationAccount?
    var id: Int { station?.id ?? 0 }
}

struct StationsView: View {
    @StateObject private var vm = StationsViewModel()
    /// Заводить, менять, блокировать, удалять станции и сбрасывать их сессии
    /// сервер разрешает ТОЛЬКО владельцу (routes/stations.php: «Кассы и станции
    /// заводит только владелец организации»). Сотрудник с правом «Настройки»
    /// видел кнопки и получал 403 — теперь кнопок у него нет.
    private var canManage: Bool { Session.shared.isOwner }
    @State private var editing: StationEditTarget?
    @State private var confirmDelete: StationAccount?
    /// паритет с Android: блокировка и сброс сессий сразу выкидывают станцию
    /// из системы (кухня или касса посреди смены) — только после вопроса.
    @State private var confirmBlock: StationAccount?
    @State private var confirmReset: StationAccount?

    var body: some View {
        List {
            if let hint = vm.createdHint {
                Text(hint).font(.footnote).foregroundColor(Brand.green)
                    .listRowBackground(Brand.card)
            }
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            if !canManage {
                Text("Заводить и менять станции может только владелец организации.")
                    .font(.footnote).foregroundColor(Brand.muted)
                    .listRowBackground(Brand.card)
            }
            if !vm.health.isEmpty {
                Section("Мониторинг касс") {
                    ForEach(vm.health) { h in
                        healthRow(h)
                    }
                }
                .listRowBackground(Brand.card)
            }
            Section("Аккаунты станций") {
                ForEach(vm.stations) { s in
                    stationRow(s)
                        .swipeActions(edge: .trailing) {
                            if canManage {
                                Button(role: .destructive) {
                                    confirmDelete = s
                                } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                                Button {
                                    editing = StationEditTarget(station: s)
                                } label: {
                                    Label("Изменить", systemImage: "pencil")
                                }
                                .tint(Brand.accent)
                                Button {
                                    if s.isActive == true { confirmBlock = s }
                                    else { Task { await vm.setBlocked(s, unblock: true) } }
                                } label: {
                                    Label(s.isActive == true ? "Заблокировать" : "Разблокировать",
                                          systemImage: s.isActive == true ? "lock" : "lock.open")
                                }
                                .tint(Brand.amber)
                            }
                        }
                        // Без полного свайпа: случайный жест вправо сбрасывал
                        // сессии — кухня или касса посреди смены вылетала на вход.
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if canManage {
                                Button {
                                    confirmReset = s
                                } label: {
                                    Label("Сбросить сессии", systemImage: "arrow.counterclockwise")
                                }
                                .tint(Brand.muted)
                            }
                        }
                }
            }
            .listRowBackground(Brand.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Станции и кассы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canManage {
                    Button { editing = StationEditTarget(station: nil) } label: { Image(systemName: "plus") }
                }
            }
        }
        .sheet(item: $editing) { target in
            StationEditSheet(target: target, vm: vm)
        }
        .alert("Удалить станцию?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { s in
            Button("Отмена", role: .cancel) { confirmDelete = nil }
            Button("Удалить", role: .destructive) {
                let target = s
                confirmDelete = nil
                Task { await vm.delete(target) }
            }
        } message: { _ in
            Text("Удалить можно только заблокированную или ни разу не входившую станцию — иначе сервер откажет.")
        }
        .alert("Заблокировать станцию?", isPresented: Binding(
            get: { confirmBlock != nil },
            set: { if !$0 { confirmBlock = nil } }
        ), presenting: confirmBlock) { s in
            Button("Отмена", role: .cancel) { confirmBlock = nil }
            Button("Заблокировать", role: .destructive) {
                confirmBlock = nil
                Task { await vm.setBlocked(s, unblock: false) }
            }
        } message: { s in
            Text("«\(s.displayName ?? s.login ?? "")» сразу выйдет из системы и не сможет войти, пока её не разблокируют.")
        }
        .alert("Сбросить сессии?", isPresented: Binding(
            get: { confirmReset != nil },
            set: { if !$0 { confirmReset = nil } }
        ), presenting: confirmReset) { s in
            Button("Отмена", role: .cancel) { confirmReset = nil }
            Button("Сбросить", role: .destructive) {
                confirmReset = nil
                Task { await vm.resetSessions(s) }
            }
        } message: { s in
            Text("«\(s.displayName ?? s.login ?? "")» выйдет из системы — на устройстве нужно будет войти заново.")
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.stations.isEmpty && vm.health.isEmpty,
                   emptyIcon: "desktopcomputer", emptyTitle: "Станций нет",
                   emptySubtitle: "Создайте станцию: кухня, бар, киоск, экран очереди или сборщик",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }

    private func stationRow(_ s: StationAccount) -> some View {
        HStack {
            Image(systemName: stationIcon(s.type))
                .foregroundColor(s.isActive == true ? Brand.accent : Brand.muted)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayName ?? s.login ?? "—")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Brand.text)
                Text([StationAccount.typeLabel(s.type),
                      s.stationNumber.map { "№\($0)" },
                      s.lastLoginAt.map { "вход " + DateFmt.short($0) }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundColor(Brand.muted)
            }
            Spacer()
            if s.hasPin == true {
                Image(systemName: "key.fill").font(.caption).foregroundColor(Brand.muted)
            }
            StatusBadge(text: s.isActive == true ? "активна" : "заблокирована",
                        color: s.isActive == true ? Brand.green : Brand.red)
        }
        .padding(.vertical, 2)
    }

    private func healthRow(_ h: StationHealth) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(h.online == true ? Brand.green : Brand.red)
                    .frame(width: 9, height: 9)
                Text(h.stationName ?? "Касса #\(h.stationAccountId ?? 0)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Spacer()
                Text(h.online == true ? "онлайн" : "офлайн")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(h.online == true ? Brand.green : Brand.red)
            }
            HStack(spacing: 8) {
                if let v = h.appVersion, !v.isEmpty {
                    Text("v\(v)").font(.caption2).foregroundColor(Brand.muted)
                }
                Text(h.shiftOpen == true ? "смена открыта" : "смена закрыта")
                    .font(.caption2).foregroundColor(h.shiftOpen == true ? Brand.green : Brand.muted)
                if let fn = h.fnStatus, !fn.isEmpty {
                    Text("ФН: \(fn)").font(.caption2).foregroundColor(Brand.muted)
                }
                if let d = h.deferredCount, d > 0 {
                    StatusBadge(text: "отложено чеков: \(d)", color: Brand.amber)
                }
            }
            if let e = h.lastError, !e.isEmpty {
                Text(e).font(.caption2).foregroundColor(Brand.red).lineLimit(2)
            }
            if let u = h.updatedAt {
                Text("Обновлялось: " + DateFmt.short(u))
                    .font(.caption2).foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 2)
    }

    private func stationIcon(_ t: String?) -> String {
        switch t {
        case "kitchen": return "frying.pan"
        case "bar": return "cup.and.saucer"
        case "kiosk": return "ipad"
        case "queue": return "list.number"
        case "picker": return "basket"
        case "chef": return "person.crop.rectangle"
        default: return "desktopcomputer"
        }
    }
}

private struct StationEditSheet: View {
    let target: StationEditTarget
    @ObservedObject var vm: StationsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var type = "kiosk"
    @State private var login = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var stationNumber = ""
    @State private var pin = ""
    @State private var hadPin = false
    @State private var clearPin = false
    @State private var perms: Set<String> = []
    @State private var sending = false
    @State private var error: String?

    private var isNew: Bool { target.station == nil }
    private var available: [String] { StationPerms.byType[type] ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isNew {
                        Picker("Тип станции", selection: $type) {
                            ForEach(StationPerms.types, id: \.self) { t in
                                Text(StationAccount.typeLabel(t)).tag(t)
                            }
                        }
                        .onChange(of: type) { _ in
                            // Права у каждого типа свои — при смене типа берём
                            // безопасный минимум, как это делает сервер.
                            perms = Set(StationPerms.defaults[type] ?? [])
                        }
                        TextField("Логин (минимум 3 символа)", text: $login)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        // паритет с Android: «pos-<число>» сервер держит за кассой (routes/stations.php).
                        if loginReserved {
                            Text("Логины вида pos-<число> зарезервированы для кассы")
                                .font(.caption).foregroundColor(Brand.red)
                        }
                    } else {
                        LabeledContent("Тип", value: StationAccount.typeLabel(type))
                        LabeledContent("Логин", value: login)
                    }
                    SecureField(isNew ? "Пароль (минимум 4 символа)" : "Новый пароль (пусто — не менять)",
                                text: $password)
                    TextField("Название на экране", text: $displayName)
                    if isNew {
                        TextField("Номер станции", text: $stationNumber)
                    }
                    if !clearPin {
                        TextField(hadPin ? "Новый ПИН 4–12 цифр (пусто — не менять)"
                                         : "ПИН 4–12 цифр (пусто — без ПИНа)", text: $pin)
                            .keyboardType(.numberPad)
                    }
                    if hadPin {
                        Toggle("Убрать ПИН", isOn: $clearPin)
                    }
                } header: {
                    Text("Станция")
                } footer: {
                    Text(isNew
                         ? "Логин и тип потом не меняются: по логину станция входит, а тип задаёт набор прав."
                         : "Смена пароля закроет активные сессии станции — она выйдет из системы.")
                }
                .listRowBackground(Brand.card)

                if available.isEmpty {
                    Section {
                        Text("У этого типа станции прав нет — экран только показывает информацию.")
                            .font(.footnote).foregroundColor(Brand.muted)
                    }
                    .listRowBackground(Brand.card)
                } else {
                    Section {
                        ForEach(available, id: \.self) { code in
                            Toggle(StationPerms.label(code), isOn: Binding(
                                get: { perms.contains(code) },
                                set: { on in
                                    if on { perms.insert(code) } else { perms.remove(code) }
                                }
                            ))
                        }
                    } header: {
                        Text("Что можно делать")
                    } footer: {
                        Text("Сервер примет только права, разрешённые этому типу станции, — лишнее он отбросит сам.")
                    }
                    .listRowBackground(Brand.card)
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundColor(Brand.red) }
                        .listRowBackground(Color.clear)
                }
                // «Сохранить» вверху серая, пока логин короче 3 или пароль короче 4
                // символов; подсказки в полях исчезают при вводе — пишем причину.
                if isNew && !canSave {
                    Section {
                        Text("Для сохранения: логин — от 3 символов, пароль — от 4.")
                            .font(.footnote).foregroundColor(Brand.muted)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(isNew ? "Новая станция" : "Станция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }
                        .disabled(sending || !canSave)
                }
            }
            .onAppear(perform: fill)
        }
    }

    private var canSave: Bool {
        guard isNew else { return true }
        return login.trimmingCharacters(in: .whitespaces).count >= 3 && password.count >= 4 && !loginReserved
    }

    /// Логин вида «pos-12» касса заводит сама — вручную сервер его не даст.
    private var loginReserved: Bool {
        let l = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard l.hasPrefix("pos-") else { return false }
        let rest = l.dropFirst(4)
        return !rest.isEmpty && rest.allSatisfy { $0 >= "0" && $0 <= "9" }
    }

    private func fill() {
        guard let s = target.station else {
            perms = Set(StationPerms.defaults[type] ?? [])
            return
        }
        type = s.type ?? "kiosk"
        login = s.login ?? ""
        displayName = s.displayName ?? ""
        stationNumber = s.stationNumber ?? ""
        perms = Set(s.permissions ?? [])
        // ПИН сервер не отдаёт — только признак has_pin. Пустое поле при
        // правке — «не менять», снять ПИН — отдельным переключателем.
        pin = ""
        hadPin = s.hasPin == true
    }

    @MainActor private func save() async {
        guard !sending else { return }   // двойной тап создавал две станции
        sending = true
        defer { sending = false }
        error = nil
        // Проверка до отправки. Раньше буквы из ПИНа молча выбрасывались
        // («12a45» становился ПИНом «1245», о чём никто не знал), короткий ПИН и
        // новый пароль из 1–3 символов уходили на сервер и возвращались отказом.
        let rawPin = pin.trimmingCharacters(in: .whitespaces)
        if !clearPin && !rawPin.isEmpty
            && (!(4...12).contains(rawPin.count) || !rawPin.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 })) {
            error = "ПИН — от 4 до 12 цифр"
            return
        }
        if !password.isEmpty && password.count < 4 {
            error = "Пароль — минимум 4 символа"
            return
        }
        let list = available.filter { perms.contains($0) }
        let digits = pin.filter { $0.isNumber }
        if let s = target.station {
            // паритет с Android: права, которых приложение не знает (новые на сервере),
            // отдаём как были — иначе любая правка станции молча их снимала.
            let unknown = (s.permissions ?? []).filter { !available.contains($0) }
            error = await vm.update(id: s.id, displayName: displayName,
                                    password: password, permissions: list + unknown,
                                    pin: clearPin ? nil : (digits.isEmpty ? (hadPin ? nil : "") : digits),
                                    clearPin: clearPin)
        } else {
            error = await vm.create(type: type,
                                    login: login.trimmingCharacters(in: .whitespaces),
                                    password: password, displayName: displayName,
                                    stationNumber: stationNumber, permissions: list, pin: digits)
        }
        if error == nil { dismiss() }
    }
}
