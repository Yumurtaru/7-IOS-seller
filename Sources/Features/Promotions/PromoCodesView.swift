import SwiftUI

// ============================================================================
//  Промокоды — GET /api/seller/promos (promo_codes.*), создание POST (code,
//  type percent|fixed|free_delivery, value, min_order, max_uses, expires_at),
//  удаление DELETE /api/seller/promos/{id}.
// ============================================================================

@MainActor
final class PromoCodesViewModel: ObservableObject {
    @Published var items: [PromoCode] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    /// Пояснение после действия (не ошибка).
    @Published var notice: String?

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.promoCodes()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func create(code: String, type: String, value: Decimal, minOrder: Decimal,
                maxUses: Int?, expiresAt: Date?) async -> Bool {
        error = nil
        var expires: String?
        if let d = expiresAt {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "Europe/Moscow")
            expires = f.string(from: d)
        }
        // Снимок до запроса: без загруженного списка или если такой код уже был,
        // после обрыва связи «код на месте» не значит «создали мы».
        let listKnown = state == .loaded
        let existed = items.contains { ($0.code ?? "").uppercased() == code.uppercased() }
        do {
            _ = try await API.shared.createPromoCode(code: code, type: type, value: value,
                                                     minOrder: minOrder, maxUses: maxUses,
                                                     expiresAt: expires)
            await load()
            return true
        } catch {
            let msg = error.localizedDescription
            // Обрыв связи или таймаут: код мог уже создаться. Раньше окно
            // оставалось с ошибкой, повтор отвечал «такой код уже есть», а в
            // списке кода не было до обновления. Перечитываем: код на месте —
            // создан, окно закрываем.
            var dropped = false
            if let e = error as? APIError {
                switch e {
                case .network, .timeout: dropped = true
                default: break
                }
            }
            if dropped && listKnown && !existed {
                await load()
                if state == .loaded,
                   items.contains(where: { ($0.code ?? "").uppercased() == code.uppercased() }) {
                    return true
                }
            }
            self.error = msg
            return false
        }
    }

    /// Удаление этого кода уже в пути. Строка висит до ответа, её смахивали
    /// второй раз — второй DELETE получал 404, и над удачным удалением
    /// всплывала ошибка «Не найдено». Второе нажатие теперь пропускаем.
    private var deletingIds: Set<Int> = []

    func delete(_ promo: PromoCode) async {
        guard !deletingIds.contains(promo.promoId) else { return }
        deletingIds.insert(promo.promoId)
        defer { deletingIds.remove(promo.promoId) }
        error = nil
        notice = nil
        do {
            try await API.shared.deletePromoCode(id: promo.promoId)
            // Кодом уже пользовались — сервер его не удаляет, а выключает
            // (seller_settings.php, DELETE promos/{id}: used_count > 0): на него
            // ссылаются заказы. Раньше код пропадал из списка и возвращался
            // после обновления — казалось, что удаление не сработало.
            if (promo.usedCount ?? 0) > 0 {
                notice = "Код «\(promo.code ?? "")» уже применяли в заказах — он выключен, а не удалён, история сохранена"
                await load()
            } else {
                items.removeAll { $0.promoId == promo.promoId }
            }
        } catch {
            // Код уже удалили (сайт, другой телефон) или связь оборвалась после
            // удаления: перечитываем, иначе он висел в списке, и каждое
            // «Удалить» давало ту же ошибку.
            let msg = error.localizedDescription
            await load()
            self.error = msg
        }
    }
}

struct PromoCodesView: View {
    @StateObject private var vm = PromoCodesViewModel()
    @State private var showCreate = false
    /// Паритет с Android: удаление промокода — только после вопроса (раньше
    /// кнопка в свайпе удаляла код, уже розданный клиентам, сразу).
    @State private var deleteTarget: PromoCode?

