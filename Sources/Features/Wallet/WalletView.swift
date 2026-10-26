import SwiftUI
import Combine

// ============================================================================
//  Кошелёк — GET /api/seller/wallet (balance, history, pending, plan, low).
//  Пополнение POST /api/seller/wallet/topup (мин. 100 ₽):
//   • bank_transfer → реквизиты (ИНН/счёт/БИК/назначение), статус pending,
//     отмена POST .../topup/{id}/cancel;
//   • card_online / sbp → {status:"redirect", topup_id, confirmation_url}:
//     открываем страницу оплаты ЮKassa в SFSafariViewController и опрашиваем
//     GET .../topup/{id}, пока провайдер не подтвердит платёж. Деньги
//     зачисляются только по подтверждению — сами мы баланс не поднимаем.
//  Низкий баланс (low=true, < 500 ₽) — warning-баннер.
// ============================================================================

@MainActor
final class WalletViewModel: ObservableObject {
    @Published var data: WalletData?
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var payLink: PayLink?
    @Published var requisites: TopupRequisites?
    @Published var successMessage: String?
    /// Ждём подтверждения оплаты по этому пополнению (nil — не ждём).
    @Published var awaitingTopupId: Int?
    /// Опрос статуса. Отдельная задача: новый запуск отменяет предыдущий,
    /// два опроса параллельно не идут.
    /// Задача держит self слабо, поэтому при уходе экрана опрос сам
    /// прекращается — отдельный deinit не нужен (в Swift 6 обращение к
    /// изолированному свойству из deinit всё равно запрещено).
    private var watchTask: Task<Void, Never>?

    /// Паритет с Android: обновление не удалось, а на экране прежний баланс.
    @Published var refreshError: String?

    func load() async {
        if data == nil { state = .loading }
        do {
            data = try await API.shared.wallet()
            state = .loaded
            refreshError = nil
        } catch is CancellationError {
        } catch {
            // Раньше при показанных данных ошибка не выводилась нигде, и
            // продавец считал старый баланс свежим.
            if data == nil { state = .failed(error.localizedDescription) }
            else { refreshError = error.localizedDescription }
        }
    }

    // Ссылку на оплату и реквизиты показываем ПОСЛЕ закрытия листа пополнения:
    // пока он на экране, SwiftUI не может показать второй лист — страница
    // ЮKassa (или реквизиты) молча не открывалась, а экран 5 минут писал
    // «Ожидаем оплату».
    var topupSheetOpen = false
    private var pendingPayLink: PayLink?
    private var pendingRequisites: TopupRequisites?

    func presentPending() {
        if let l = pendingPayLink { payLink = l }
        if let r = pendingRequisites { requisites = r }
        pendingPayLink = nil; pendingRequisites = nil
    }

    func topup(amount: Decimal, method: String) async -> Bool {
        error = nil
        successMessage = nil
        defer { if !topupSheetOpen { presentPending() } }
        do {
            let res = try await API.shared.walletTopup(amount: amount, method: method)
            if let url = res.payURL {
                // Онлайн-оплата: открываем страницу ЮKassa и ждём подтверждения.
                pendingPayLink = PayLink(url: url)
                if let id = res.topupId, id > 0 {
                    awaitingTopupId = id
                    successMessage = "Ожидаем оплату. Баланс обновится сам, как только ЮKassa подтвердит платёж."
                    watch(id: id)
                }
            } else if res.status == "confirmed" {
                // Старый сервер, файлы ещё не выложены.
                successMessage = "Кошелёк пополнен на \(Money.rub(amount))"
            } else if res.status == "pending" {
                pendingRequisites = res.requisites      // банковский перевод
            }
            await load()
            return true
        } catch {
            var msg = error.localizedDescription
            // Паритет с Android: обрыв связи после отправки — заявка могла уже
            // создаться (у перевода — с реквизитами), а повтор заводил вторую.
            // Перечитываем кошелёк и прямо просим проверить список.
            if let e = error as? APIError {
                switch e {
                case .network, .timeout:
                    msg += ". Заявка могла создаться — закройте окно и проверьте «Ожидают подтверждения», прежде чем повторять"
                    await load()
                default: break
                }
            }
            self.error = msg
            return false
        }
    }

