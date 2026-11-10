import SwiftUI

// ============================================================================
//  «План закупок» (routes/seller_replenishment.php, волна В5 сайта).
//
//  Сервер сам считает, сколько и у кого заказать на выбранный горизонт. Экран:
//  горизонт -> (если идёт пересчёт — полоса прогресса и опрос раз в 2,5 с) ->
//  строки по поставщикам -> правка количества -> «Создать заказы поставщикам».
//
//  Создание заказов — деньги и документы: ключ повтора (Idempotency-Key) пишется
//  в память телефона ДО отправки и живёт, пока сервер не ответил ясно. Обрыв,
//  таймаут, 5xx, закрытие приложения -> «Повторить отправку» уходит с ТЕМ ЖЕ
//  ключом и тем же телом, поэтому заказы не задваиваются.
//  Исключение строки («не заказывать сейчас») действует только на эту отправку
//  (поле exclude) и не меняет настройки позиции на сервере.
// ============================================================================

@MainActor
final class ReplenishmentViewModel: ObservableObject {
    @Published var horizon = "14"
    @Published var plan: ReplPlan?
    @Published var state: LoadState = .idle
    @Published var status: ReplStatus?
    @Published var showAll = false
    @Published var excluded: Set<String> = []
    @Published var sending = false
    @Published var recalcBusy = false
    @Published var result: ReplOrdersResult?
    @Published var sendError: String?
    @Published var pending: ReplPendingOrders?
    @Published var error: String?
    @Published var offlineNote = false
    /// Опрос остановлен через 10 минут: экран пишет «идёт дольше обычного» и даёт «Проверить ещё раз».
    @Published var gaveUp = false
    private var pollTask: Task<Void, Never>?
    private var pollGen = 0
    private var failStreak = 0
    private var loadGen = 0

    private var shopId: Int? { Session.shared.activeShopId }
    private var userId: Int? { Session.shared.user?.id }

    func start() async {
        pending = ReplPendingStore.load(shopId: shopId, userId: userId)
        await loadPlan()
    }

    func loadPlan() async {
        loadGen += 1
        let my = loadGen
        if plan == nil { state = .loading }
        do {
            let p = try await API.shared.replPlan(horizon: horizon)
            guard my == loadGen else { return }
            plan = p
            status = p.status
            state = .loaded
            if ReplLogic.isTerminal(p.status) {
                stopPolling()
            } else {
                // Экран уже закрыт (задача отменена) — опрос заново не запускаем.
                guard !Task.isCancelled else { return }
                startPolling()
            }
        } catch is CancellationError {
        } catch {
            guard my == loadGen else { return }
            let text = SellerNewErrors.text(error)
            if plan == nil { state = .failed(text) } else { self.error = text }
        }
    }

    func changeHorizon(_ value: String) async {
        guard value != horizon else { return }
        horizon = value
        excluded = []
        stopPolling()
        plan = nil
        await loadPlan()
    }

