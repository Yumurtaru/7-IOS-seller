import SwiftUI

// ============================================================================
//  Карточка клиента — GET /api/seller/clients/{id}: RFM, история заказов,
//  бонусы, любимые позиции. Действия:
//   • бонус POST /clients/{id}/bonus {amount, note} (минус = списание) → {balance}
//   • чёрный список POST /clients/{id}/blacklist {remove?} → {blacklisted}
//   • заметка PUT /clients/{id}/note {note} → {saved}
//     (503 «примените миграцию batch11_client_notes.sql» — показываем текстом)
// ============================================================================

@MainActor
final class ClientDetailViewModel: ObservableObject {
    @Published var detail: ClientDetail?
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var note = ""
    /// Заметка сохранена / сохраняется. Раньше кнопка молчала: ни «сохранено»,
    /// ни защиты от повторного нажатия — продавец не знал, ушла ли заметка.
    @Published var noteSaved = false
    @Published var savingNote = false

    let clientId: Int
    init(clientId: Int) { self.clientId = clientId }

    func load() async {
        if detail == nil { state = .loading }
        do {
            let d = try await API.shared.client(id: clientId)
            // Заметку из ответа подставляем, только если её не правили: load()
            // идёт и после бонуса/чёрного списка, и несохранённый текст пропадал.
            if detail == nil || note == (detail?.note ?? "") { note = d.note ?? "" }
            detail = d
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Итог начисления для окна: прошло / отказ / исход неизвестен (повтор — тем же
    /// телом с тем же ключом окна, второй раз сервер не начислит).
    enum BonusOutcome { case done, failed, unknown }

    /// keys — ключи окна начисления (IdempotencyKeys.form()).
    func grantBonus(amount: Decimal, note: String?, keys: IdempotencyKeys) async -> BonusOutcome {
        error = nil
        do {
            _ = try await API.shared.grantClientBonus(id: clientId, amount: amount, note: note, keys: keys)
            await load()
            return .done
        } catch {
            let msg = error.localizedDescription
            // Обрыв связи или таймаут: начисление могло пройти. Раньше окно
            // оставалось открытым с ошибкой, повторное «Применить» начисляло
            // баллы второй раз. Перечитываем карточку: баланс сдвинулся ровно
            // на эту сумму — значит, прошло, повторять не нужно.
            // паритет с Android: 5xx тоже сверяем — сервер мог упасть уже после начисления;
            // и любое изменение баланса — признак, что прошло (списание сервер мог урезать
            // до остатка, поэтому точную сумму не сравниваем).
            // Неизвестный исход — и 5xx с JSON-телом, и «первый запрос ещё идёт»
            // (API.keyedOutcomeUnknown): ключ окна postKeyed сохранил.
            if API.keyedOutcomeUnknown(error) {
                let before = detail?.bonusBalance
                await load()
                if let b = before, let after = detail?.bonusBalance, after != b {
                    keys.forgetAll()   // прошло — ключ окна больше не нужен
                    self.error = "Связь прервалась, но баланс бонусов изменился — проверьте историю ниже, повторять не нужно"
                    return .done
                }
                // Исход неизвестен: ключ окна остаётся, повтор не начислит второй раз.
                self.error = msg + ". Изменения баланса пока не видно — нажмите «Повторить»: второй раз не начислится."
                return .unknown
            }
            self.error = msg
            return .failed
        }
    }

    func toggleBlacklist() async {
        error = nil
        do {
            _ = try await API.shared.setClientBlacklist(id: clientId,
                                                        remove: detail?.blacklisted == true)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveNote() async {
        guard !savingNote else { return }
        savingNote = true
        defer { savingNote = false }
        error = nil
        noteSaved = false
        do {
            try await API.shared.saveClientNote(id: clientId,
                                                note: note.trimmingCharacters(in: .whitespacesAndNewlines))
            noteSaved = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ClientDetailView: View {
    @StateObject private var vm: ClientDetailViewModel
    var onChanged: (() -> Void)?
    @State private var showBonusSheet = false
    @State private var showBlacklistConfirm = false

    init(clientId: Int, onChanged: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ClientDetailViewModel(clientId: clientId))
        self.onChanged = onChanged
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let err = vm.error {
                    InlineErrorBar(message: err).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let d = vm.detail {
                    headerCard(d)
                    rfmCard(d)
                    actionsCard(d)
                    noteCard
                    if let top = d.topItems, !top.isEmpty { topItemsCard(top) }
                    if let orders = d.orders, !orders.isEmpty { ordersCard(orders) }
                    if let bonus = d.bonusHistory, !bonus.isEmpty { bonusCard(bonus) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        // У заметки (TextEditor) нет кнопки «Готово»: открытая клавиатура
        // закрывала «Сохранить заметку» и историю, убрать её было нечем.
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Клиент")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.detail == nil,
                   emptyIcon: "person", emptyTitle: "Нет данных",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $showBonusSheet) {
            BonusSheet(vm: vm, onDone: { onChanged?() })
        }
        .confirmationDialog(
            vm.detail?.blacklisted == true ? "Убрать клиента из чёрного списка?" : "Добавить клиента в чёрный список?",
            isPresented: $showBlacklistConfirm, titleVisibility: .visible
        ) {
            Button(vm.detail?.blacklisted == true ? "Убрать из ЧС" : "В чёрный список",
                   role: vm.detail?.blacklisted == true ? nil : .destructive) {
                Task { await vm.toggleBlacklist(); onChanged?() }
            }
        }
        .task { await vm.load() }
    }

    // ── Шапка ────────────────────────────────────────────────────────────────
    private func headerCard(_ d: ClientDetail) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(d.name ?? "Без имени")
                        .font(.title3.weight(.bold))
                        .foregroundColor(Brand.text)
                    if d.blacklisted == true { StatusBadge(text: "Чёрный список", color: Brand.red) }
                    Spacer()
                }
                if let phone = d.phone, !phone.isEmpty {
                    Button {
                        let clean = phone.filter { "+0123456789".contains($0) }
                        if let url = URL(string: "tel://\(clean)") { UIApplication.shared.open(url) }
                    } label: {
                        Label(phone, systemImage: "phone.fill").font(.subheadline)
                    }
                    .tint(Brand.green)
                }
                if let email = d.email, !email.isEmpty {
                    Label(email, systemImage: "envelope")
                        .font(.subheadline).foregroundColor(Brand.muted)
                }
                InfoRow(label: "Бонусный баланс", value: Money.rub(d.bonusBalance))
                if let first = d.firstOrder {
                    InfoRow(label: "Первый заказ", value: DateFmt.short(first))
                }
                if let freq = d.frequencyDays {
                    InfoRow(label: "Частота покупок", value: "раз в \(freq) дн.")
                }
            }
        }
    }

    // ── RFM ─────────────────────────────────────────────────────────────────
    private func rfmCard(_ d: ClientDetail) -> some View {
        SectionCard(title: "RFM-сегмент") {
            if let rfm = d.rfm {
                HStack(spacing: 10) {
                    rfmMetric("Давность", "\(rfm.recency ?? 0) дн.")
                    rfmMetric("Заказов", "\(rfm.frequency ?? 0)")
                    rfmMetric("Сумма", Money.rub(rfm.monetary))
                }
                HStack {
                    Text("Сегмент").font(.subheadline).foregroundColor(Brand.muted)
                    Spacer()
                    StatusBadge(text: ClientSegments.label(rfm.segment),
                                color: ClientSegments.color(rfm.segment))
                }
            } else {
                Text("Нет данных").font(.subheadline).foregroundColor(Brand.muted)
            }
        }
    }

    private func rfmMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption2).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Brand.chip)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // ── Действия ─────────────────────────────────────────────────────────────
    // Бонусы и чёрный список закрыты отдельными правами внутри «Клиентов»:
    // видеть карточку клиента и раздавать баллы — разные полномочия.
    @ViewBuilder
    private func actionsCard(_ d: ClientDetail) -> some View {
        let canBonus = Session.shared.can("customers.bonus")
        let canBlacklist = Session.shared.can("customers.blacklist")
        if canBonus || canBlacklist {
            HStack(spacing: 10) {
                if canBonus {
                    // Ошибка прошлого действия (чёрный список, заметка) не должна
                    // висеть в окне бонусов, будто отказали в начислении.
                    Button { vm.error = nil; showBonusSheet = true } label: {
                        Label("Бонус", systemImage: "gift")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
                }
                if canBlacklist {
                    Button { showBlacklistConfirm = true } label: {
                        Label(d.blacklisted == true ? "Из ЧС" : "В ЧС", systemImage: "hand.raised")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(d.blacklisted == true ? Brand.green : Brand.red)
                }
            }
        }
    }

    // ── Заметка ──────────────────────────────────────────────────────────────
    private var noteCard: some View {
        SectionCard(title: "Заметка о клиенте") {
            TextEditor(text: $vm.note)
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .background(Brand.chip)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack(spacing: 10) {
                Button(vm.savingNote ? "Сохраняем…" : "Сохранить заметку") {
                    Task { await vm.saveNote() }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(Brand.accent)
                .disabled(vm.savingNote)
                if vm.noteSaved {
                    Text("Сохранено").font(.footnote).foregroundColor(Brand.green)
                }
            }
        }
        // Правка после сохранения снимает «Сохранено».
        .onChange(of: vm.note) { _ in vm.noteSaved = false }
    }

    // ── Любимые позиции ──────────────────────────────────────────────────────
    private func topItemsCard(_ items: [ClientTopItem]) -> some View {
        SectionCard(title: "Часто заказывает") {
            // По порядку, а не по названию: две позиции с одним именем (разные
            // товары, варианты) давали одинаковый id, и строка рисовалась дважды.
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                    Spacer()
                    // Весовой товар: 2,5 кг было «×2» (обрезка до целого);
                    // «в 1 заказах» — склоняем.
                    Text("×\(QtyFmt.qty(item.qty)) в \(Self.inOrders(item.times ?? 0))")
                        .font(.caption).foregroundColor(Brand.muted)
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// «1 заказе», «3 заказах», «21 заказе».
    private static func inOrders(_ n: Int) -> String {
        (n % 10 == 1 && n % 100 != 11) ? "\(n) заказе" : "\(n) заказах"
    }

    // ── История заказов ──────────────────────────────────────────────────────
    private func ordersCard(_ orders: [ClientOrder]) -> some View {
        SectionCard(title: "Заказы (\(orders.count))") {
            ForEach(orders) { order in
                HStack {
                    Text("№\(order.orderId)")
                        .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                    StatusBadge(text: OrderStatuses.label(order.status),
                                color: OrderStatuses.color(order.status))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Money.rub(order.total))
                            .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                        Text(DateFmt.short(order.createdAt))
                            .font(.caption2).foregroundColor(Brand.muted)
                    }
                }
                .padding(.vertical, 3)
                if order.orderId != orders.last?.orderId {
                    Divider().overlay(Brand.border)
                }
            }
        }
    }

    // Раньше всё, что не earn, подписывалось «Списание»: и сгоревшие баллы, и
    // ручное начисление продавцом другого типа. Известные типы — по названию,
    // остальные — по знаку суммы.
    private static func bonusIsPlus(_ tx: BonusTransaction) -> Bool {
        switch tx.type {
        case "earn": return true
        case "spend", "expire": return false
        default: return (tx.amount ?? 0) >= 0
        }
    }

    private static func bonusTitle(_ tx: BonusTransaction, plus: Bool) -> String {
        switch tx.type {
        case "earn": return "Начисление"
        case "spend": return "Списание"
        case "expire": return "Сгорели"
        default: return plus ? "Начисление" : "Списание"
        }
    }

    // ── История бонусов ──────────────────────────────────────────────────────
    private func bonusCard(_ history: [BonusTransaction]) -> some View {
        SectionCard(title: "Бонусы") {
            ForEach(history) { tx in
                let plus = Self.bonusIsPlus(tx)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.bonusTitle(tx, plus: plus))
                            .font(.subheadline).foregroundColor(Brand.text)
                        Text(DateFmt.short(tx.createdAt))
                            .font(.caption2).foregroundColor(Brand.muted)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        // Знак ставим сами, сумму — по модулю: отрицательная сумма
                        // из базы давала «−-250 ₽».
                        Text((plus ? "+" : "−") + Money.rub(abs(tx.amount ?? 0)))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(plus ? Brand.green : Brand.red)
                        // паритет с Android: остаток бонусов после операции.
                        if let after = tx.balanceAfter {
                            Text(Money.rub(after)).font(.caption2).foregroundColor(Brand.muted)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Лист начисления/списания бонусов.
private struct BonusSheet: View {
    @ObservedObject var vm: ClientDetailViewModel
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var isWithdraw = false
    @State private var note = ""
    @State private var sending = false
    /// Ключ повтора — на это окно (закрыли — пропал).
    @State private var idem = IdempotencyKeys.form()
    /// Исход последней попытки неизвестен: сумма, операция и комментарий
    /// заблокированы — «Повторить» уходит тем же телом с тем же ключом.
    @State private var unknown = false

    /// Строгий разбор суммы: Decimal(string:) читает начало строки, и «1 500»
    /// давало 1.
    private var parsedAmount: Decimal? {
        let t = String(amountText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            .replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              t.filter({ $0 == "." }).count <= 1 else { return nil }
        return Decimal(string: t)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Операция", selection: $isWithdraw) {
                        Text("Начислить").tag(false)
                        Text("Списать").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(sending || unknown)
                    TextField("Сумма, ₽", text: $amountText)
                        .keyboardType(.decimalPad)
                        .disabled(sending || unknown)
                    TextField("Комментарий (необязательно)", text: $note)
                        .disabled(sending || unknown)
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Бонусы клиенту")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Пока начисление в пути — окно не закрываем (ключ повтора живёт с окном).
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "…" : (unknown ? "Повторить" : "Применить")) {
                        // Двойной тап начислял дважды: sending ставился уже внутри Task.
                        guard !sending, let amount = parsedAmount, amount > 0 else { return }
                        sending = true
                        Task {
                            let r = await vm.grantBonus(amount: isWithdraw ? -amount : amount,
                                                        note: note.isEmpty ? nil : note, keys: idem)
                            sending = false
                            unknown = r == .unknown
                            if r == .done { onDone(); dismiss() }
                        }
                    }
                    // «0» проходил проверку кнопки, а нажатие молча ничего не делало.
                    .disabled(sending || (parsedAmount ?? 0) <= 0)
                }
            }
        }
        .interactiveDismissDisabled(sending)
    }
}
