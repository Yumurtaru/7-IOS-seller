import SwiftUI

// ============================================================================
//  Поставщики — GET/POST/PUT/DELETE /api/seller/suppliers (DELETE = is_active 0),
//  деталь: история поставок + статистика; прайс-лист:
//  GET/POST /api/seller/suppliers/{id}/prices, DELETE /api/seller/supplier-prices/{id}.
// ============================================================================

@MainActor
final class SuppliersViewModel: ObservableObject {
    @Published var suppliers: [Supplier] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    func load() async {
        if suppliers.isEmpty { state = .loading }
        do {
            suppliers = try await API.shared.suppliers()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func save(id: Int?, fields: [String: Any?]) async -> Bool {
        error = nil
        do {
            if let id = id {
                try await API.shared.updateSupplier(id: id, fields: fields)
            } else {
                _ = try await API.shared.createSupplier(fields: fields)
            }
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deactivate(_ s: Supplier) async {
        error = nil
        do {
            try await API.shared.deleteSupplier(id: s.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SuppliersView: View {
    @StateObject private var vm = SuppliersViewModel()
    @State private var editing: SupplierEditTarget?
    /// Паритет с Android: выключение поставщика — только после вопроса.
    @State private var deactivating: Supplier?

    var body: some View {
        List {
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                    .listRowBackground(Brand.card)
            }
            ForEach(vm.suppliers) { s in
                NavigationLink {
                    SupplierDetailView(supplierId: s.id, listVM: vm)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.name ?? "—")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text)
                            Text(joinedNonEmpty([s.phone, s.inn.map { "ИНН \($0)" }], separator: " · "))
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        if s.isActive == false {
                            StatusBadge(text: "неактивен", color: Brand.muted)
                        }
                    }
                }
                .listRowBackground(Brand.card)
                // Без полного свайпа: длинный жест сразу выключал поставщика —
                // он пропадал из выбора в закупках и документах без вопроса.
                .swipeActions(allowsFullSwipe: false) {
                    if s.isActive != false {
                        Button(role: .destructive) {
                            deactivating = s
                        } label: {
                            Label("Деактивировать", systemImage: "nosign")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Поставщики")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editing = SupplierEditTarget(form: nil) } label: { Image(systemName: "plus") }
            }
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.suppliers.isEmpty,
                   emptyIcon: "truck.box", emptyTitle: "Поставщиков нет",
                   emptySubtitle: "Добавьте первого поставщика кнопкой «+»",
                   retry: { Task { await vm.load() } })
        .sheet(item: $editing) { target in
            SupplierEditSheet(vm: vm, initial: target.form)
        }
        .confirmationDialog(
            "Деактивировать «\(deactivating?.name ?? "поставщика")»?",
            isPresented: Binding(get: { deactivating != nil }, set: { if !$0 { deactivating = nil } }),
            titleVisibility: .visible,
            presenting: deactivating
        ) { s in
            Button("Деактивировать", role: .destructive) {
                deactivating = nil
                Task { await vm.deactivate(s) }
            }
            Button("Отмена", role: .cancel) { deactivating = nil }
        } message: { _ in
            Text("Поставщик пропадёт из выбора в закупках и документах. Вернуть — переключателем «Активен» в карточке.")
        }
        .task { await vm.load() }
    }
}

struct SupplierEditTarget: Identifiable {
    let id = UUID()
    let form: SupplierFormData?
}

/// Плоские поля формы — не тащим DTO с property-wrapper'ами в @State.
struct SupplierFormData {
    var supplierId: Int?
    var name: String
    var phone: String
    var email: String
    var inn: String
    var address: String
    var comment: String
    var isActive: Bool

    init(from s: Supplier) {
        supplierId = s.supplierId
        name = s.name ?? ""; phone = s.phone ?? ""; email = s.email ?? ""
        inn = s.inn ?? ""; address = s.address ?? ""; comment = s.comment ?? ""
        isActive = s.isActive ?? true
    }

    init(from d: SupplierDetail) {
        supplierId = d.supplierId
        name = d.name ?? ""; phone = d.phone ?? ""; email = d.email ?? ""
        inn = d.inn ?? ""; address = d.address ?? ""; comment = d.comment ?? ""
        isActive = d.isActive ?? true
    }
}

// ── Создание / правка поставщика ─────────────────────────────────────────────
struct SupplierEditSheet: View {
    @ObservedObject var vm: SuppliersViewModel
    let initial: SupplierFormData?
    var onSaved: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var inn = ""
    @State private var address = ""
    @State private var comment = ""
    @State private var isActive = true
    @State private var isSubmitting = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Поставщик") {
                    TextField("Название *", text: $name)
                    TextField("Телефон", text: $phone.phoneInput).keyboardType(.phonePad)
                    TextField("E-mail", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    TextField("ИНН", text: $inn).keyboardType(.numberPad)
                    TextField("Адрес", text: $address)
                    TextField("Комментарий", text: $comment, axis: .vertical).lineLimit(2...4)
                    if initial?.supplierId != nil {
                        Toggle("Активен", isOn: $isActive).tint(Brand.green)
                    }
                }
                // Подсказка об опечатке — не запрет: сервер хранит любую строку (паритет с Android).
                if let w = innWarning ?? mailWarning {
                    Section { Text(w).font(.footnote).foregroundColor(Brand.amber) }
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
                    .disabled(isSubmitting || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(initial?.supplierId == nil ? "Новый поставщик" : "Поставщик")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
            .onAppear {
                if let f = initial {
                    name = f.name; phone = f.phone; email = f.email
                    inn = f.inn; address = f.address; comment = f.comment
                    isActive = f.isActive
                }
            }
        }
    }

    /// Опечатка в ИНН — предупреждение, сохранение не блокирует (сервер хранит любую
    /// строку). Проверяем только изменённое поле; исходное тоже обрезаем.
    private var innWarning: String? {
        let innT = inn.trimmingCharacters(in: .whitespaces)
        guard !innT.isEmpty, innT != (initial?.inn ?? "").trimmingCharacters(in: .whitespaces) else { return nil }
        let digits = innT.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 })
        if (innT.count == 10 || innT.count == 12) && digits { return nil }
        return "ИНН обычно 10 цифр (организация) или 12 цифр (ИП) — проверьте"
    }

    /// Опечатка в e-mail — тоже только предупреждение.
    private var mailWarning: String? {
        let mailT = email.trimmingCharacters(in: .whitespaces)
        guard !mailT.isEmpty, mailT != (initial?.email ?? "").trimmingCharacters(in: .whitespaces) else { return nil }
        let at = mailT.split(separator: "@", omittingEmptySubsequences: false)
        if at.count == 2 && !at[0].isEmpty && at[1].contains(".") && !mailT.contains(" ") { return nil }
        return "Проверьте e-mail — например, zakaz@postavshik.ru"
    }

    @MainActor private func submit() async {
        guard !isSubmitting else { return }   // двойной тап создавал двух поставщиков
        isSubmitting = true
        localError = nil
        // При правке очищенное поле уходит пустой строкой: nil-ключи makeRequest
        // выбрасывает, и стёртый телефон/ИНН/адрес оставался на сервере, хотя
        // экран показывал «сохранено». При создании пустые поля не шлём.
        let editing = initial?.supplierId != nil
        func opt(_ v: String) -> Any? { v.isEmpty ? (editing ? "" : nil) : v }
        var fields: [String: Any?] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "phone": opt(phone),
            "email": opt(email),
            "inn": opt(inn),
            "address": opt(address),
            "comment": opt(comment),
        ]
        if initial?.supplierId != nil { fields["is_active"] = isActive ? 1 : 0 }
        let ok = await vm.save(id: initial?.supplierId, fields: fields)
        isSubmitting = false
        if ok { onSaved?(); dismiss() } else { localError = vm.error }
    }
}

// ── Деталь поставщика: карточка + история + прайс ────────────────────────────
@MainActor
final class SupplierDetailViewModel: ObservableObject {
    @Published var detail: SupplierDetail?
    @Published var prices: [SupplierPrice] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    func load(id: Int) async {
        if detail == nil { state = .loading }
        do {
            detail = try await API.shared.supplier(id: id)
            // Прайс может быть не установлен (503 до миграции) — не роняем экран.
            prices = (try? await API.shared.supplierPrices(supplierId: id)) ?? []
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Позиции прайса, удаление которых уже в пути: второй тап по корзине слал
    /// второй DELETE, и поверх успешного удаления появлялась ошибка.
    @Published private(set) var deletingPriceIds: Set<Int> = []

    func deletePrice(_ p: SupplierPrice, supplierId: Int) async {
        guard !deletingPriceIds.contains(p.id) else { return }
        deletingPriceIds.insert(p.id)
        defer { deletingPriceIds.remove(p.id) }
        error = nil
        do {
            try await API.shared.deleteSupplierPrice(id: p.id)
            await load(id: supplierId)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func addPrice(supplierId: Int, item: StockSearchItem, price: Decimal, sku: String?, packQty: Decimal?) async -> Bool {
        error = nil
        do {
            try await API.shared.saveSupplierPrice(
                supplierId: supplierId, kind: item.kind ?? "product",
                positionId: item.itemId ?? 0, price: price, supplierSku: sku, packQty: packQty)
            await load(id: supplierId)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct SupplierDetailView: View {
    let supplierId: Int
    @ObservedObject var listVM: SuppliersViewModel
    @StateObject private var vm = SupplierDetailViewModel()
    @State private var showEdit = false
    @State private var showAddPrice = false
    /// Паритет с Android: удаление позиции прайса — с вопросом (корзина стоит вплотную к цене).
    @State private var deletingPrice: SupplierPrice?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let d = vm.detail {
                    infoCard(d)
                    statsCard(d)
                    pricesCard
                    deliveriesCard(d)
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(vm.detail?.name ?? "Поставщик")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Изменить") { showEdit = true }
            }
        }
        .refreshable { await vm.load(id: supplierId) }
        .listState(vm.state, isEmpty: vm.detail == nil,
                   emptyIcon: "truck.box", emptyTitle: "Нет данных",
                   retry: { Task { await vm.load(id: supplierId) } })
        .sheet(isPresented: $showEdit) {
            SupplierEditSheet(vm: listVM, initial: vm.detail.map { SupplierFormData(from: $0) }) {
                Task { await vm.load(id: supplierId) }
            }
        }
        .sheet(isPresented: $showAddPrice) {
            AddSupplierPriceSheet(vm: vm, supplierId: supplierId)
        }
        .confirmationDialog(
            "Удалить позицию прайса?",
            isPresented: Binding(get: { deletingPrice != nil }, set: { if !$0 { deletingPrice = nil } }),
            titleVisibility: .visible,
            presenting: deletingPrice
        ) { p in
            Button("Удалить «\(p.name ?? "позицию")»", role: .destructive) {
                deletingPrice = nil
                Task { await vm.deletePrice(p, supplierId: supplierId) }
            }
            Button("Отмена", role: .cancel) { deletingPrice = nil }
        }
        .task { await vm.load(id: supplierId) }
    }

    private func infoCard(_ d: SupplierDetail) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 6) {
                if let p = d.phone, !p.isEmpty { InfoRow(label: "Телефон", value: p) }
                if let e = d.email, !e.isEmpty { InfoRow(label: "E-mail", value: e) }
                if let i = d.inn, !i.isEmpty { InfoRow(label: "ИНН", value: i) }
                if let a = d.address, !a.isEmpty { InfoRow(label: "Адрес", value: a) }
                if let c = d.comment, !c.isEmpty { InfoRow(label: "Комментарий", value: c) }
                if d.isActive == false { StatusBadge(text: "неактивен", color: Brand.muted) }
            }
        }
    }

    @ViewBuilder
    private func statsCard(_ d: SupplierDetail) -> some View {
        if let st = d.stats {
            SectionCard(title: "Статистика поставок") {
                InfoRow(label: "Приходов", value: "\(st.cnt ?? 0)")
                InfoRow(label: "Оборот", value: Money.rub(st.turnover))
                if let last = st.lastAt, !last.isEmpty {
                    InfoRow(label: "Последняя поставка", value: DateFmt.short(last))
                }
            }
        }
    }

    private var pricesCard: some View {
        SectionCard(title: "Прайс-лист") {
            if vm.prices.isEmpty {
                Text("Позиции прайса не заведены").font(.caption).foregroundColor(Brand.muted)
            } else {
                ForEach(vm.prices) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name ?? "—")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text).lineLimit(1)
                            Text([p.supplierSku.map { "SKU \($0)" },
                                  p.packQty.map { "упак. \(QtyFmt.qty($0))" }]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        Text(Money.rub(p.price))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Brand.text)
                        Button {
                            deletingPrice = p
                        } label: {
                            Image(systemName: "trash").foregroundColor(Brand.red).font(.caption)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.deletingPriceIds.contains(p.id))
                    }
                    .padding(.vertical, 3)
                }
            }
            Button {
                showAddPrice = true
            } label: {
                Label("Добавить позицию прайса", systemImage: "plus")
                    .font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private func deliveriesCard(_ d: SupplierDetail) -> some View {
        if let rows = d.deliveries, !rows.isEmpty {
            SectionCard(title: "История поставок") {
                ForEach(rows) { doc in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.number ?? "ПРХ-\(doc.id)")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text)
                            Text(DateFmt.short(doc.postedAt ?? doc.createdAt))
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.rub(doc.totalAmount))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.text)
                            StatusBadge(text: doc.status == "posted" ? "проведён" : (doc.status == "draft" ? "черновик" : "отменён"),
                                        color: doc.status == "posted" ? Brand.green : Brand.muted)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// ── Позиция прайса: поиск позиции + цена ─────────────────────────────────────
struct AddSupplierPriceSheet: View {
    @ObservedObject var vm: SupplierDetailViewModel
    let supplierId: Int
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [StockSearchItem] = []
    @State private var selected: StockSearchItem?
    @State private var priceText = ""
    @State private var sku = ""
    @State private var packText = ""
    @State private var isSubmitting = false
    @State private var localError: String?
    @State private var searchTask: Task<Void, Never>?
    /// Поиск не удался (нет сети): раньше список просто оставался пустым,
    /// и казалось, что позиции нет в базе.
    @State private var searchError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Позиция") {
                    if let sel = selected {
                        HStack {
                            Text(sel.name ?? "—").font(.subheadline.weight(.medium))
                            Spacer()
                            // Цена прежней позиции не должна переехать на новую.
                            Button("Сменить") { selected = nil; priceText = "" }
                                .font(.caption)
                                // Без стиля кнопка строки Form срабатывала от тапа по
                                // названию — выбор и введённая цена сбрасывались.
                                .buttonStyle(.borderless)
                        }
                    } else {
                        TextField("Поиск товара или ингредиента", text: $query)
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
                                if priceText.isEmpty, let p = r.anyPrice, p > 0 { priceText = "\(p)" }
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
                Section("Условия") {
                    TextField("Цена, ₽ *", text: $priceText).keyboardType(.decimalPad)
                    TextField("Артикул поставщика (SKU)", text: $sku)
                    TextField("Кол-во в упаковке", text: $packText).keyboardType(.decimalPad)
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
                    .disabled(isSubmitting || selected == nil || Money.strict(priceText) == nil)
                } footer: {
                    // Кнопка гасла молча — пишем, чего не хватает.
                    if selected == nil {
                        Text("Найдите и выберите позицию в списке выше")
                    } else if Money.strict(priceText) == nil {
                        Text("Укажите цену — число, например 150 или 149,90").foregroundColor(Brand.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Позиция прайса")
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

    @MainActor private func submit() async {
        // Двойной тап добавлял позицию прайса дважды.
        guard !isSubmitting, let sel = selected,
              let price = Money.strict(priceText) else { return }   // «1 500» было 1 ₽
        let pack = Money.strict(packText, maxFraction: 3)
        // Опечатка в упаковке («6шт», «1,5,») раньше молча выкидывала поле:
        // позиция сохранялась без кратности, как будто её не вводили.
        if !packText.trimmingCharacters(in: .whitespaces).isEmpty && (pack ?? 0) <= 0 {
            localError = "Кол-во в упаковке — число больше нуля, например 6 или 0,5"
            return
        }
        isSubmitting = true
        localError = nil
        let ok = await vm.addPrice(supplierId: supplierId, item: sel, price: price,
                                   sku: sku.isEmpty ? nil : sku, packQty: pack)
        isSubmitting = false
        if ok { dismiss() } else { localError = vm.error }
    }
}