    // ── Опрос пересчёта ─────────────────────────────────────────────────────
    func startPolling() {
        guard pollTask == nil else { return }
        pollGen += 1
        let my = pollGen
        gaveUp = false
        let began = Date()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Раз в 2,5 с; после сбоев сети — реже (до 10 с).
                let delay = ReplLogic.pollNanos * UInt64(min(4, 1 + self.failStreak))
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                let finished = await self.pollOnce()
                if finished {
                    if self.pollGen == my { self.pollTask = nil }
                    await self.loadPlan()
                    return
                }
                if Date().timeIntervalSince(began) >= ReplLogic.pollGiveUpSeconds {
                    if self.pollGen == my { self.pollTask = nil; self.gaveUp = true }
                    return
                }
            }
        }
    }

    /// «Проверить ещё раз» после остановки опроса: заново читаем план; если пересчёт идёт — опрос стартует снова.
    func checkAgain() async {
        gaveUp = false
        failStreak = 0
        stopPolling()
        await loadPlan()
    }

    /// Пояснение «Почему столько» для строки, у которой его нет в плане. Ошибка — пусто (молча).
    func explain(for line: ReplLine) async -> [String] {
        guard let id = line.itemId else { return [] }
        do {
            let r = try await API.shared.replExplain(kind: line.kind ?? "goods", itemId: id, horizon: horizon)
            return r.explain?.text ?? []
        } catch {
            return []
        }
    }

    /// «Отменить отправку»: забыть ключ и тело незавершённой отправки. Если заказы уже успели
    /// создаться, они остаются в разделе «Закупки».
    func cancelPending() {
        ReplPendingStore.clear(shopId: shopId, userId: userId)
        pending = nil
        sendError = nil
    }

    func stopPolling() {
        pollGen += 1
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() async -> Bool {
        do {
            let s = try await API.shared.replStatus(retries: 0)
            failStreak = 0
            offlineNote = false
            status = s
            return ReplLogic.isTerminal(s)
        } catch is CancellationError {
            return false
        } catch {
            failStreak += 1
            offlineNote = true
            return false
        }
    }

    func recalc() async {
        guard !recalcBusy else { return }
        recalcBusy = true
        defer { recalcBusy = false }
        do {
            let s = try await API.shared.replRecalc()
            status = s
            failStreak = 0
            gaveUp = false
            stopPolling()
            if ReplLogic.isTerminal(s) { await loadPlan() } else { startPolling() }
        } catch is CancellationError {
        } catch {
            self.error = SellerNewErrors.text(error)
        }
    }

    // ── Правка количества ───────────────────────────────────────────────────
    /// Пустой текст — сбросить к расчётному. Возвращает текст ошибки или nil.
    func saveQty(_ line: ReplLine, text: String) async -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        var qty = ""
        if !t.isEmpty {
            guard let d = ReceiptMath.parse(t, maxFraction: 3), d <= 999_999.999 else {
                return "Количество — число от 0 до 999 999,999"
            }
            qty = OcrLogic.plain(d)
        }
        guard let id = line.itemId else { return "Позиция не найдена" }
        do {
            try await API.shared.replSetQty(kind: line.kind ?? "goods", itemId: id, qty: qty)
        } catch is CancellationError {
            return nil
        } catch {
            return SellerNewErrors.text(error)
        }
        await loadPlan()
        return nil
    }

    func toggle(_ line: ReplLine) {
        if excluded.contains(line.key) { excluded.remove(line.key) } else { excluded.insert(line.key) }
    }

    // ── Создать заказы ──────────────────────────────────────────────────────
    /// Новая отправка либо повтор прежней (если она не завершилась): ключ и тело берутся
    /// из памяти телефона, а новый ключ рождается только когда прежних незавершённых нет.
    func createOrders() async {
        guard !sending else { return }
        let shop = shopId
        let user = userId
        let p: ReplPendingOrders
        if let saved = pending ?? ReplPendingStore.load(shopId: shop, userId: user) {
            p = saved
        } else {
            p = ReplPendingOrders(key: UUID().uuidString, horizon: horizon, exclude: excluded.sorted())
            ReplPendingStore.save(p, shopId: shop, userId: user)   // ДО отправки
        }
        pending = p
        await send(p, shop: shop, user: user)
    }

    private func send(_ p: ReplPendingOrders, shop: Int?, user: Int?) async {
        sending = true
        sendError = nil
        result = nil
        defer { sending = false }
        var body: [String: Any?] = ["horizon": p.horizon, "kind": "all"]
        if !p.exclude.isEmpty { body["exclude"] = p.exclude }
        do {
            let r = try await API.shared.replCreateOrders(body: body, key: p.key)
            ReplPendingStore.clear(shopId: shop, userId: user)
            pending = nil
            result = r
            excluded = []
            await loadPlan()
        } catch is CancellationError {
            // Исход неизвестен — ключ остаётся.
        } catch {
            let forget = ReplLogic.shouldForgetKey(error)
            var text = SellerNewErrors.text(error)
            if forget {
                ReplPendingStore.clear(shopId: shop, userId: user)
                pending = nil
                if SellerNewErrors.code(error) == "idempotency_unknown_outcome" {
                    text += "\nПроверьте раздел «Закупки»: заказы могли создаться."
                    await loadPlan()
                }
            } else {
                text += "\nНажмите «Повторить отправку»: заказы не задвоятся."
            }
            sendError = text
        }
    }
}

struct ReplenishmentView: View {
    @StateObject private var vm = ReplenishmentViewModel()
    @State private var editLine: ReplLine?
    @State private var confirmCreate = false
    @State private var confirmCancelSend = false