    /// Ждём ответа ЮKassa примерно 5 минут. Обрыв связи отказом не считаем —
    /// запрос просто повторяется, платёж от этого не пропадает.
    private func watch(id: Int) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.awaitingTopupId == id else { return }
                guard let res = try? await API.shared.walletTopupStatus(id: id) else { continue }
                if Task.isCancelled { return }
                switch res.status {
                case "confirmed":
                    self.awaitingTopupId = nil
                    self.successMessage = "Кошелёк пополнен на \(Money.rub(res.amount ?? 0))"
                    await self.load()
                    return
                case "rejected":
                    self.awaitingTopupId = nil
                    self.successMessage = nil
                    self.error = "Платёж не прошёл. Деньги не списаны, можно попробовать ещё раз."
                    await self.load()
                    return
                default:
                    continue
                }
            }
            guard let self, self.awaitingTopupId == id else { return }
            self.awaitingTopupId = nil
            self.successMessage = "Платёж обрабатывается. Баланс обновится сам — деньги не потеряются."
            await self.load()
        }
    }

    /// Пользователь закрыл страницу оплаты — проверяем статус сразу, не дожидаясь
    /// следующего тика опроса.
    func checkNow() async {
        guard let id = awaitingTopupId else { await load(); return }
        if let res = try? await API.shared.walletTopupStatus(id: id) {
            if res.status == "confirmed" {
                awaitingTopupId = nil
                successMessage = "Кошелёк пополнен на \(Money.rub(res.amount ?? 0))"
            } else if res.status == "rejected" {
                awaitingTopupId = nil
                successMessage = nil
                error = "Платёж не прошёл. Деньги не списаны, можно попробовать ещё раз."
            }
        }
        await load()
    }

    /// Отмена уже в пути: второй тап «Отменить» получал ошибку при успешной отмене.
    private var cancellingIds: Set<Int> = []

    func cancelPending(_ topup: PendingTopup) async {
        guard !cancellingIds.contains(topup.topupId) else { return }
        cancellingIds.insert(topup.topupId)
        defer { cancellingIds.remove(topup.topupId) }
        error = nil
        do {
            try await API.shared.cancelTopup(id: topup.topupId)
            await load()
        } catch {
            self.error = error.localizedDescription
            // Заявку уже подтвердил администратор (или отменили с сайта), либо
            // связь оборвалась после отмены: перечитываем, иначе в «Ожидают»
            // висела заявка с кнопкой, дающей ту же ошибку, и старый баланс.
            await load()
        }
    }
}