    var body: some View {
        List {
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            if let note = vm.notice {
                Text(note).font(.footnote).foregroundColor(Brand.amber)
                    .listRowBackground(Brand.card)
            }
            ForEach(vm.items) { promo in
                PromoCodeRow(promo: promo)
                    .listRowBackground(Brand.card)
                    // Без полного свайпа: длинный жест удалял промокод, который
                    // уже раздали клиентам, без вопроса — только кнопкой.
                    .swipeActions(allowsFullSwipe: false) {
                        // Удаление промокода — то же право, что архивация акции.
                        if Session.shared.can("promotions.delete") {
                            Button(role: .destructive) {
                                deleteTarget = promo
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "ticket", emptyTitle: "Промокодов нет",
                   emptySubtitle: "Создайте код на скидку или бесплатную доставку",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Промокоды")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // Ошибка прошлого удаления не должна всплывать в новом окне создания.
                Button { vm.error = nil; showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .confirmationDialog(
            "Удалить промокод?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { promo in
            Button("Удалить «\(promo.code ?? "промокод")»", role: .destructive) {
                let p = promo
                deleteTarget = nil
                Task { await vm.delete(p) }
            }
            Button("Отмена", role: .cancel) { deleteTarget = nil }
        } message: { promo in
            Text((promo.usedCount ?? 0) > 0
                 ? "Кодом уже пользовались — он будет выключен, а история заказов сохранится."
                 : "Код перестанет действовать для клиентов.")
        }
        .sheet(isPresented: $showCreate) { PromoCodeCreateSheet(vm: vm) }
        .task { await vm.load() }
    }
}

struct PromoCodeRow: View {
    let promo: PromoCode

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(promo.code ?? "—")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.text)
                Spacer()
                StatusBadge(text: valueLabel, color: Brand.accent)
            }
            HStack(spacing: 8) {
                if let min = promo.minOrder, min > 0 { Text("от \(Money.rub(min))") }
                Text(usedText)
                if let exp = promo.expiresAt { Text("до \(DateFmt.short(exp))") }
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
            if promo.isActive != true {
                StatusBadge(text: "Выключен", color: Brand.muted)
            }
        }
        .padding(.vertical, 3)
    }

    /// «использован 2 раз» → «2 раза»; с лимитом — «2 из 10 раз», «0 из 1 раза».
    private var usedText: String {
        let n = promo.usedCount ?? 0
        if let limit = promo.maxUses {
            let one = limit % 10 == 1 && limit % 100 != 11
            return "использован \(n) из \(limit) " + (one ? "раза" : "раз")
        }
        let m100 = n % 100, m10 = n % 10
        let few = m10 >= 2 && m10 <= 4 && !(m100 >= 12 && m100 <= 14)
        return "использован \(n) " + (few ? "раза" : "раз")
    }

    private var valueLabel: String {
        switch promo.type {
        // 7,5% раньше показывалось как «−7%».
        case "percent":
            let s = NSDecimalNumber(decimal: promo.value ?? 0).stringValue.replacingOccurrences(of: ".", with: ",")
            return "−" + s + "%"
        case "fixed": return "−\(Money.rub(promo.value))"
        case "free_delivery": return "Бесплатная доставка"
        default: return promo.type ?? "—"
        }
    }
}

private struct PromoCodeCreateSheet: View {
    @ObservedObject var vm: PromoCodesViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var type = "percent"
    @State private var valueText = ""
    @State private var minOrderText = ""
    @State private var maxUsesText = ""
    @State private var hasExpiry = false
    @State private var expiresAt = Date().addingTimeInterval(30 * 86400)
    @State private var sending = false

    /// Скидка 0 (или 0 %) давала «рабочий» код без скидки, процент больше 100 —
    /// «−150%». У бесплатной доставки суммы нет.
    private var valueOK: Bool {
        if type == "free_delivery" { return true }
        guard let v = Money.strict(valueText), v > 0 else { return false }
        return type != "percent" || v <= 100
    }
    /// Лимит «0» создавал код, который нельзя применить ни разу. Пусто — без лимита.
    private var maxUsesOK: Bool {
        let t = maxUsesText.filter { !$0.isWhitespace }
        return t.isEmpty || (Int(t).map { $0 > 0 } ?? false)
    }

    /// Почему «Создать» серая. Раньше кнопка гасла молча (скидка 150 %, лимит 0,
    /// «1,5,0» в сумме) — казалось, что она не работает. Пустые поля не ругаем.
    private var blockReason: String? {
        let value = valueText.trimmingCharacters(in: .whitespaces)
        if type != "free_delivery" && !value.isEmpty && !valueOK {
            return type == "percent" ? "Скидка — число больше 0 и не больше 100 %" : "Скидка — число больше 0, например 300"
        }
        let minOrder = minOrderText.trimmingCharacters(in: .whitespaces)
        if !minOrder.isEmpty && Money.strict(minOrderText) == nil {
            return "Мин. сумма заказа — число, например 500"
        }
        if !maxUsesOK { return "Макс. использований — целое число больше 0 или пусто" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Промокод") {
                    TextField("Код (например, SALE20)", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Picker("Тип", selection: $type) {
                        Text("Процент").tag("percent")
                        Text("Фиксированная сумма").tag("fixed")
                        Text("Бесплатная доставка").tag("free_delivery")
                    }
                    if type != "free_delivery" {
                        TextField(type == "percent" ? "Скидка, %" : "Скидка, ₽", text: $valueText)
                            .keyboardType(.decimalPad)
                    }
                    TextField("Мин. сумма заказа, ₽ (0 = любая)", text: $minOrderText)
                        .keyboardType(.decimalPad)
                    TextField("Макс. использований (пусто = без лимита)", text: $maxUsesText)
                        .keyboardType(.numberPad)
                    Toggle("Срок действия", isOn: $hasExpiry).tint(Brand.accent)
                    if hasExpiry {
                        // Прошедшая дата создавала уже просроченный код.
                        DatePicker("Действует до", selection: $expiresAt, in: Date()...,
                                   displayedComponents: [.date, .hourAndMinute])
                    }
                }
                if let reason = blockReason {
                    Text(reason).font(.footnote).foregroundColor(Brand.amber)
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Новый промокод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "…" : "Создать") {
                        // Флаг — до Task: второй тап в том же кадре давал «код уже есть».
                        guard !sending, valueOK, maxUsesOK else { return }
                        sending = true
                        Task {
                            let ok = await vm.create(
                                code: code.trimmingCharacters(in: .whitespaces).uppercased(),
                                type: type,
                                // Строго: «1 000» раньше давало скидку 1 ₽, а лимит
                                // «1 000» — безлимит.
                                value: type == "free_delivery" ? 0 : (Money.strict(valueText) ?? 0),
                                minOrder: Money.strict(minOrderText) ?? 0,
                                maxUses: Int(maxUsesText.filter { !$0.isWhitespace }),
                                expiresAt: hasExpiry ? expiresAt : nil
                            )
                            sending = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(sending || code.trimmingCharacters(in: .whitespaces).isEmpty
                              // У «Бесплатной доставки» поля суммы нет — не требуем его.
                              || !valueOK
                              || (!minOrderText.trimmingCharacters(in: .whitespaces).isEmpty && Money.strict(minOrderText) == nil)
                              || !maxUsesOK)
                }
            }
        }
    }
}
