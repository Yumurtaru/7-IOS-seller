import SwiftUI

// ============================================================================
//  Роли и права (RBAC) — GET /api/seller/staff/roles (системные создаются
//  лениво на сервере), матрица прав из GET /api/seller/staff/permissions
//  (каталог {группа:[[code,label,desc]]} + пресеты). CRUD:
//  POST/PUT/DELETE /api/seller/staff/roles[/{id}]. Системную роль нельзя
//  удалить; права роли admin сервер принудительно оставляет полными.
// ============================================================================

@MainActor
final class RolesViewModel: ObservableObject {
    @Published var roles: [StaffRole] = []
    @Published var info: StaffPermissionsInfo?
    @Published var state: LoadState = .idle
    @Published var error: String?

    /// Порядок групп — как в core/StaffRBAC.php (JSON-объект порядок не хранит).
    static let groupOrder = ["Продажи и заказы", "Каталог", "Склад", "Аналитика", "Управление", "Касса (POS)"]

    var orderedGroups: [(String, [[String]])] {
        guard let catalog = info?.catalog else { return [] }
        let known = Self.groupOrder.compactMap { name in catalog[name].map { (name, $0) } }
        let extra = catalog.keys.filter { !Self.groupOrder.contains($0) }.sorted()
            .compactMap { name in catalog[name].map { (name, $0) } }
        return known + extra
    }