struct WalletView: View {
    @StateObject private var vm = WalletViewModel()
    @State private var showTopup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let d = vm.data {
                        if let e = vm.refreshError {
                            Text("Не обновилось: \(e). Ниже — прежние данные.")
                                .font(.footnote).foregroundColor(Brand.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if d.ordersBlocked == true { blockedBanner } else if d.low == true { lowBalanceBanner }
                        balanceCard(d)
                        if let msg = vm.successMessage {
                            HStack(spacing: 8) {
                                if vm.awaitingTopupId != nil { ProgressView().scaleEffect(0.8) }
                                Text(msg)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(vm.awaitingTopupId != nil ? Brand.muted : Brand.green)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let err = vm.error {
                            Text(err).font(.footnote).foregroundColor(Brand.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        pendingCard(d)
                        historyCard(d)
                    }
                }
                .padding(16)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Кошелёк")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { ShopSwitcherMenu() } }
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.data == nil,
                       emptyIcon: "rublesign.circle", emptyTitle: "Нет данных",
                       retry: { Task { await vm.load() } })
            .sheet(isPresented: $showTopup, onDismiss: {
                vm.topupSheetOpen = false
                vm.presentPending()
            }) {
                TopupSheet(vm: vm)
            }
            .sheet(item: $vm.payLink, onDismiss: { Task { await vm.checkNow() } }) { link in
                SafariView(url: link.url).ignoresSafeArea()
            }
            .sheet(isPresented: Binding(
                get: { vm.requisites != nil },
                set: { if !$0 { vm.requisites = nil } }
            )) {
                if let r = vm.requisites { RequisitesSheet(requisites: r) }
            }
            .task { await vm.load() }
            // Вернулись из банковского приложения (СБП) или просто из фона —
            // баланс и статус пополнения проверяем сразу: раньше оставались
            // старые цифры, а «Ожидаем оплату» висело до следующего тика опроса
            // или вовсе до «потянуть вниз», если опрос уже кончился.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await vm.checkNow() }
            }
        }
    }

    private var lowBalanceBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Низкий баланс").font(.subheadline.weight(.bold)).foregroundColor(.white)
                Text("Комиссия списывается с кошелька. При уходе в минус приём заказов остановится — пополните заранее.")
                    .font(.caption).foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.red)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Приём заказов уже остановлен. Текст выше обещает это заранее — здесь
    /// говорим прямо, что оно случилось, и что именно продолжает работать.
    private var blockedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Приём заказов остановлен").font(.subheadline.weight(.bold)).foregroundColor(.white)
                Text("Кошелёк ушёл в минус. Заказы с сайта и приложений не приходят; касса и киоск работают. Пополните кошелёк — приём включится сразу.")
                    .font(.caption).foregroundColor(.white.opacity(0.9))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.red)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func balanceCard(_ d: WalletData) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Баланс").font(.caption).foregroundColor(Brand.muted)
                Text(Money.rub(d.balance))
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(d.low == true ? Brand.red : Brand.green)
                if let plan = d.plan {
                    HStack {
                        Text("Тариф «\(plan.name ?? "—")»")
                        Spacer()
                        Text(Money.rub(plan.priceMonthly) + "/мес")
                    }
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                }
                // Пополнение кошелька — отдельное право внутри «Финансов».
                if Session.shared.can("finance.topup") {
                    Button {
                        vm.topupSheetOpen = true
                        showTopup = true
                    } label: {
                        Label("Пополнить", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .background(Brand.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func pendingCard(_ d: WalletData) -> some View {
        Group {
            if let pending = d.pending, !pending.isEmpty {
                SectionCard(title: "Ожидают подтверждения") {
                    ForEach(pending) { topup in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Money.rub(topup.amount))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(Brand.text)
                                Text(WalletLabels.method(topup.method) + " · " + DateFmt.short(topup.createdAt))
                                    .font(.caption)
                                    .foregroundColor(Brand.muted)
                            }
                            Spacer()
                            // Сервер отменяет только банковский перевод; онлайн-заявка
                            // (карта/СБП) закрывается сама, кнопка давала бы ошибку 422.
                            if (topup.method ?? "") == "bank_transfer" {
                                Button("Отменить") {
                                    Task { await vm.cancelPending(topup) }
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Brand.red)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private func historyCard(_ d: WalletData) -> some View {
        SectionCard(title: "История операций") {
            let tx = d.transactions ?? []
            if tx.isEmpty {
                Text("Операций пока нет").font(.subheadline).foregroundColor(Brand.muted)
            } else {
                ForEach(tx) { t in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.txTitle(t.type))
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text)
                            if let desc = t.description, !desc.isEmpty {
                                Text(desc).font(.caption).foregroundColor(Brand.muted)
                            }
                            Text(DateFmt.short(t.createdAt)).font(.caption2).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.signed(t.amount))
                                .font(.subheadline.weight(.bold))
                                .foregroundColor((t.amount ?? 0) >= 0 ? Brand.green : Brand.text)
                            Text("= " + Money.rub(t.balanceAfter))
                                .font(.caption2)
                                .foregroundColor(Brand.muted)
                        }
                    }
                    .padding(.vertical, 4)
                    if t.id != tx.last?.id { Divider().overlay(Brand.border) }
                }
            }
        }
    }

    /// Заголовок операции. Сервер пишет ещё «refund_commission» (возврат
    /// комиссии при отмене/возврате заказа) и «correction» (возврат пополнения
    /// через ЮKassa) — в WalletLabels их нет, и в истории стоял голый код.
    /// Незнакомый код — нейтральное «Операция», не код.
    private static func txTitle(_ type: String?) -> String {
        switch type {
        case "refund_commission": return "Возврат комиссии"
        case "correction": return "Корректировка"
        default:
            let label = WalletLabels.type(type)
            return label == type ? "Операция" : label
        }
    }
}

// ── Пополнение ───────────────────────────────────────────────────────────────
struct TopupSheet: View {
    @ObservedObject var vm: WalletViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var amountText = "1000"
    @State private var method = "card_online"
    @State private var isSubmitting = false
    @State private var localError: String?

    private let presets: [Decimal] = [500, 1000, 3000, 5000]

    /// П-27.10: пределы пополнения — из ответа кошелька (min_topup/max_topup,
    /// настройка площадки). Старый сервер их не шлёт — 100 ₽ и без верхней границы.
    private var minTopup: Decimal { vm.data?.minTopupValue ?? 100 }
    private var maxTopup: Decimal? { vm.data?.maxTopupValue }
    private var amountHeader: String {
        if let mx = maxTopup { return "Сумма (от \(Money.rub(minTopup)) до \(Money.rub(mx)))" }
        return "Сумма (минимум \(Money.rub(minTopup)))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(amountHeader) {
                    TextField("Сумма, ₽", text: $amountText)
                        .keyboardType(.numberPad)
                    HStack(spacing: 8) {
                        ForEach(presets, id: \.self) { p in
                            Button(Money.rub(p)) { amountText = "\(p)" }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                        }
                    }
                }
                Section("Способ") {
                    Picker("Способ", selection: $method) {
                        Text("Картой онлайн").tag("card_online")
                        Text("СБП").tag("sbp")
                        Text("Банковский перевод").tag("bank_transfer")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if method == "bank_transfer" {
                        Text("Получите реквизиты и оплатите со счёта организации. Зачисление после подтверждения администратором.")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                }
                if let err = localError {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer(); if isSubmitting { ProgressView() } else { Text("Пополнить").bold() }; Spacer() }
                    }
                    .disabled(isSubmitting)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Пополнение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
        }
    }

    @MainActor private func submit() async {
        // Двойной тап создавал два пополнения (две ссылки ЮKassa или два счёта).
        guard !isSubmitting else { return }
        // «100 000» с пробелом раньше читалось как 100 — платёж на 100 ₽.
        // П-27.10: минимум и максимум — с сервера (без них — 100 ₽, верха нет).
        let minA = minTopup
        guard let amount = Money.strict(amountText.trimmingCharacters(in: .whitespaces)), amount >= minA else {
            localError = "Сумма — число не меньше \(NSDecimalNumber(decimal: minA).stringValue)"
                + (minA < 1500 ? ", например 1500" : "")
            return
        }
        if let mx = maxTopup, amount > mx {
            localError = "Сумма — не больше \(Money.rub(mx)) за одно пополнение"
            return
        }
        isSubmitting = true
        localError = nil
        let ok = await vm.topup(amount: amount, method: method)
        isSubmitting = false
        if ok { dismiss() } else { localError = vm.error }
    }
}

// ── Реквизиты банковского перевода ───────────────────────────────────────────
struct RequisitesSheet: View {
    let requisites: TopupRequisites
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Реквизиты для оплаты") {
                    copyRow("ИНН", requisites.inn)
                    copyRow("Расчётный счёт", requisites.account)
                    copyRow("БИК", requisites.bik)
                    copyRow("Назначение платежа", requisites.purpose)
                }
                Section {
                    Text("После поступления средств администратор подтвердит пополнение — заявка видна в «Ожидают подтверждения».")
                        .font(.caption).foregroundColor(Brand.muted)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Банковский перевод")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
    }

    private func copyRow(_ label: String, _ value: String?) -> some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundColor(Brand.muted)
                    Text(value ?? "—").font(.subheadline.weight(.medium)).foregroundColor(Brand.text)
                }
                Spacer()
                Image(systemName: "doc.on.doc").foregroundColor(Brand.muted)
            }
        }
    }
}
