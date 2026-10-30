import SwiftUI

// ============================================================================
//  Закупки (заказы поставщику) — routes/seller_purchase.php:
//   • список  GET  /api/seller/purchase-orders?status=&supplier_id=
//   • деталь  GET  /api/seller/purchase-orders/{id}
//   • создать POST /api/seller/purchase-orders {supplier_id?, warehouse_id?,
//     comment?, items:[{kind,id,name,unit,article,qty,price}]}
//   • править PUT  …/{id} (только черновик), удалить DELETE …/{id} (черновик)
//   • send / cancel POST …/{id}/send | /cancel
//   • приёмка POST …/{id}/receive {warehouse_id?, items:[{poi_id,qty,price?,
//     expires_at?}]} — сервер создаёт и проводит приход, возвращает
//     {income_document_id, fully_received}; без items принимает весь остаток.
// ============================================================================

@MainActor
final class PurchaseOrdersViewModel: ObservableObject {
    @Published var orders: [PurchaseOrderSummary] = []
    @Published var state: LoadState = .idle
    @Published var status = ""            // "" | draft | sent | received | cancelled

    func load() async {
        if orders.isEmpty { state = .loading }
        // Ответ по прежнему чипу не применяем: «Черновики» → «Отправлены», и
        // медленный ответ по черновикам показывался под «Отправлены».
        let asked = status
        do {
            let list = try await API.shared.purchaseOrders(status: asked.isEmpty ? nil : asked, supplierId: nil)
            guard asked == status else { return }
            orders = list
            state = .loaded
        } catch is CancellationError {
        } catch {
            // Ошибка по прежнему чипу не должна ложиться на новый.
            guard asked == status else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

struct PurchaseOrdersView: View {
    @StateObject private var vm = PurchaseOrdersViewModel()
    @State private var showCreate = false

    private let statuses: [(String, String)] = [
        ("", "Все"), ("draft", "Черновики"), ("sent", "Отправлены"),
        ("received", "Приняты"), ("cancelled", "Отменены"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(statuses, id: \.0) { code, title in
                        FilterChip(title: title, selected: vm.status == code) {
                            // Смена чипа убирает строки прежнего: если новый запрос
                            // не пройдёт, под «Отменены» не должны висеть черновики.
                            if vm.status != code { vm.orders = [] }
                            vm.status = code
                            Task { await vm.load() }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            List {
                ForEach(vm.orders) { po in
                    NavigationLink {
                        PurchaseOrderDetailView(poId: po.id, listVM: vm)
                    } label: {
                        row(po)
                    }
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Закупки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.orders.isEmpty,
                   emptyIcon: "cart", emptyTitle: "Заказов поставщикам нет",
                   emptySubtitle: "Создайте первый заказ кнопкой «+»",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $showCreate) {
            PurchaseOrderEditSheet(listVM: vm, existing: nil)
        }
        .task { await vm.load() }
    }

    private func row(_ po: PurchaseOrderSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(po.number ?? "ЗАК-\(po.id)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Text(joinedNonEmpty([po.supplier, DateFmt.short(po.createdAt)], separator: " · "))
                    .font(.caption).foregroundColor(Brand.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.rub(po.totalAmount))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                StatusBadge(text: PurchaseLabels.status(po.status), color: statusColor(po.status))
            }
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ s: String?) -> Color {
        switch s {
        case "draft": return Brand.muted
        case "sent": return Brand.amber
        case "received": return Brand.green
        case "cancelled": return Brand.red
        default: return Brand.muted
        }
    }
}

// ── Деталь заказа ────────────────────────────────────────────────────────────
@MainActor
final class PurchaseOrderDetailViewModel: ObservableObject {
    @Published var detail: PurchaseOrderDetail?
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var acting = false
    @Published var receiveResult: String?
    /// А317: 422 qty_over_remaining — строка заказа (poi_id) и текст сервера (с остатком).
    @Published var receiveLineError: (poiId: Int, text: String)?

    func load(id: Int) async {
        if detail == nil { state = .loading }
        do {
            detail = try await API.shared.purchaseOrder(id: id)
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func send(id: Int) async {
        await run { try await API.shared.sendPurchaseOrder(id: id); await self.load(id: id) }
        // Отказ (заказ уже отправили/приняли с другого устройства) — перечитываем,
        // иначе на экране оставались прежний статус и неработающие кнопки.
        if error != nil { await load(id: id) }
    }

    func cancel(id: Int) async {
        await run { try await API.shared.cancelPurchaseOrder(id: id); await self.load(id: id) }
        if error != nil { await load(id: id) }   // то же для отмены
    }

    /// true = заказ удалён (возвращаемся к списку).
    func deleteDraft(id: Int) async -> Bool {
        guard !acting else { return false }   // двойной тап — один запрос
        error = nil
        acting = true
        defer { acting = false }
        do {
            try await API.shared.deletePurchaseOrder(id: id)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Отпечаток приёмки заказа: статус, приход и принятое по строкам.
    private static func receiveMark(_ d: PurchaseOrderDetail?) -> String? {
        guard let d else { return nil }
        let rows = (d.items ?? []).map { "\($0.id):\($0.qtyReceived ?? 0)" }.joined(separator: ",")
        return "\(d.status ?? "")|\(d.incomeDocumentId ?? 0)|\(rows)"
    }

    /// keys — ключи повтора окна приёмки (живут, пока окно открыто).
    func receive(id: Int, warehouseId: Int?, items: [[String: Any]]?, keys: IdempotencyKeys? = nil) async -> Bool {
        // Второй запрос приёмки проводил второй приход — остатки удваивались.
        guard !acting else { return false }
        error = nil
        receiveLineError = nil
        acting = true
        defer { acting = false }
        do {
            let ack = try await API.shared.receivePurchaseOrder(id: id, warehouseId: warehouseId, items: items, keys: keys)
            var text = ack.fullyReceived == true
                ? "Заказ принят полностью — приход №\(ack.incomeDocumentId ?? 0) проведён"
                : "Частичная приёмка — приход №\(ack.incomeDocumentId ?? 0) проведён, остаток ждёт поставки"
            // Строки, чью позицию удалили из справочника, сервер не принимает и
            // считает в broken_items — без этого заказ «не закрывался» молча.
            if let broken = ack.brokenItems, broken > 0 {
                text += ". Не принято строк: \(broken) — их товар или ингредиент удалён из справочника"
            }
            receiveResult = text
            await load(id: id)
            return true
        } catch let e as APIDetailedError where e.status == 422 && e.extras["error_code"] == "qty_over_remaining"
                    && Int(e.extras["poi_id"] ?? "") != nil {
            // А317: больше остатка по строке — текст сервера (с остатком) у этой строки
            // окна приёмки; приёмка не прошла, исход известен.
            // Только у строки — без общего дубля внизу окна.
            receiveLineError = (Int(e.extras["poi_id"] ?? "") ?? 0, e.message)
            return false
        } catch {
            let msg = error.localizedDescription
            self.error = msg
            // А60/П-23.11: 409 — приёмку уже провели (другое устройство, повтор
            // после обрыва): перечитываем заказ, чтобы кнопки и остатки были верны.
            let before = Self.receiveMark(detail)
            await load(id: id)
            // Заказ изменился — исход известен: ключи окна забываем и закрываем окно,
            // чтобы прежние количества не ушли второй раз.
            if let b = before, let a = Self.receiveMark(detail), a != b {
                keys?.forgetAll()
                self.error = msg + ". Заказ изменился — проверьте, что уже принято"
                return true
            }
            return false
        }
    }

    /// А60/П-23.11: заказ принят, а документ прихода остался черновиком —
    /// провести его: POST …/receive {"post_only": true}.
    func postIncome(id: Int) async {
        guard !acting else { return }   // двойной тап — один запрос
        error = nil
        acting = true
        defer { acting = false }
        do {
            _ = try await API.shared.receivePurchaseOrder(id: id, warehouseId: nil, items: nil, postOnly: true)
            receiveResult = "Приход проведён"
        } catch APIError.decoding {
            // Успех без данных в ответе — итог покажет перечитанный заказ.
        } catch {
            self.error = error.localizedDescription
        }
        await load(id: id)   // и при 409 «уже проводится/проведён» — актуальное состояние
    }

    private func run(_ op: @escaping () async throws -> Void) async {
        guard !acting else { return }   // двойной тап «Отправить/Отменить» — один запрос
        error = nil
        acting = true
        defer { acting = false }
        do { try await op() } catch { self.error = error.localizedDescription }
    }
}

struct PurchaseOrderDetailView: View {
    let poId: Int
    @ObservedObject var listVM: PurchaseOrdersViewModel
    @StateObject private var vm = PurchaseOrderDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var showReceive = false
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let d = vm.detail {
                    headerCard(d)
                    if let msg = vm.receiveResult {
                        Text(msg).font(.footnote.weight(.semibold)).foregroundColor(Brand.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let err = vm.error {
                        Text(err).font(.footnote).foregroundColor(Brand.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    itemsCard(d)
                    actions(d)
                }
            }
            .padding(16)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(vm.detail?.number ?? "Заказ")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load(id: poId) }
        .listState(vm.state, isEmpty: vm.detail == nil,
                   emptyIcon: "cart", emptyTitle: "Нет данных",
                   retry: { Task { await vm.load(id: poId) } })
        .sheet(isPresented: $showEdit) {
            PurchaseOrderEditSheet(listVM: listVM, existing: vm.detail) {
                Task { await vm.load(id: poId) }
            }
        }
        .sheet(isPresented: $showReceive) {
            if let d = vm.detail {
                ReceiveSheet(vm: vm, detail: d) { Task { await listVM.load() } }
            }
        }
        .confirmationDialog("Отменить заказ поставщику?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Отменить заказ", role: .destructive) {
                Task { await vm.cancel(id: poId); await listVM.load() }
            }
        }
        .confirmationDialog("Удалить черновик?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                Task {
                    if await vm.deleteDraft(id: poId) {
                        await listVM.load()
                        dismiss()
                    }
                }
            }
        }
        .task { await vm.load(id: poId) }
    }

    private func headerCard(_ d: PurchaseOrderDetail) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Статус", value: PurchaseLabels.status(d.status))
                // Паритет с Android: поставщик в карточке заказа. Деталь отдаёт только
                // supplier_id, имя — из строки списка (GET /purchase-orders даёт supplier).
                InfoRow(label: "Поставщик", value: supplierName(d))
                // П-28.12: склад приёмки — названием от сервера (раньше не показывался).
                if let w = d.warehouseName?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty {
                    InfoRow(label: "Склад", value: w)
                }
                InfoRow(label: "Сумма", value: Money.rub(d.totalAmount))
                if let c = d.createdAt { InfoRow(label: "Создан", value: DateFmt.short(c)) }
                if let s = d.sentAt, !s.isEmpty { InfoRow(label: "Отправлен", value: DateFmt.short(s)) }
                if let r = d.receivedAt, !r.isEmpty { InfoRow(label: "Приёмка", value: DateFmt.short(r)) }
                if let doc = d.incomeDocumentId, doc > 0 {
                    InfoRow(label: "Документ прихода", value: "№\(doc)")
                }
                if let c = d.comment, !c.isEmpty { InfoRow(label: "Комментарий", value: c) }
            }
        }
    }

    private func supplierName(_ d: PurchaseOrderDetail) -> String {
        guard let sid = d.supplierId, sid > 0 else { return "Не выбран" }
        // П-28.12: название из самой детали; нет (старый сервер) — из строки списка.
        if let own = d.supplierName?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty { return own }
        let name = listVM.orders.first(where: { $0.id == poId })?.supplier ?? ""
        return name.isEmpty ? "№\(sid)" : name
    }

    private func itemsCard(_ d: PurchaseOrderDetail) -> some View {
        SectionCard(title: "Позиции") {
            let items = d.items ?? []
            if items.isEmpty {
                Text("Позиций нет").font(.caption).foregroundColor(Brand.muted)
            } else {
                ForEach(items) { it in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(it.name ?? "—")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text).lineLimit(2)
                            Spacer()
                            Text(Money.rub(it.amount))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.text)
                        }
                        HStack {
                            Text("\(QtyFmt.qty(it.qtyOrdered)) \(it.unit ?? "") × \(Money.rub(it.price))")
                                .font(.caption).foregroundColor(Brand.muted)
                            Spacer()
                            if (it.qtyReceived ?? 0) > 0 {
                                Text("принято \(QtyFmt.qty(it.qtyReceived))")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(it.remaining > 0 ? Brand.amber : Brand.green)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    if it.id != items.last?.id { Divider().overlay(Brand.border) }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ d: PurchaseOrderDetail) -> some View {
        VStack(spacing: 10) {
            // Отправка заказа и приёмка — отдельные права внутри «Поставщиков»:
            // приёмка увеличивает остатки, это не то же, что составить заявку.
            if d.status == "draft" && Session.shared.can("suppliers.send") {
                actionButton("Отправить поставщику", icon: "paperplane.fill", color: Brand.accent) {
                    Task { await vm.send(id: poId); await listVM.load() }
                }
            }
            // Паритет с Android: правка черновика и отмена заказа не требуют прав
            // «Отправка»/«Приёмка» — сервер (StaffAccess.php) закрывает отдельными
            // правами только /send и /receive. Раньше сотрудник без них не мог
            // ни поправить черновик, ни отменить заказ.
            if d.status == "draft" {
                actionButton("Редактировать черновик", icon: "pencil", color: Brand.chip, textColor: Brand.text) {
                    showEdit = true
                }
            }
            if (d.status == "draft" || d.status == "sent") && Session.shared.can("suppliers.receive") {
                actionButton("Принять поставку", icon: "tray.and.arrow.down.fill", color: Brand.green) {
                    showReceive = true
                }
            }
            if d.status == "draft" || d.status == "sent" {
                actionButton("Отменить заказ", icon: "xmark.circle", color: Brand.chip, textColor: Brand.red) {
                    confirmCancel = true
                }
            }
            // А60/П-23.11: приёмка прошла, а приход не проведён (черновик) —
            // остатки ещё не выросли. Поле income_document_status новое: без него
            // кнопки нет, как раньше.
            if d.status == "received" && d.incomeDocumentStatus == "draft" && Session.shared.can("suppliers.receive") {
                actionButton("Провести приход", icon: "checkmark.seal.fill", color: Brand.green) {
                    Task { await vm.postIncome(id: poId); await listVM.load() }
                }
            }
            if d.status == "draft" {
                actionButton("Удалить черновик", icon: "trash", color: Brand.chip, textColor: Brand.red) {
                    confirmDelete = true
                }
            }
        }
        .disabled(vm.acting)
    }

    private func actionButton(_ title: String, icon: String, color: Color,
                              textColor: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .background(color)
        .foregroundColor(textColor)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// ── Создание / правка черновика ──────────────────────────────────────────────
/// Строка формы заказа (плоская, без DTO).
struct POItemDraft: Identifiable {
    let id = UUID()
    var kind: String
    var positionId: Int
    var name: String
    var unit: String
    var article: String?
    var qtyText: String
    var priceText: String

    // Строгий разбор: «1 000» кг раньше читалось как 1, «1 500» ₽ — как 1 ₽.
    var qty: Decimal { Money.strict(qtyText, maxFraction: 3) ?? 0 }
    var price: Decimal { Money.strict(priceText) ?? 0 }

    var payload: [String: Any] {
        var p: [String: Any] = [
            "kind": kind, "id": positionId, "name": name, "unit": unit,
            "qty": "\(qty)", "price": "\(price)",
        ]
        if let a = article, !a.isEmpty { p["article"] = a }
        return p
    }
}

struct PurchaseOrderEditSheet: View {
    @ObservedObject var listVM: PurchaseOrdersViewModel
    let existing: PurchaseOrderDetail?
    var onSaved: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var suppliers: [Supplier] = []
    @State private var warehouses: [WarehouseInfo] = []
    @State private var supplierId = 0
    @State private var warehouseId = 0
    @State private var comment = ""
    @State private var items: [POItemDraft] = []
    @State private var showAddItem = false
    @State private var isSubmitting = false
    @State private var localError: String?

    private var total: Decimal {
        items.reduce(Decimal(0)) { $0 + $1.qty * $1.price }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Заказ") {
                    Picker("Поставщик", selection: $supplierId) {
                        Text("Не выбран").tag(0)
                        ForEach(suppliers) { s in
                            Text(s.name ?? "—").tag(s.id)
                        }
                    }
                    Picker("Склад приёмки", selection: $warehouseId) {
                        Text("Основной").tag(0)
                        ForEach(warehouses) { w in
                            Text(w.name ?? "Склад").tag(w.warehouseId)
                        }
                    }
                    TextField("Комментарий", text: $comment)
                }
                Section("Позиции · итого \(Money.rub(total))") {
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.name)
                                .font(.subheadline.weight(.medium))
                            HStack {
                                TextField("Кол-во", text: $item.qtyText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                Text(item.unit).font(.caption).foregroundColor(Brand.muted)
                                TextField("Цена", text: $item.priceText)
                                    .keyboardType(.decimalPad)
                                    .textFieldStyle(.roundedBorder)
                                Text("₽").font(.caption).foregroundColor(Brand.muted)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        // Строка ForEach($items) с полем «Кол-во»/«Цена» в фокусе,
                        // удалённая в том же кадре, роняла SwiftUI (Index out of range).
                        // Сначала снимаем фокус, удаляем по id в следующем кадре.
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        let ids = Set(offsets.map { items[$0].id })
                        DispatchQueue.main.async { items.removeAll { ids.contains($0.id) } }
                    }
                    Button {
                        showAddItem = true
                    } label: {
                        Label("Добавить позицию", systemImage: "plus")
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
                    .disabled(isSubmitting || items.isEmpty)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(existing == nil ? "Новый заказ" : "Черновик заказа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
            // Свайп вниз стирал набранные позиции заказа — закрыть можно кнопкой «Отмена».
            .interactiveDismissDisabled(!items.isEmpty || isSubmitting)
            .sheet(isPresented: $showAddItem) {
                POAddItemSheet { picked, qty, price in
                    items.append(POItemDraft(
                        kind: picked.kind ?? "product", positionId: picked.itemId ?? 0,
                        name: picked.name ?? "—", unit: picked.unit ?? "",
                        article: picked.article,
                        qtyText: "\(qty)", priceText: "\(price)"))
                }
            }
            .task { await bootstrap() }
        }
    }

    private func bootstrap() async {
        // Черновик — в форму сразу, справочники — потом. Раньше строки ждали
        // поставщиков и склады: на медленной сети форма стояла пустой, продавец
        // добавлял позицию, строки черновика уже не подставлялись, и «Сохранить»
        // заменяло весь состав заказа одной новой позицией.
        if let d = existing, items.isEmpty {
            supplierId = d.supplierId ?? 0
            warehouseId = d.warehouseId ?? 0
            comment = d.comment ?? ""
            items = (d.items ?? []).map { it in
                POItemDraft(kind: it.kind, positionId: (it.productId ?? 0) != 0 ? (it.productId ?? 0) : (it.ingredientId ?? 0),
                            name: it.name ?? "—", unit: it.unit ?? "", article: it.article,
                            qtyText: "\(it.qtyOrdered ?? 0)", priceText: "\(it.price ?? 0)")
            }
        }
        suppliers = ((try? await API.shared.suppliers()) ?? []).filter { $0.isActive != false }
        warehouses = (try? await API.shared.warehouses()) ?? []
    }

    @MainActor private func submit() async {
        guard !isSubmitting else { return }   // двойной тап создавал два заказа
        isSubmitting = true
        localError = nil
        // Нечитаемое количество раньше молча выкидывало строку из заказа
        // (сервер заменяет весь список), а цена становилась 0 ₽.
        if let bad = items.first(where: {
            Money.strict($0.qtyText, maxFraction: 3) == nil
            || (!$0.priceText.trimmingCharacters(in: .whitespaces).isEmpty && Money.strict($0.priceText) == nil)
        }) {
            localError = "«\(bad.name)»: проверьте количество и цену"
            isSubmitting = false
            return
        }
        let payload = items.filter { $0.qty > 0 }.map { $0.payload }
        guard !payload.isEmpty else {
            localError = "Добавьте позиции с количеством больше нуля"
            isSubmitting = false
            return
        }
        do {
            if let d = existing {
                // Сброс поставщика/склада и стёртый комментарий — явным значением:
                // nil-ключи makeRequest выбрасывает, и сервер оставлял прежние.
                // П-20.1: «не выбран» — 0 (так рекомендует сервер; null он не обещает).
                try await API.shared.updatePurchaseOrder(id: d.poId ?? 0, fields: [
                    "supplier_id": supplierId > 0 ? supplierId : 0,
                    "warehouse_id": warehouseId > 0 ? warehouseId : 0,
                    "comment": comment,
                    "items": payload,
                ])
            } else {
                _ = try await API.shared.createPurchaseOrder(
                    supplierId: supplierId > 0 ? supplierId : nil,
                    warehouseId: warehouseId > 0 ? warehouseId : nil,
                    comment: comment.isEmpty ? nil : comment,
                    items: payload)
            }
            await listVM.load()
            onSaved?()
            isSubmitting = false
            dismiss()
        } catch {
            localError = error.localizedDescription
            isSubmitting = false
        }
    }
}

/// Поиск позиции для строки заказа (GET /api/seller/stock/search).
struct POAddItemSheet: View {
    var onAdd: (StockSearchItem, Decimal, Decimal) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [StockSearchItem] = []
    @State private var selected: StockSearchItem?
    @State private var qtyText = "1"
    @State private var priceText = ""
    @State private var searchTask: Task<Void, Never>?
    /// Поиск не удался (нет сети): раньше список просто оставался пустым.
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            Form {
                if let sel = selected {
                    Section("Позиция") {
                        HStack {
                            Text(sel.name ?? "—").font(.subheadline.weight(.medium))
                            Spacer()
                            // Цена прежней позиции не должна переехать на новую.
                            Button("Сменить") { selected = nil; priceText = "" }.font(.caption)
                                // Кнопка строки Form без стиля срабатывает от касания по всей
                                // строке: тап по названию сбрасывал выбор и введённую цену.
                                .buttonStyle(.borderless)
                        }
                        TextField("Количество *", text: $qtyText).keyboardType(.decimalPad)
                        TextField("Цена закупки, ₽", text: $priceText).keyboardType(.decimalPad)
                    }
                    Section {
                        Button {
                            let qty = Money.strict(qtyText, maxFraction: 3) ?? 0
                            let price = Money.strict(priceText) ?? 0
                            if qty > 0 { onAdd(sel, qty, price); dismiss() }
                        } label: {
                            HStack { Spacer(); Text("Добавить").bold(); Spacer() }
                        }
                        .disabled((Money.strict(qtyText, maxFraction: 3) ?? 0) <= 0
                                  || (!priceText.trimmingCharacters(in: .whitespaces).isEmpty && Money.strict(priceText) == nil))
                    } footer: {
                        // Кнопка гасла молча («1,5,» или 0 в количестве) — пишем причину.
                        if let b = addBlocker { Text(b).foregroundColor(Brand.red) }
                    }
                } else {
                    Section("Поиск") {
                        TextField("Название, артикул или штрихкод", text: $query)
                            .onChange(of: query) { _ in scheduleSearch() }
                        if let err = searchError {
                            Button { scheduleSearch() } label: {
                                Text("Не удалось найти: \(err) · Повторить")
                                    .font(.footnote).foregroundColor(Brand.red)
                            }
                        }
                        ForEach(results) { r in
                            Button {
                                selected = r
                                if let p = r.anyPrice, p > 0, priceText.isEmpty { priceText = "\(p)" }
                            } label: {
                                HStack {
                                    Text(r.name ?? "—").foregroundColor(Brand.text)
                                    Spacer()
                                    Text(r.kind == "ingredient" ? "ингредиент" : "товар")
                                        .font(.caption).foregroundColor(Brand.muted)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Позиция заказа")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
        }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query
        // Запрос стал короче 2 символов — старая ошибка поиска больше не про него.
        if q.count < 2 { searchError = nil }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, q.count >= 2 else { return }
            var found: [StockSearchItem] = []
            var failure: String?
            do {
                found = try await API.shared.stockSearch(q: q)
            } catch is CancellationError {
                return
            } catch {
                failure = error.localizedDescription
            }
            guard !Task.isCancelled else { return }
            // Замыкание MainActor.run — @Sendable: захват локальных var не компилируется в Xcode 15/16.
            let f = found, e = failure
            await MainActor.run { results = f; searchError = e }
        }
    }

    /// Почему «Добавить» недоступна — то же условие, что у .disabled кнопки.
    private var addBlocker: String? {
        if (Money.strict(qtyText, maxFraction: 3) ?? 0) <= 0 {
            return "Укажите количество больше нуля, например 2 или 0,5"
        }
        let p = priceText.trimmingCharacters(in: .whitespaces)
        if !p.isEmpty && Money.strict(priceText) == nil {
            return "Цена — число, например 150 или 149,90"
        }
        return nil
    }
}

// ── Приёмка: фактические количества по строкам ───────────────────────────────
/// Строка приёмки — poi_id + факт + цена + срок годности (тело сверено с PHP).
private struct ReceiveLine: Identifiable {
    let id: Int                 // poi_id
    let name: String
    let unit: String
    let remaining: Decimal
    var qtyText: String
    var priceText: String
    var expiresAt: Date?
    var include: Bool

    var qty: Decimal { Money.strict(qtyText, maxFraction: 3) ?? 0 }
    var price: Decimal? { Money.strict(priceText) }
}

struct ReceiveSheet: View {
    @ObservedObject var vm: PurchaseOrderDetailViewModel
    let detail: PurchaseOrderDetail
    var onReceived: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [ReceiveLine] = []
    @State private var warehouses: [WarehouseInfo] = []
    @State private var warehouseId = 0
    @State private var isSubmitting = false
    @State private var localError: String?
    /// Ключ повтора приёмки — на это окно (закрыли — пропал).
    @State private var idem = IdempotencyKeys.form()

    var body: some View {
        NavigationStack {
            Form {
                Section("Склад приёмки") {
                    Picker("Склад", selection: $warehouseId) {
                        Text("Из заказа / основной").tag(0)
                        ForEach(warehouses) { w in
                            Text(w.name ?? "Склад").tag(w.warehouseId)
                        }
                    }
                }
                Section("Фактически принято") {
                    ForEach($lines) { $line in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: $line.include) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name).font(.subheadline.weight(.medium))
                                    Text("осталось \(QtyFmt.qty(line.remaining)) \(line.unit)")
                                        .font(.caption).foregroundColor(Brand.muted)
                                }
                            }
                            .tint(Brand.green)
                            if line.include {
                                HStack {
                                    TextField("Кол-во", text: $line.qtyText)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.roundedBorder)
                                        // Поправили количество — текст ошибки строки убираем.
                                        .onChange(of: line.qtyText) { _ in
                                            if vm.receiveLineError?.poiId == line.id { vm.receiveLineError = nil }
                                        }
                                    TextField("Цена, ₽", text: $line.priceText)
                                        .keyboardType(.decimalPad)
                                        .textFieldStyle(.roundedBorder)
                                }
                                // Без срока выбор даты показывал сегодняшнюю дату, хотя срок
                                // не уходил на сервер (и «сегодня» было не выбрать). Теперь
                                // срок задаётся явно. Кнопки — borderless: кнопка строки Form
                                // без стиля срабатывала от тапа по названию и стирала срок.
                                if line.expiresAt != nil {
                                    DatePicker("Срок годности",
                                               selection: Binding(
                                                   get: { line.expiresAt ?? Date() },
                                                   set: { line.expiresAt = $0 }
                                               ),
                                               displayedComponents: .date)
                                        .font(.caption)
                                    Button("Убрать срок годности") { line.expiresAt = nil }
                                        .font(.caption).foregroundColor(Brand.red)
                                        .buttonStyle(.borderless)
                                } else {
                                    Button("Указать срок годности") { line.expiresAt = Date() }
                                        .font(.caption)
                                        .buttonStyle(.borderless)
                                }
                            }
                            // А317: сервер не принял больше остатка — его текст у этой строки.
                            if let le = vm.receiveLineError, le.poiId == line.id {
                                Text(le.text).font(.caption).foregroundColor(Brand.red)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let err = localError {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer(); if isSubmitting { ProgressView() } else { Text("Провести приёмку").bold() }; Spacer() }
                    }
                    .disabled(isSubmitting || lines.allSatisfy { !$0.include || $0.qty <= 0 })
                } footer: {
                    Text("Сервер создаст и проведёт приход: остатки, партии и себестоимость обновятся автоматически. Частичная приёмка оставит заказ открытым.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Приёмка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Пока приёмка уходит — не закрываем (ключ повтора живёт с окном).
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() }.disabled(isSubmitting) }
            }
            .task {
                // Строки — сразу из заказа, склады — потом: раньше строки ждали
                // ответа списка складов, и на плохой сети форма приёмки минуту
                // стояла пустой (а без сети — до ошибки запроса).
                if lines.isEmpty {
                    lines = (detail.items ?? []).compactMap { it in
                        let rem = it.remaining
                        guard rem > 0 else { return nil }
                        return ReceiveLine(id: it.id, name: it.name ?? "—", unit: it.unit ?? "",
                                           remaining: rem, qtyText: "\(rem)",
                                           priceText: (it.price ?? 0) > 0 ? "\(it.price ?? 0)" : "",
                                           expiresAt: nil, include: true)
                    }
                }
                warehouses = (try? await API.shared.warehouses()) ?? warehouses
            }
            // Свайп вниз закрывал приёмку и стирал введённые количества и сроки
            // годности, а во время отправки — прятал итог проведения. Закрыть — «Отмена».
            .interactiveDismissDisabled()
        }
    }

    @MainActor private func submit() async {
        // Двойной тап проводил приёмку дважды: два прихода, остатки ×2.
        guard !isSubmitting else { return }
        isSubmitting = true
        localError = nil
        // Строка с нечитаемым количеством или ценой раньше молча пропускалась —
        // частичная приёмка без предупреждения.
        if let bad = lines.first(where: { $0.include && (
            (!$0.qtyText.trimmingCharacters(in: .whitespaces).isEmpty && Money.strict($0.qtyText, maxFraction: 3) == nil)
            || (!$0.priceText.trimmingCharacters(in: .whitespaces).isEmpty && $0.price == nil)) }) {
            localError = "«\(bad.name)»: проверьте количество и цену"
            isSubmitting = false
            return
        }
        var items: [[String: Any]] = []
        for line in lines where line.include && line.qty > 0 {
            var row: [String: Any] = ["poi_id": line.id, "qty": "\(line.qty)"]
            if let p = line.price, p > 0 { row["price"] = "\(p)" }
            if let exp = line.expiresAt { row["expires_at"] = DateFmt.ymd(exp) }
            items.append(row)
        }
        let ok = await vm.receive(id: detail.poId ?? 0,
                                  warehouseId: warehouseId > 0 ? warehouseId : nil,
                                  items: items, keys: idem)
        isSubmitting = false
        if ok { onReceived?(); dismiss() } else { localError = vm.error }
    }
}
