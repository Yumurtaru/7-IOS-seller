import SwiftUI

// ============================================================================
//  Лояльность / кешбэк — GET /api/seller/loyalty (loyalty_programs или дефолт
//  {cashback_percent:0, …, is_active:0}), сохранение POST /api/seller/loyalty.
// ============================================================================

@MainActor
final class LoyaltyViewModel: ObservableObject {
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var success = false
    @Published var saving = false
    /// К-57: последний ответ сервера (режим, лимит списания, QR-правило, ограничения).
    @Published var program: LoyaltyProgram?
    @Published var limitText = ""

    // Правка после сохранения снимает «Сохранено»: надпись висела над
    // уже изменёнными и ещё не сохранёнными полями.
    @Published var isActive = false { didSet { success = false } }
    @Published var cashbackText = "" { didSet { success = false } }
    @Published var minOrderText = "" { didSet { success = false } }
    @Published var expireDaysText = "" { didSet { success = false } }

    func load() async {
        state = .loading
        do {
            let lp = try await API.shared.loyalty()
            isActive = lp.isActive ?? false
            cashbackText = lp.cashbackPercent.map { "\($0)" } ?? "0"
            minOrderText = lp.minOrderForCashback.map { "\($0)" } ?? "0"
            expireDaysText = lp.pointsExpireDays.map(String.init) ?? ""
            program = lp
            limitText = lp.pointsRedeemMaxPercent.map { "\($0)" } ?? ""
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// К-57: PUT только изменённых полей; ответ {saved:true} — перечитываем GET (без сброса
    /// несохранённых правок четырёх старых полей). 422 — текст сервера.
    func patch(_ fields: [String: Any?]) async {
        guard state == .loaded, !saving else { return }
        saving = true
        defer { saving = false }
        error = nil
        success = false
        do {
            try await API.shared.patchLoyalty(fields)
            success = true
        } catch {
            self.error = error.localizedDescription
        }
        // Успех или отказ — на экране то, что на сервере (переключатель не врёт).
        if let lp = try? await API.shared.loyalty() {
            program = lp
            limitText = lp.pointsRedeemMaxPercent.map { "\($0)" } ?? ""
        }
    }

    func saveLimit() async {
        let raw = limitText.trimmingCharacters(in: .whitespaces)
        guard let v = Money.strict(raw), v >= 0, v <= 100 else {
            error = "Лимит списания — число от 0 до 100"
            return
        }
        await patch(["points_redeem_max_percent": "\(v)"])
    }

    func save() async {
        // Настройки не прочитаны (идёт загрузка или она упала) — в полях пусто,
        // и «Сохранить» выключало программу и обнуляло кешбэк на сервере.
        // Двойной тап — один запрос.
        guard state == .loaded, !saving else { return }
        saving = true
        defer { saving = false }
        error = nil
        success = false
        // Строгий разбор: «1 000» раньше давало 1 ₽, а «30 » в сроке — «бессрочно».
        let cbRaw = cashbackText.trimmingCharacters(in: .whitespaces)
        let moRaw = minOrderText.trimmingCharacters(in: .whitespaces)
        let edRaw = expireDaysText.filter { !$0.isWhitespace }
        // «Кешбэк» — как в подписях формы выше (было «Кэшбэк» только здесь).
        guard cbRaw.isEmpty || Money.strict(cbRaw) != nil else { error = "Кешбэк — число, например 5"; return }
        guard moRaw.isEmpty || Money.strict(moRaw) != nil else { error = "Минимальный заказ — число, например 500"; return }
        guard edRaw.isEmpty || Int(edRaw) != nil else { error = "Срок жизни баллов — целое число дней"; return }
        do {
            try await API.shared.saveLoyalty(
                cashbackPercent: cbRaw.isEmpty ? 0 : (Money.strict(cbRaw) ?? 0),
                minOrder: moRaw.isEmpty ? 0 : (Money.strict(moRaw) ?? 0),
                expireDays: Int(edRaw),
                isActive: isActive
            )
            success = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LoyaltyView: View {
    @StateObject private var vm = LoyaltyViewModel()
    /// А116: сохранение (POST /api/seller/loyalty) — право «Начислять бонусы»
    /// (StaffAccess::actionPerms → customers.bonus), иначе 403. Без права — просмотр.
    private var canEdit: Bool { Session.shared.can("customers.bonus") }

    var body: some View {
        Form {
            // Заголовок строкой и footer вместе SwiftUI не принимает:
            // инициализатора Section(_:content:footer:) не существует.
            // Поэтому заголовок тоже отдельным замыканием.
            Section {
                Toggle("Программа включена", isOn: $vm.isActive).tint(Brand.green)
                HStack {
                    Text("Кешбэк, %")
                    Spacer()
                    TextField("0", text: $vm.cashbackText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                HStack {
                    Text("Мин. заказ, ₽")
                    Spacer()
                    TextField("0", text: $vm.minOrderText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
                HStack {
                    Text("Баллы сгорают через, дн.")
                    Spacer()
                    TextField("∞", text: $vm.expireDaysText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            } header: {
                Text("Кешбэк баллами")
            } footer: {
                Text("Баллы начисляются автоматически при выполнении заказа (1 балл = 1 ₽)."
                     + (canEdit ? "" : "\nПроцент кешбэка и условия программы меняет владелец или сотрудник с правом «Начислять бонусы»."))
            }
            .disabled(!canEdit)

            modeSection

            Section {
                Button("Сохранить") { Task { await vm.save() } }
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .foregroundColor(Brand.accent)
                    .disabled(vm.state != .loaded || vm.saving || !canEdit)
                if vm.success {
                    Text("Сохранено").font(.footnote).foregroundColor(Brand.green)
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Лояльность")
        .navigationBarTitleDisplayMode(.inline)
        .listState(vm.state, isEmpty: vm.state != .loaded,
                   emptyIcon: "heart", emptyTitle: "Загрузка…",
                   retry: { Task { await vm.load() } })
        // Один раз (или после ошибки): возврат на вкладку затирал правки.
        .task { if vm.state != .loaded { await vm.load() } }
    }

    // ── К-57: режим программы, списание только по QR, лимит, табак ───────────
    /// Старый сервер ничего из этого не шлёт — секции нет.
    @ViewBuilder
    private var modeSection: some View {
        if let p = vm.program,
           p.mode != nil || p.cardSpendVerifiedOnly != nil || p.pointsRedeemMaxPercent != nil
            || (p.systemRestrictedCount ?? 0) > 0 {
            Section {
                if let mode = p.mode {
                    Text(mode == "discount" ? "Режим: скидка \(p.cashbackPercent ?? 0) %" : "Режим: кэшбэк баллами")
                        .font(.subheadline.weight(.semibold))
                    Picker("Режим", selection: Binding(
                        get: { mode == "discount" ? "discount" : "cashback" },
                        set: { new in
                            guard new != mode else { return }
                            Task { await vm.patch(["mode": new]) }
                        }
                    )) {
                        Text("Кэшбэк").tag("cashback")
                        Text("Скидка").tag("discount")
                    }
                    .pickerStyle(.segmented)
                    Text("Проценты по категориям и исключения — в кабинете на сайте")
                        .font(.footnote).foregroundColor(Brand.muted)
                }
                if let on = p.cardSpendVerifiedOnly {
                    Toggle("Списывать баллы только по одноразовому QR", isOn: Binding(
                        get: { on },
                        set: { new in Task { await vm.patch(["card_spend_verified_only": new]) } }
                    )).tint(Brand.green)
                }
                if p.pointsRedeemMaxPercent != nil {
                    HStack {
                        Text("Лимит списания, %")
                        Spacer()
                        TextField("0", text: $vm.limitText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    if let eff = p.pointsRedeemMaxPercentEffective {
                        Text("Действует сейчас: \(eff) %").font(.footnote).foregroundColor(Brand.muted)
                    }
                    Button("Сохранить лимит") { Task { await vm.saveLimit() } }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.accent)
                }
                Text("Табак и никотин: без скидок и баллов (по закону)")
                    .font(.footnote).foregroundColor(Brand.muted)
                if let n = p.systemRestrictedCount, n > 0 {
                    Text("Исключено системой: \(n)").font(.footnote).foregroundColor(Brand.muted)
                }
            }
            .disabled(!canEdit || vm.saving)
        }
    }
}
