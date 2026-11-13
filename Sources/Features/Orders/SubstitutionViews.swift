import SwiftUI

// ============================================================================
//  Замены товаров (П-72 п.4): подпись выбора клиента, предложение замены,
//  статус ответа, «позвонить»; настройка «Время на ответ клиента, мин».
//  POST|DELETE /api/seller/orders/{id}/items/{item_id}/substitute,
//  GET|POST /api/seller/substitution/settings.
// ============================================================================

/// Блок замены под позицией заказа. Пусто, если нет ни выбора клиента, ни замены,
/// и предложить её нельзя. Лист выбора товара — единственный .sheet этой вью.
struct SubstitutionItemRow: View {
    let item: OrderItem
    let orderStatus: String?
    let clientPhone: String?
    let canAct: Bool
    let busy: Bool
    /// (itemId, productId, qty) → успех.
    let onPropose: (Int, Int, Decimal?) async -> Bool
    let onRevoke: (Int) async -> Void

    @State private var showPicker = false

    /// Пустой/кривой блок substitute (нет ни товара, ни статуса) считаем отсутствующим.
    private var sub: SubstituteInfo? {
        guard let s = item.substitute, (s.productId ?? 0) > 0 || s.status != nil else { return nil }
        return s
    }

    private var canPropose: Bool {
        canAct && (item.lineId ?? 0) > 0 && sub == nil && !Substitution.orderClosed(orderStatus)
    }

    var body: some View {
        let choice = Substitution.choiceLabel(item.substitution)
        if choice != nil || sub != nil || canPropose {
            VStack(alignment: .leading, spacing: 3) {
                if let choice = choice {
                    Text(choice).font(.caption).foregroundColor(Brand.muted)
                }
                if let s = sub { substituteBlock(s) }
                if canPropose {
                    Button("Предложить замену") { showPicker = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.accent)
                        .disabled(busy)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(isPresented: $showPicker) {
                SubstitutionPickerSheet(itemName: item.name ?? "Позиция") { productId, qty in
                    showPicker = false
                    Task { _ = await onPropose(item.lineId ?? 0, productId, qty) }
                }
            }
        }
    }

    @ViewBuilder
    private func substituteBlock(_ s: SubstituteInfo) -> some View {
        let qty = s.qty.map { "\($0)" } ?? ""
        let price = s.price.map { Money.rub($0) } ?? ""
        let line = "Замена: " + (s.name ?? "товар")
            + (qty.isEmpty ? "" : " · \(qty)")
            + (price.isEmpty ? "" : " × \(price)")
        Text(line).font(.footnote).foregroundColor(Brand.text)
        switch s.status {
        case "pending":
            let until = Substitution.hhmm(s.deadlineAt)
            Text(until.map { "Ждём ответа клиента до \($0)" } ?? "Ждём ответа клиента")
                .font(.footnote.weight(.semibold)).foregroundColor(Brand.accent)
            if canAct, (item.lineId ?? 0) > 0 {
                Button("Отозвать") {
                    let id = item.lineId ?? 0
                    Task { await onRevoke(id) }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.red)
                .disabled(busy)
            }
        case "accepted":
            Text(s.outcome == "removed" ? "Клиент согласился: позиция убрана" : "Клиент принял замену")
                .font(.footnote.weight(.semibold)).foregroundColor(Brand.green)
        case "declined":
            Text(s.outcome == "removed" ? "Клиент отказался: позиция убрана" : "Клиент отказался от замены")
                .font(.footnote.weight(.semibold)).foregroundColor(Brand.red)
        case "auto":
            Text(s.outcome == "removed" ? "Время вышло: позиция убрана" : "Время вышло: замена принята автоматически")
                .font(.footnote).foregroundColor(Brand.muted)
        default:
            EmptyView()
        }
        if s.needsCall == true {
            Text("Клиент просил позвонить").font(.footnote.weight(.bold)).foregroundColor(Brand.red)
            if let phone = clientPhone, !phone.isEmpty,
               let url = URL(string: "tel://" + phone.filter { "+0123456789".contains($0) }) {
                Link(destination: url) {
                    Label("Позвонить клиенту", systemImage: "phone.fill").font(.subheadline.weight(.semibold))
                }
                .foregroundColor(Brand.green)
            }
        }
    }
}

/// Выбор товара своего магазина (поиск по активным) и количество (необязательно).
struct SubstitutionPickerSheet: View {
    let itemName: String
    let onPick: (Int, Decimal?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var qtyText = ""
    @State private var results: [ProductSummary] = []
    @State private var picked: ProductSummary?
    @State private var loadError: String?

    private var qtyParsed: Decimal? {
        let t = qtyText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : Money.strict(t, maxFraction: 3)
    }
    private var qtyBad: Bool {
        let t = qtyText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        guard let q = qtyParsed else { return true }
        return q <= 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Найти товар", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let e = loadError {
                        Text(e).font(.footnote).foregroundColor(Brand.red)
                    }
                    ForEach(results) { p in
                        Button {
                            picked = p
                        } label: {
                            HStack {
                                Text((picked?.id == p.id ? "✓ " : "") + (p.name ?? "—"))
                                    .foregroundColor(picked?.id == p.id ? Brand.accent : Brand.text)
                                Spacer()
                                Text(Money.rub(p.price)).font(.footnote).foregroundColor(Brand.muted)
                            }
                        }
                    }
                } header: { Text("Замена для: \(itemName)") }
                Section {
                    HStack {
                        Text("Количество")
                        Spacer()
                        TextField("как в заказе", text: $qtyText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    if qtyBad {
                        Text("Количество — положительное число").font(.footnote).foregroundColor(Brand.red)
                    }
                } footer: { Text("Необязательно: без количества берётся количество исходной позиции.") }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Предложить замену")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Предложить") {
                        if let p = picked, let id = p.id { onPick(id, qtyParsed) }
                    }
                    .disabled(picked?.id == nil || qtyBad)
                }
            }
            // Пауза 350 мс после ввода; прежний поиск отменяется сам (task(id:)).
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
                do {
                    let page = try await API.shared.products(category: nil, status: "active",
                                                             q: query.isEmpty ? nil : query, page: 1)
                    if Task.isCancelled { return }
                    results = page.items.filter { $0.isAvailable != false && $0.stopped != true }
                    loadError = nil
                } catch is CancellationError {
                } catch {
                    loadError = error.localizedDescription
                }
            }
        }
    }
}

