import SwiftUI

// ============================================================================
//  Сотрудники — GET /api/seller/staff/employees?status= (все поля
//  staffEmployeeRow), создание/правка/увольнение POST/PUT/DELETE, PIN для
//  кассы (4–12 цифр, уникален в магазине — сервер валидирует).
// ============================================================================

enum EmployeeLabels {
    static func status(_ s: String?) -> String {
        switch s {
        case "active": return "Работает"
        case "blocked": return "Заблокирован"
        case "fired": return "Уволен"
        default: return s ?? "—"
        }
    }
    static func statusColor(_ s: String?) -> Color {
        switch s {
        case "active": return Brand.green
        case "blocked": return Brand.amber
        case "fired": return Brand.muted
        default: return Brand.muted
        }
    }
    static func salaryType(_ s: String?) -> String {
        switch s {
        case "fixed": return "Оклад"
        case "percent": return "Процент"
        case "mixed": return "Оклад + %"
        default: return s ?? "—"
        }
    }
}

@MainActor
final class EmployeesViewModel: ObservableObject {
    @Published var items: [Employee] = []
    @Published var roles: [StaffRole] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    // Смена фильтра: старые строки убираем, ответ прежнего фильтра не применяем —
    // иначе под «Уволены» оставались работающие сотрудники.
    @Published var statusFilter: String? {
        didSet { if statusFilter != oldValue { items = []; state = .loading; loadGen += 1; Task { await load() } } }
    }
    private var loadGen = 0