    func load() async {
        if roles.isEmpty { state = .loading }
        do {
            async let r = API.shared.staffRoles()
            async let i = API.shared.staffPermissions()
            roles = try await r
            info = try await i
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Удаление роли в пути: строка висит до ответа, второе «Удалить» слало
    /// второй DELETE, сервер отвечал 404 — ошибка поверх удачного удаления.
    private var deletingIds: Set<Int> = []

    func delete(_ role: StaffRole) async {
        guard !deletingIds.contains(role.roleId) else { return }
        deletingIds.insert(role.roleId)
        defer { deletingIds.remove(role.roleId) }
        error = nil
        do {
            try await API.shared.deleteStaffRole(id: role.roleId)
            roles.removeAll { $0.roleId == role.roleId }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RolesView: View {
    @StateObject private var vm = RolesViewModel()
    @State private var editTarget: RoleEditTarget?
    /// Паритет с Android: удаление роли — с подтверждением.
    @State private var deleteTarget: StaffRole?

    /// Роли создаёт, меняет и удаляет только владелец (seller_staff.php,
    /// staff/roles: StaffAccess::isOwner, иначе 403). Сотрудник с правом
    /// «Сотрудники» раньше настраивал матрицу и получал отказ при сохранении.
    private var canEdit: Bool { Session.shared.isOwner }

    var body: some View {
        List {
            if !canEdit {
                Text("Роли и права меняет только владелец организации — здесь их можно посмотреть.")
                    .font(.footnote).foregroundColor(Brand.amber)
                    .listRowBackground(Brand.card)
            }
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            ForEach(vm.roles) { role in
                Button { editTarget = RoleEditTarget(role: role) } label: {
                    RoleRow(role: role)
                }
                .buttonStyle(.plain)
                .listRowBackground(Brand.card)
                // Без полного свайпа: длинный жест сразу удалял без вопроса
                // (сотрудник с PIN кассы, курьер, роль) — теперь только кнопкой.
                .swipeActions(allowsFullSwipe: false) {
                    if role.isSystem != true && canEdit {
                        Button(role: .destructive) {
                            deleteTarget = role
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Удалить роль?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { role in
            Button("Удалить «\(role.name ?? "роль")»", role: .destructive) {
                let r = role
                deleteTarget = nil
                Task { await vm.delete(r) }
            }
            Button("Отмена", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("Сотрудники с этой ролью останутся без роли и её прав.")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.roles.isEmpty,
                   emptyIcon: "person.badge.key", emptyTitle: "Ролей нет",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Роли и права")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if canEdit {
                    Button { editTarget = RoleEditTarget(role: nil) } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(item: $editTarget) { target in
            RoleEditSheet(role: target.role, vm: vm, onSaved: { Task { await vm.load() } })
        }
        .task { await vm.load() }
    }
}

struct RoleEditTarget: Identifiable {
    let role: StaffRole?
    var id: Int { role?.roleId ?? -1 }
}

struct RoleRow: View {
    let role: StaffRole

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: role.color) ?? Brand.muted)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(role.name ?? "Роль")
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Brand.text)
                    if role.isSystem == true {
                        StatusBadge(text: "Системная", color: Brand.muted)
                    }
                }
                // «1 прав · 1 сотрудников» — склоняем.
                Text(Self.plural(role.permissions.values.filter { $0 }.count, "право", "права", "прав")
                     + " · " + Self.plural(role.members ?? 0, "сотрудник", "сотрудника", "сотрудников"))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(Brand.muted)
        }
        .padding(.vertical, 4)
    }

    private static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m100 = n % 100, m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "\(n) \(many)" }
        if m10 == 1 { return "\(n) \(one)" }
        if m10 >= 2 && m10 <= 4 { return "\(n) \(few)" }
        return "\(n) \(many)"
    }
}

// ── Редактор роли: имя + матрица прав по группам каталога ────────────────────
struct RoleEditSheet: View {
    let role: StaffRole?
    @ObservedObject var vm: RolesViewModel
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var permissions: [String: Bool]
    @State private var error: String?
    @State private var saving = false

    private var isAdmin: Bool { role?.code == "admin" }

    init(role: StaffRole?, vm: RolesViewModel, onSaved: @escaping () -> Void) {
        self.role = role
        self.vm = vm
        self.onSaved = onSaved
        _name = State(initialValue: role?.name ?? "")
        _permissions = State(initialValue: role?.permissions ?? [:])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Роль") {
                    TextField("Название роли", text: $name)
                        .disabled(role?.isSystem == true)
                    if role == nil, let presets = vm.info?.presets, !presets.isEmpty {
                        Menu("Заполнить из пресета") {
                            ForEach(presets) { preset in
                                Button(preset.name ?? preset.id) {
                                    permissions = preset.permissions
                                    if name.isEmpty { name = preset.name ?? "" }
                                }
                            }
                        }
                        .tint(Brand.accent)
                    }
                    if isAdmin {
                        Text("Администратор всегда имеет все права — сервер не даст их урезать.")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                }
                ForEach(vm.orderedGroups, id: \.0) { group, perms in
                    Section(group) {
                        ForEach(perms.indices, id: \.self) { i in
                            let code = perms[i].count > 0 ? perms[i][0] : ""
                            let label = perms[i].count > 1 ? perms[i][1] : code
                            let hint = perms[i].count > 2 ? perms[i][2] : ""
                            Toggle(isOn: Binding(
                                get: { permissions[code] == true },
                                set: { permissions[code] = $0 }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(label).font(.subheadline)
                                    if !hint.isEmpty {
                                        Text(hint).font(.caption2).foregroundColor(Brand.muted)
                                    }
                                }
                            }
                            .tint(Brand.green)
                            .disabled(isAdmin)
                        }
                    }
                }
                if let err = error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(role == nil ? "Новая роль" : (role?.name ?? "Роль"))
            .navigationBarTitleDisplayMode(.inline)
            // Ошибка сохранения писалась под всей матрицей прав (десятки
            // переключателей) — после «Сохранить» вверху её не видно.
            .errorAlert($error)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "…" : "Сохранить") {
                        guard !saving else { return }
                        saving = true   // сразу: двойное нажатие создавало две роли
                        Task { await save() }
                    }
                        // Не владелец — только просмотр (сервер ответит 403).
                        .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || !Session.shared.isOwner)
                }
            }
        }
        // Матрица прав — десятки переключателей в длинном списке: смахивание
        // вниз у верхнего края закрывало лист и теряло всю настройку без вопроса.
        .interactiveDismissDisabled(saving || hasEdits)
    }

    private var hasEdits: Bool {
        let n0: String = role?.name ?? ""
        let p0: [String: Bool] = role?.permissions ?? [:]
        return name != n0 || permissions != p0
    }

    private func save() async {
        error = nil
        saving = true
        defer { saving = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        do {
            if let role = role {
                try await API.shared.updateStaffRole(id: role.roleId,
                                                     name: role.isSystem == true ? nil : trimmed,
                                                     color: nil,
                                                     permissions: isAdmin ? nil : permissions)
            } else {
                _ = try await API.shared.createStaffRole(name: trimmed, preset: nil,
                                                         permissions: permissions, color: nil)
            }
            onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