    var body: some View {
        List {
            horizonSection
            progressSection
            if let r = vm.result { resultSection(r) }
            pendingSection
            if let plan = vm.plan, vm.state != .loading {
                summarySection(plan)
                let blocks = ReplLogic.blocks(plan, onlyOrder: !vm.showAll)
                if blocks.isEmpty && ReplLogic.isTerminal(vm.status) {
                    Section {
                        Text((vm.status?.hasData ?? true) ? ReplLogic.emptyText : ReplLogic.noDataText)
                            .font(.footnote).foregroundColor(Brand.muted)
                    }
                    .listRowBackground(Brand.card)
                }
                ForEach(blocks) { block in
                    blockSection(block)
                }
                createSection(plan)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("План закупок")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await vm.recalc() } } label: {
                    if vm.recalcBusy { ProgressView() } else { Text("Пересчитать") }
                }
                .disabled(vm.recalcBusy || vm.sending)
            }
        }
        .refreshable { await vm.loadPlan() }
        .listState(vm.state, isEmpty: vm.plan == nil,
                   emptyIcon: "cart.badge.plus", emptyTitle: "План пока пуст", emptySubtitle: nil,
                   retry: { Task { await vm.loadPlan() } })
        .task { await vm.start() }
        .onDisappear { vm.stopPolling() }
        .sheet(item: $editLine) { line in
            ReplLineEditSheet(line: line,
                              onSave: { text in await vm.saveQty(line, text: text) },
                              loadExplain: { await vm.explain(for: line) })
        }
        .confirmationDialog("Создать заказы поставщикам?", isPresented: $confirmCreate, titleVisibility: .visible) {
            Button("Создать") { Task { await vm.createOrders() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Заказы появятся черновиками в разделе «Закупки». Поставщикам они не отправляются.")
        }
        .errorAlert($vm.error)
    }

    // ── Секции ──────────────────────────────────────────────────────────────

    private var horizonSection: some View {
        Section {
            Picker("На сколько считаем", selection: Binding(get: { vm.horizon },
                                                             set: { v in Task { await vm.changeHorizon(v) } })) {
                ForEach(ReplLogic.horizons, id: \.value) { h in Text(h.title).tag(h.value) }
            }
            .pickerStyle(.menu)
            .disabled(vm.sending)
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private var progressSection: some View {
        if let s = vm.status, !ReplLogic.isTerminal(s) {
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Считаем план закупок…").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                }
                ProgressView(value: Double(min(100, max(0, s.progress ?? 0))), total: 100)
                if let t = s.stageLabel, !t.isEmpty {
                    Text(t).font(.caption).foregroundColor(Brand.muted)
                }
                if vm.offlineNote {
                    Text("Нет связи — проверим позже").font(.caption).foregroundColor(Brand.amber)
                }
                if vm.gaveUp {
                    Text(ReplLogic.slowText).font(.footnote).foregroundColor(Brand.text)
                    Button(ReplLogic.checkAgain) { Task { await vm.checkAgain() } }
                        .buttonStyle(.borderless)
                }
            }
            .listRowBackground(Brand.card)
        } else if let s = vm.status, (s.status ?? "") == "failed" {
            Section {
                Text("Пересчёт не удался").font(.subheadline.weight(.semibold)).foregroundColor(Brand.red)
                if let e = s.error, !e.isEmpty { Text(e).font(.footnote).foregroundColor(Brand.muted) }
                Text("Нажмите «Пересчитать» ещё раз.").font(.caption).foregroundColor(Brand.muted)
            }
            .listRowBackground(Brand.card)
        } else if let s = vm.status, let t = s.lastComputedAt, !t.isEmpty {
            Section {
                Text("Рассчитано: \(DateFmt.short(t))").font(.caption).foregroundColor(Brand.muted)
            }
            .listRowBackground(Brand.card)
        }
    }

    @ViewBuilder
    private func resultSection(_ r: ReplOrdersResult) -> some View {
        Section {
            ForEach(ReplLogic.resultLines(r), id: \.self) { line in
                Text(line).font(.subheadline)
                    .foregroundColor(line.hasPrefix("Не удалось") ? Brand.red : Brand.text)
            }
            if ReplLogic.hasOrders(r) {
                NavigationLink { PurchaseOrdersView() } label: {
                    Label("Открыть заказы поставщикам", systemImage: "cart")
                }
            }
        } header: {
            Text("Итог")
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private var pendingSection: some View {
        if let e = vm.sendError {
            Section {
                Text(e).font(.footnote).foregroundColor(Brand.red)
            }
            .listRowBackground(Brand.card)
        }
        if let p = vm.pending {
            Section {
                Text("Прошлая отправка заказов (\(ReplLogic.horizonTitle(p.horizon))) не завершилась. Повторите её — заказы не задвоятся.")
                    .font(.footnote).foregroundColor(Brand.text)
                Button { Task { await vm.createOrders() } } label: {
                    HStack {
                        Text("Повторить отправку").fontWeight(.semibold)
                        Spacer()
                        if vm.sending { ProgressView() }
                    }
                }
                .disabled(vm.sending || !Session.shared.can("suppliers"))
                Button(ReplLogic.cancelSend, role: .destructive) { confirmCancelSend = true }
                    .disabled(vm.sending)
                    .confirmationDialog(ReplLogic.cancelSendTitle, isPresented: $confirmCancelSend, titleVisibility: .visible) {
                        Button(ReplLogic.cancelSend, role: .destructive) { vm.cancelPending() }
                        Button(ReplLogic.cancelSendKeep, role: .cancel) {}
                    } message: {
                        Text(ReplLogic.cancelSendNote)
                    }
            }
            .listRowBackground(Brand.amber.opacity(0.14))
        }
    }

    @ViewBuilder
    private func summarySection(_ plan: ReplPlan) -> some View {
        Section {
            if let s = plan.summary {
                InfoRow(label: "К заказу", value: "\(s.orderLines ?? 0) поз. на \(Money.rub(s.orderAmount))")
                InfoRow(label: "Поставщиков", value: "\(s.orderSuppliers ?? 0)")
                if (s.riskCount ?? 0) > 0 {
                    InfoRow(label: "Риск дефицита", value: "\(s.riskCount ?? 0)")
                }
                if (s.noSupplier ?? 0) > 0 {
                    InfoRow(label: "Без поставщика", value: "\(s.noSupplier ?? 0)")
                }
                if let b = s.budget, b.over ?? false {
                    Text("Бюджет превышен: часть строк урезана (\(b.cutLines ?? 0)). Было бы \(Money.rub(b.totalBefore)).")
                        .font(.footnote).foregroundColor(Brand.amber)
                }
            }
            if let b = plan.params?.budget, b > 0 {
                InfoRow(label: "Бюджет закупок", value: Money.rub(b))
            }
            if (plan.staleLines ?? 0) > 0 {
                Text("Для \(plan.staleLines ?? 0) строк данные устарели — нажмите «Пересчитать».")
                    .font(.caption).foregroundColor(Brand.amber)
            }
            if ReplLogic.isPartial(plan) {
                Text(ReplLogic.partialText(shown: plan.lines.count, total: plan.total ?? 0))
                    .font(.caption).foregroundColor(Brand.amber)
            }
            Toggle("Показать все позиции", isOn: $vm.showAll)
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private func blockSection(_ block: ReplBlock) -> some View {
        Section {
            ForEach(block.lines) { line in lineRow(line) }
            if let g = block.group {
                if !(g.minReached ?? true), let need = g.toMin, need > 0 {
                    Text("До минимальной суммы заказа не хватает \(Money.rub(need))")
                        .font(.caption).foregroundColor(Brand.amber)
                }
                if let d = g.deliveryDate, !d.isEmpty {
                    Text("Поставка: \(DateFmt.day(d))" + ((g.orderBy ?? "").isEmpty ? "" : " · заказать до \(DateFmt.day(g.orderBy))"))
                        .font(.caption).foregroundColor(Brand.muted)
                }
            }
        } header: {
            HStack {
                Text(block.name)
                Spacer()
                if block.group != nil { Text(Money.rub(ReplLogic.blockAmount(block, excluded: vm.excluded))) }
            }
        }
        .listRowBackground(Brand.card)
    }

    private func lineRow(_ line: ReplLine) -> some View {
        let isOut = vm.excluded.contains(line.key)
        let canInclude = line.selected ?? false
        let unit = line.unit ?? ""
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                if canInclude {
                    Button { vm.toggle(line) } label: {
                        Image(systemName: isOut ? "circle" : "checkmark.circle.fill")
                            .foregroundColor(isOut ? Brand.muted : Brand.accent)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isOut ? "Вернуть в заказ" : "Не заказывать сейчас")
                }
                Text((line.name ?? "").isEmpty ? "Без названия" : (line.name ?? ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(isOut ? Brand.muted : Brand.text)
                Spacer(minLength: 6)
                statusBadge(line.status)
            }
            Text("Остаток: \(QtyFmt.qty(line.stock)) \(unit) · расход в день: \(QtyFmt.qty(line.avgDaily)) · хватит на \(ReplLogic.coverText(line.daysCover))")
                .font(.caption).foregroundColor(Brand.muted)
            if (line.inTransit ?? 0) > 0 {
                Text("В пути: \(QtyFmt.qty(line.inTransit)) \(unit)").font(.caption2).foregroundColor(Brand.muted)
            }
            HStack {
                if line.priceKnown ?? false {
                    Text("Заказать: \(QtyFmt.qty(line.qty)) \(unit) × \(Money.rub(line.price)) = \(Money.rub(line.amount))")
                } else {
                    Text("Заказать: \(QtyFmt.qty(line.qty)) \(unit) · цена неизвестна")
                }
                Spacer(minLength: 4)
                if (line.qtyRecommended ?? 0) != (line.qty ?? 0) {
                    Text("рекомендовано \(QtyFmt.qty(line.qtyRecommended))").foregroundColor(Brand.muted)
                }
            }
            .font(.caption.weight(.medium)).foregroundColor(Brand.text)
            if line.flags?.edited ?? false {
                Text("Изменено вручную").font(.caption2).foregroundColor(Brand.accent)
            }
            if line.flags?.cutByBudget ?? false {
                Text("Урезано по бюджету").font(.caption2).foregroundColor(Brand.amber)
            }
            if !canInclude && ReplLogic.needsOrder(line) {
                Text("Не попадёт в заказ: нет поставщика или цены, либо количество 0")
                    .font(.caption2).foregroundColor(Brand.amber)
            }
            Button("Изменить количество") { editLine = line }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(vm.sending)
        }
        .padding(.vertical, 2)
    }

    private func statusBadge(_ status: String?) -> some View {
        switch status ?? "" {
        case "risk": return StatusBadge(text: "Риск", color: Brand.red)
        case "order": return StatusBadge(text: "К заказу", color: Brand.accent)
        case "ok": return StatusBadge(text: "Хватает", color: Brand.green)
        case "excess": return StatusBadge(text: "Излишек", color: Brand.amber)
        case "dead": return StatusBadge(text: "Не продаётся", color: Brand.muted)
        default: return StatusBadge(text: "Нет данных", color: Brand.muted)
        }
    }

    @ViewBuilder
    private func createSection(_ plan: ReplPlan) -> some View {
        let tot = ReplLogic.orderTotals(plan, excluded: vm.excluded)
        Section {
            Button { confirmCreate = true } label: {
                HStack {
                    Spacer()
                    if vm.sending { ProgressView() }
                    Text(vm.sending ? ReplLogic.creating : "Создать заказы поставщикам").font(.headline)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent).tint(Brand.accent)
            .disabled(vm.sending || vm.pending != nil || tot.count <= 0 || !Session.shared.can("suppliers"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !Session.shared.can("suppliers") {
                    Text(ReplLogic.needSuppliersRight)
                }
                if tot.count <= 0 {
                    Text("Нет строк для заказа.")
                } else {
                    Text("В заказы попадёт строк: \(tot.count) на \(Money.rub(tot.amount)). Снимите галочку у строки, чтобы не заказывать её сейчас.")
                }
            }
        }
        .listRowBackground(Color.clear)
    }
}

// ── Правка количества ────────────────────────────────────────────────────────

private struct ReplLineEditSheet: View {
    let line: ReplLine
    let onSave: (String) async -> String?
    let loadExplain: () async -> [String]
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var extraExplain: [String] = []
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(line.name ?? "").font(.subheadline.weight(.semibold))
                    InfoRow(label: "Рекомендовано", value: "\(QtyFmt.qty(line.qtyRecommended)) \(line.unit ?? "")")
                    TextField("Количество к заказу", text: $text).keyboardType(.decimalPad)
                } footer: {
                    Text("Пустое поле — вернуть расчётное количество.")
                }
                if !explainLines.isEmpty {
                    Section("Почему столько") {
                        ForEach(Array(explainLines.enumerated()), id: \.offset) { _, t in
                            Text(t).font(.footnote).foregroundColor(Brand.text)
                        }
                    }
                }
                if let e = error {
                    Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Количество")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            saving = true
                            let e = await onSave(text)
                            saving = false
                            if let e { error = e } else { dismiss() }
                        }
                    } label: {
                        if saving { ProgressView() } else { Text("Сохранить") }
                    }
                    .disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear { text = (line.qty ?? 0) > 0 ? OcrLogic.input(line.qty ?? 0) : "" }
            .task {
                // У строки нет explain (в плане больше 50 строк) — спрашиваем отдельно; ошибка молча.
                if (line.explain?.text ?? []).isEmpty { extraExplain = await loadExplain() }
            }
        }
    }

    private var explainLines: [String] {
        let own = line.explain?.text ?? []
        return own.isEmpty ? extraExplain : own
    }
}