    static let statusChips: [(String?, String)] = [
        // «Блок» — обрубок; статус в карточке — «Заблокирован».
        (nil, "Все"), ("active", "Работают"), ("blocked", "Заблокированы"), ("fired", "Уволены"),
    ]

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        do {
            async let emps = API.shared.employees(status: statusFilter)
            async let allRoles = API.shared.staffRoles()
            let fresh = try await emps
            let freshRoles = try? await allRoles
            guard myGen == loadGen else { return }
            items = fresh
            roles = freshRoles ?? roles
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Удаление сотрудника в пути: строка висит до ответа, второе «Удалить»
    /// получало 404 «Сотрудник не найден» поверх удачного удаления.
    private var deletingIds: Set<Int> = []

    func delete(_ employee: Employee) async {
        guard !deletingIds.contains(employee.employeeId) else { return }
        deletingIds.insert(employee.employeeId)
        defer { deletingIds.remove(employee.employeeId) }
        error = nil
        do {
            try await API.shared.deleteEmployee(id: employee.employeeId)
            items.removeAll { $0.employeeId == employee.employeeId }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct EmployeesView: View {
    @StateObject private var vm = EmployeesViewModel()
    @State private var editTarget: EmployeeEditTarget?
    /// Паритет с Android: удаление сотрудника (с PIN кассы) — с подтверждением.
    @State private var deleteTarget: Employee?

    var body: some View {
        VStack(spacing: 0) {
            chips
            List {
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                        .listRowBackground(Brand.card)
                }
                ForEach(vm.items) { employee in
                    Button { editTarget = EmployeeEditTarget(employee: employee) } label: {
                        EmployeeRow(employee: employee)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Brand.card)
                    // Без полного свайпа: длинный жест сразу удалял без вопроса
                    // (сотрудник с PIN кассы, курьер, роль) — теперь только кнопкой.
                    .swipeActions(allowsFullSwipe: false) {
                        // Сотрудника со входом в кабинет удаляет только владелец
                        // (seller_staff.php, DELETE employees: panel_access → 403).
                        if Session.shared.isOwner || employee.panelAccess != true {
                            Button(role: .destructive) {
                                deleteTarget = employee
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .confirmationDialog(
                "Удалить сотрудника?",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { employee in
                Button("Удалить «\(employee.fullName ?? employee.phone ?? "сотрудника")»", role: .destructive) {
                    let e = employee
                    deleteTarget = nil
                    Task { await vm.delete(e) }
                }
                Button("Отмена", role: .cancel) { deleteTarget = nil }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "person.3", emptyTitle: "Сотрудников нет",
                       emptySubtitle: "Добавьте сотрудников, назначьте роли и PIN для кассы",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Сотрудники")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editTarget = EmployeeEditTarget(employee: nil) } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editTarget) { target in
            EmployeeEditSheet(employee: target.employee, roles: vm.roles,
                              onSaved: { Task { await vm.load() } })
        }
        .task { await vm.load() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(EmployeesViewModel.statusChips, id: \.1) { value, title in
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

struct EmployeeEditTarget: Identifiable {
    let employee: Employee?
    var id: Int { employee?.employeeId ?? -1 }
}

struct EmployeeRow: View {
    let employee: Employee

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(employee.fullName ?? employee.phone ?? "Сотрудник")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.text)
                Spacer()
                StatusBadge(text: EmployeeLabels.status(employee.status),
                            color: EmployeeLabels.statusColor(employee.status))
            }
            HStack(spacing: 8) {
                if let role = employee.roleName {
                    StatusBadge(text: role, color: Color(hex: employee.roleColor) ?? Brand.accent)
                }
                if let pos = employee.position, !pos.isEmpty {
                    Text(pos).font(.caption).foregroundColor(Brand.muted)
                }
                if employee.hasPin == true {
                    Label("PIN", systemImage: "key.fill")
                        .font(.caption2).foregroundColor(Brand.muted)
                }
            }
            if let phone = employee.phone, !phone.isEmpty {
                Text(phone).font(.caption2).foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 3)
    }
}

/// #RRGGBB → Color (цвета ролей приходят с сервера).
extension Color {
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

// ── Карточка сотрудника (создание/правка) ────────────────────────────────────
struct EmployeeEditSheet: View {
    let employee: Employee?
    let roles: [StaffRole]
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var fullName: String
    @State private var phone: String
    @State private var email: String
    @State private var position: String
    @State private var roleId: Int
    @State private var status: String
    @State private var pin: String
    @State private var clearPin = false
    @State private var salaryType: String
    @State private var salaryValue: String
    @State private var nightBonus: String
    @State private var note: String
    @State private var error: String?
    @State private var saving = false

    init(employee: Employee?, roles: [StaffRole], onSaved: @escaping () -> Void) {
        self.employee = employee
        self.roles = roles
        self.onSaved = onSaved
        _fullName = State(initialValue: employee?.fullName ?? "")
        _phone = State(initialValue: employee?.phone ?? "")
        _email = State(initialValue: employee?.email ?? "")
        _position = State(initialValue: employee?.position ?? "")
        _roleId = State(initialValue: employee?.roleId ?? 0)
        _status = State(initialValue: employee?.status ?? "active")
        _pin = State(initialValue: employee?.pin ?? "")
        _salaryType = State(initialValue: employee?.salaryType ?? "fixed")
        _salaryValue = State(initialValue: employee?.salaryValue.map { "\($0)" } ?? "")
        _nightBonus = State(initialValue: employee?.nightBonus.map { "\($0)" } ?? "")
        _note = State(initialValue: employee?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сотрудник") {
                    TextField("ФИО", text: $fullName)
                    TextField("Телефон", text: $phone.phoneInput).keyboardType(.phonePad)
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("Должность", text: $position)
                    Picker("Роль", selection: $roleId) {
                        Text("Без роли").tag(0)
                        ForEach(roles) { role in
                            Text(role.name ?? "Роль").tag(role.roleId)
                        }
                    }
                    // Роль назначает только владелец (seller_staff.php,
                    // staffEmployeePayload: иначе 403 при сохранении всей карточки).
                    .disabled(!Session.shared.isOwner)
                    Picker("Статус", selection: $status) {
                        Text("Работает").tag("active")
                        Text("Заблокирован").tag("blocked")
                        Text("Уволен").tag("fired")
                    }
                }
                Section {
                    // Паритет с Android: PIN задаёт владелец (свой PIN сотрудник меняет
                    // сам) — иначе сервер отвечал 403 на всё сохранение карточки, а
                    // «Удалить PIN» молча не срабатывало (seller_staff.php, PUT employees).
                    if !canPin {
                        Text(employee?.hasPin == true
                             ? "PIN задан. Менять PIN может только владелец организации"
                             : "PIN для кассы задаёт владелец организации")
                            .font(.footnote).foregroundColor(Brand.muted)
                    } else if !clearPin {
                        TextField("PIN (4–12 цифр)", text: $pin).keyboardType(.numberPad)
                    }
                    if employee?.hasPin == true && Session.shared.isOwner {
                        Toggle("Удалить PIN", isOn: $clearPin)
                    }
                } header: {
                    Text("PIN для кассы")
                } footer: {
                    if canPin {
                        Text(employee?.hasPin == true
                             ? "PIN задан. Пусто — не менять, введите новый, чтобы заменить. PIN уникален в магазине."
                             : "PIN нужен для входа сотрудника на кассу.")
                    }
                }
                Section("Зарплата") {
                    Picker("Тип", selection: $salaryType) {
                        Text("Оклад").tag("fixed")
                        Text("Процент").tag("percent")
                        Text("Оклад + %").tag("mixed")
                    }
                    TextField(salaryType == "percent" ? "Ставка, %" : "Сумма, ₽", text: $salaryValue)
                        .keyboardType(.decimalPad)
                    TextField("Ночная надбавка, ₽", text: $nightBonus)
                        .keyboardType(.decimalPad)
                }
                Section("Заметка") {
                    TextField("Комментарий", text: $note, axis: .vertical).lineLimit(2...4)
                }
                if let err = error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(employee == nil ? "Новый сотрудник" : "Сотрудник")
            .navigationBarTitleDisplayMode(.inline)
            // «Сохранить» — вверху, а отказ сервера («PIN уже занят», «телефон
            // занят») писался под зарплатой и заметкой — с клавиатурой его не
            // видно, казалось, что кнопка не работает. Показываем ещё и окном.
            .errorAlert($error)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "…" : "Сохранить") { Task { await save() } }
                        .disabled(saving || (fullName.trimmingCharacters(in: .whitespaces).isEmpty
                                             && phone.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
        // Смахивание листа вниз стирало заполненную карточку (ФИО, телефон,
        // PIN, оклад) без вопроса. С правками закрыть — только кнопкой «Отмена».
        .interactiveDismissDisabled(saving || hasEdits)
    }

    /// PIN меняет владелец или сам сотрудник в своей карточке (как на сервере).
    private var canPin: Bool {
        if Session.shared.isOwner { return true }
        guard let uid = employee?.userId, uid > 0 else { return false }
        return uid == Session.shared.user?.id
    }

    /// Что-то изменено относительно открытой карточки (или нового сотрудника).
    private var hasEdits: Bool {
        // По шагам, а не одним выражением: длинную цепочку с ?? компилятор
        // может не успеть разобрать («expression too complex»).
        let e = employee
        if clearPin { return true }
        let texts: [(String, String)] = [
            (fullName, e?.fullName ?? ""), (phone, e?.phone ?? ""), (email, e?.email ?? ""),
            (position, e?.position ?? ""), (status, e?.status ?? "active"), (pin, e?.pin ?? ""),
            (salaryType, e?.salaryType ?? "fixed"), (note, e?.note ?? ""),
        ]
        if texts.contains(where: { $0.0 != $0.1 }) { return true }
        if roleId != (e?.roleId ?? 0) { return true }
        let salary0: String = e?.salaryValue.map { "\($0)" } ?? ""
        let bonus0: String = e?.nightBonus.map { "\($0)" } ?? ""
        return salaryValue != salary0 || nightBonus != bonus0
    }

    @MainActor private func save() async {
        guard !saving else { return }   // двойной тап создавал двух сотрудников
        error = nil
        saving = true
        defer { saving = false }
        var fields: [String: Any?] = [
            "full_name": fullName.trimmingCharacters(in: .whitespaces),
            // Правка: пустое поле — пустая строка. nil выпадает из тела, и
            // стёртые телефон, почта, должность, заметка оставались прежними.
            // Пустую строку шлём, только если поле было заполнено и его стёрли:
            // у сотрудника без почты «email: ""» мог бы получить отказ проверки.
            "phone": phone.isEmpty ? ((employee?.phone ?? "").isEmpty ? nil : "") : phone,
            "email": email.isEmpty ? ((employee?.email ?? "").isEmpty ? nil : "") : email,
            "position": position.isEmpty ? (employee == nil ? nil : "") : position,
            "role_id": roleId,
            "status": status,
            "note": note.isEmpty ? (employee == nil ? nil : "") : note,
            "salary_type": salaryType,
        ]
        // Сервер PIN не отдаёт (pin = null, есть только has_pin), а пустая
        // строка его стирает. Раньше любая правка сотрудника (должность, оклад)
        // снимала PIN — кассир больше не мог войти на кассу. Теперь: новый PIN —
        // шлём, «Удалить PIN» — пустая строка, иначе ключ не уходит.
        let p = pin.trimmingCharacters(in: .whitespaces)
        // Правило PIN (4–12 цифр) проверяем до отправки: раньше «12а4» или «123»
        // уходили на сервер, и отказ всплывал поверх формы без подсказки, что не так.
        if !clearPin && !p.isEmpty
            && !((4...12).contains(p.count) && p.allSatisfy { $0.isASCII && $0.isNumber }) {
            error = "PIN — от 4 до 12 цифр, без букв и пробелов"
            return
        }
        // Не владелец и не своя карточка — PIN не трогаем (поле скрыто).
        if canPin {
            if employee == nil { fields["pin"] = p }
            else if clearPin { fields["pin"] = "" }
            else if !p.isEmpty { fields["pin"] = p }
        }
        // Деньги уходят СТРОКОЙ, как во всех остальных запросах платформы:
        // сервер приводит их (float), а Double в JSON печатается по правилам
        // плавающей точки (1234.56 -> 1234.5599999999999). Запятую с русской
        // клавиатуры по-прежнему принимаем.
        // Строгий разбор: оклад «45 000» раньше сохранялся как 45 ₽.
        for (raw, label) in [(salaryValue, "Оклад"), (nightBonus, "Ночная надбавка")] {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && Money.strict(t) == nil { error = "\(label) — число, например 45000"; return }
        }
        // Процентную ставку выше 100 сервер молча режет до 100
        // (seller_staff.php, staffEmployeePayload) — говорим до сохранения.
        if salaryType == "percent", let v = Money.strict(salaryValue), v > 100 {
            error = "Ставка в процентах — не больше 100"
            return
        }
        if let v = Money.strict(salaryValue) {
            fields["salary_value"] = "\(v)"
        } else if employee != nil && salaryValue.trimmingCharacters(in: .whitespaces).isEmpty {
            fields["salary_value"] = "0"
        }
        if let v = Money.strict(nightBonus) {
            fields["night_bonus"] = "\(v)"
        } else if employee != nil && nightBonus.trimmingCharacters(in: .whitespaces).isEmpty {
            fields["night_bonus"] = "0"
        }
        do {
            try await API.shared.saveEmployee(id: employee?.employeeId, fields: fields)
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
