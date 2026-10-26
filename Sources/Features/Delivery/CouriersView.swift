import SwiftUI

// ============================================================================
//  Курьеры — routes/seller_couriers.php (пути /api/v1/seller/couriers, но
//  конверт обычный {ok,data}): GET список, POST создать (телефон = логин
//  в клиентское приложение), PUT правка (имя/пароль/права),
//  POST /{id}/block (unblock=1 — разблокировать), DELETE — отвязать от магазина.
//  Права — deny-by-default, каталог courierPermLabels() зеркалится в CourierPerms.
// ============================================================================

@MainActor
final class CouriersViewModel: ObservableObject {
    @Published var couriers: [Courier] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var createdLogin: String?
    /// created=false: у номера уже был аккаунт — курьер входит СВОИМ паролем,
    /// введённый здесь не применился. Раньше экран всё равно просил «передать
    /// курьеру логин и пароль», и курьер не мог войти с этим паролем.
    @Published var createdNotice: String?

    func load() async {
        if couriers.isEmpty { state = .loading }
        do {
            couriers = try await API.shared.couriers()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func create(name: String, phone: String, password: String, permissions: [String]) async -> Bool {
        error = nil
        do {
            let ack = try await API.shared.createCourier(name: name, phone: phone,
                                                         password: password, permissions: permissions)
            createdLogin = ack.login ?? ack.phone
            createdNotice = ack.created == false
                ? ((ack.notice?.isEmpty == false) ? ack.notice
                   : "У этого номера уже есть аккаунт: курьер входит своим прежним паролем, введённый пароль не применён.")
                : nil
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func update(id: Int, name: String?, password: String?, permissions: [String]?) async -> Bool {
        error = nil
        do {
            let nameSkipped = try await API.shared.updateCourier(id: id, name: name, password: password,
                                                                 permissions: permissions)
            await load()
            // Сервер молча не меняет имя чужого аккаунта (name_skipped) — раньше
            // экран закрывался как будто всё сохранено, а имя оставалось прежним.
            if nameSkipped {
                error = "Права сохранены, но имя не изменено: курьер входит своим аккаунтом Yumurta — имя меняет он сам."
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func toggleBlock(_ c: Courier) async {
        error = nil
        do {
            _ = try await API.shared.setCourierBlocked(id: c.id, unblock: c.status == "blocked")
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ c: Courier) async {
        error = nil
        do {
            try await API.shared.deleteCourier(id: c.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CouriersView: View {
    @StateObject private var vm = CouriersViewModel()
    @State private var editing: CourierEditTarget?
    /// паритет с Android: блокировка (курьер посреди доставки) и отвязка — только после вопроса.
    @State private var confirmBlock: Courier?
    @State private var confirmRemove: Courier?

    var body: some View {
        List {
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                    .listRowBackground(Brand.card)
            }
            if let login = vm.createdLogin {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Курьер создан").font(.subheadline.weight(.semibold)).foregroundColor(Brand.green)
                        if let notice = vm.createdNotice {
                            Text("Логин для клиентского приложения: \(login). " + notice)
                                .font(.caption).foregroundColor(Brand.amber)
                        } else {
                            Text("Логин для клиентского приложения: \(login). Передайте курьеру логин и пароль.")
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                }
                .listRowBackground(Brand.card)
            }
            ForEach(vm.couriers) { c in
                Button {
                    editing = CourierEditTarget(courier: c)
                } label: {
                    HStack {
                        Image(systemName: "figure.outdoor.cycle")
                            .foregroundColor(c.status == "blocked" ? Brand.muted : Brand.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name ?? "—")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text)
                            Text(c.phone ?? "")
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        if let n = c.activeOrders, n > 0 {
                            StatusBadge(text: "в пути: \(n)", color: .blue)
                        }
                        if c.status == "blocked" {
                            StatusBadge(text: "заблокирован", color: Brand.red)
                        }
                    }
                }
                .listRowBackground(Brand.card)
                // Без полного свайпа: длинный жест сразу удалял без вопроса
                // (сотрудник с PIN кассы, курьер, роль) — теперь только кнопкой.
                .swipeActions(allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        confirmRemove = c
                    } label: {
                        Label("Отвязать", systemImage: "trash")
                    }
                    // паритет с Android: курьера со своим аккаунтом Yumurta (account_owned = false)
                    // сервер блокировать не даёт — 409 (seller_couriers.php). Кнопку не показываем.
                    if c.accountOwned != false {
                        Button {
                            if c.status == "blocked" { Task { await vm.toggleBlock(c) } }
                            else { confirmBlock = c }
                        } label: {
                            Label(c.status == "blocked" ? "Разблокировать" : "Блокировать",
                                  systemImage: c.status == "blocked" ? "lock.open" : "lock")
                        }
                        .tint(Brand.amber)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Курьеры")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editing = CourierEditTarget(courier: nil) } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.couriers.isEmpty,
                   emptyIcon: "figure.outdoor.cycle", emptyTitle: "Курьеров нет",
                   emptySubtitle: "Курьер входит в клиентское приложение по телефону и паролю",
                   retry: { Task { await vm.load() } })
        .sheet(item: $editing) { target in
            CourierEditSheet(vm: vm, courier: target.courier)
        }
        .alert("Заблокировать курьера?", isPresented: Binding(
            get: { confirmBlock != nil },
            set: { if !$0 { confirmBlock = nil } }
        ), presenting: confirmBlock) { c in
            Button("Отмена", role: .cancel) { confirmBlock = nil }
            Button("Заблокировать", role: .destructive) {
                confirmBlock = nil
                Task { await vm.toggleBlock(c) }
            }
        } message: { c in
            Text(blockMessage(c))
        }
        .alert("Отвязать курьера?", isPresented: Binding(
            get: { confirmRemove != nil },
            set: { if !$0 { confirmRemove = nil } }
        ), presenting: confirmRemove) { c in
            Button("Отмена", role: .cancel) { confirmRemove = nil }
            Button("Отвязать", role: .destructive) {
                confirmRemove = nil
                Task { await vm.remove(c) }
            }
        } message: { c in
            Text("\(c.name ?? "Курьер") больше не сможет брать заказы этого заведения.")
        }
        .task { await vm.load() }
    }

    private func blockMessage(_ c: Courier) -> String {
        let n = c.activeOrders ?? 0
        let tail = n > 0 ? " Сейчас у него заказов в работе: \(n)." : ""
        return "\(c.name ?? "Курьер") не сможет войти и брать заказы, пока его не разблокируют." + tail
    }
}

struct CourierEditTarget: Identifiable {
    let id = UUID()
    let courier: Courier?
}

struct CourierEditSheet: View {
    @ObservedObject var vm: CouriersViewModel
    let courier: Courier?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var phone = ""
    @State private var password = ""
    @State private var perms: Set<String> = Set(CourierPerms.defaults)
    @State private var isSubmitting = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Курьер") {
                    // паритет с Android: имя и пароль чужого аккаунта меняет только сам курьер.
                    if foreign {
                        Text("Курьер входит своим аккаунтом Yumurta — имя и пароль меняет только он сам. Здесь можно поменять права.")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                    TextField("Имя *", text: $name)
                        .disabled(foreign)
                    if courier == nil {
                        TextField("Телефон (логин) *", text: $phone.phoneInput).keyboardType(.phonePad)
                    } else {
                        LabeledContent("Телефон", value: courier?.phone ?? "—")
                    }
                    // Сервер требует от 6 символов (seller_couriers.php: «Минимум 6 символов»),
                    // а приложение пускало 4–5 и получало отказ после нажатия.
                    if !foreign {
                        SecureField(courier == nil ? "Пароль (мин. 6 символов, если у номера ещё нет аккаунта Yumurta) *" : "Новый пароль (не менять — пусто)",
                                    text: $password)
                    }
                }
                Section("Права в приложении") {
                    ForEach(CourierPerms.all, id: \.self) { code in
                        Toggle(CourierPerms.label(code), isOn: Binding(
                            get: { perms.contains(code) },
                            set: { on in if on { perms.insert(code) } else { perms.remove(code) } }
                        ))
                        .tint(Brand.green)
                    }
                }
                if let err = localError {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer(); if isSubmitting { ProgressView() } else { Text("Сохранить").bold() }; Spacer() }
                    }
                    .disabled(isSubmitting || !isValid)
                } footer: {
                    // Подсказки «мин. 6 символов» пропадают, как только начали ввод, —
                    // серая «Сохранить» выглядела сломанной. Пишем, чего не хватает.
                    if let why = invalidReason { Text(why) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(courier == nil ? "Новый курьер" : "Курьер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
            .onAppear {
                if let c = courier {
                    name = c.name ?? ""
                    perms = Set(c.permissions ?? CourierPerms.defaults)
                }
            }
        }
    }

    /// Курьер со своим аккаунтом Yumurta (сервер: account_owned = false).
    private var foreign: Bool { courier?.accountOwned == false }

    private var isValid: Bool {
        if foreign { return true }   // правим только права
        let n = !name.trimmingCharacters(in: .whitespaces).isEmpty
        if courier == nil {
            return n && !phone.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 6
        }
        return n && (password.isEmpty || password.count >= 6)
    }

    /// Причина серой «Сохранить» — те же условия, что в isValid.
    private var invalidReason: String? {
        if foreign { return nil }
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Укажите имя курьера" }
        if courier == nil && phone.trimmingCharacters(in: .whitespaces).isEmpty { return "Укажите телефон — это логин курьера" }
        if courier == nil && password.count < 6 { return "Пароль — мин. 6 символов (если у номера ещё нет аккаунта Yumurta)" }
        if courier != nil && !password.isEmpty && password.count < 6 { return "Новый пароль — минимум 6 символов" }
        return nil
    }

    @MainActor private func submit() async {
        guard !isSubmitting else { return }   // двойной тап создавал двух курьеров
        // Телефон — это логин курьера в приложении. Опечатка (пропущенная цифра)
        // создавала аккаунт, в который курьер потом не мог войти.
        if courier == nil {
            let digitCount = phone.filter { $0.isASCII && $0.isNumber }.count
            if !(10...15).contains(digitCount) {
                localError = "Телефон — 10–11 цифр, например +7 900 123-45-67"
                return
            }
        }
        isSubmitting = true
        localError = nil
        let ok: Bool
        if let c = courier {
            // Имя шлём, только если его правили: иначе у чужого аккаунта сервер
            // на каждое сохранение прав отвечал бы «имя не изменено».
            let newName = name.trimmingCharacters(in: .whitespaces)
            // Чужому аккаунту имя и пароль не шлём: сервер их не меняет (пароль — 422).
            let foreignAcc = c.accountOwned == false
            ok = await vm.update(id: c.id, name: (foreignAcc || newName == (c.name ?? "")) ? nil : name,
                                 password: (foreignAcc || password.isEmpty) ? nil : password,
                                 permissions: Array(perms) + [CourierPerms.listMarker])
        } else {
            ok = await vm.create(name: name.trimmingCharacters(in: .whitespaces),
                                 phone: phone.trimmingCharacters(in: .whitespaces),
                                 password: password, permissions: Array(perms) + [CourierPerms.listMarker])
        }
        isSubmitting = false
        if ok { dismiss() } else { localError = vm.error }
    }
}