/// Настройка «Время на ответ клиента, мин» (1–120) для списка настроек магазина.
struct SubstitutionSettingsSection: View {
    @State private var loaded: Int?
    @State private var text = ""
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false

    private var parsed: Int? { Int(text.filter { !$0.isWhitespace }) }
    private var canSave: Bool {
        guard let v = parsed, (1...120).contains(v) else { return false }
        return !busy && v != loaded
    }

    var body: some View {
        Section {
            HStack {
                Text("Время на ответ клиента, мин")
                Spacer()
                TextField("5", text: $text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
            }
            Button("Сохранить время на ответ") { Task { await save() } }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.accent)
                .disabled(!canSave)
            if let m = message {
                Text(m).font(.footnote).foregroundColor(messageIsError ? Brand.red : Brand.green)
            }
        } header: {
            Text("Замены товаров")
        } footer: {
            Text("От 1 до 120. Без ответа замена применяется по выбору клиента.")
        }
        .listRowBackground(Brand.card)
        .task { await load() }
    }

    private func load() async {
        do {
            let s = try await API.shared.substitutionSettings()
            if let v = s.timeoutMin { loaded = v; if text.isEmpty { text = String(v) } }
        } catch is CancellationError {
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }

    private func save() async {
        guard let v = parsed, (1...120).contains(v), !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await API.shared.saveSubstitutionSettings(timeoutMin: v)
            loaded = v
            message = "Сохранено"
            messageIsError = false
        } catch {
            message = error.localizedDescription
            messageIsError = true
        }
    }
}
