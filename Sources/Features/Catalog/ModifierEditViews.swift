import SwiftUI

// ============================================================================
//  АY (сайт А616): правка варианта и группы модификаторов без удаления.
//   • PUT /api/seller/modifiers/{id}        — name, price, is_available
//   • PUT /api/seller/modifier-groups/{id}  — name, type, is_required, min_qty, max_qty
//  Шлём только изменённые поля. Цена варианта — только с правом «Цены»
//  (products.price): без него поле цены не редактируется и в тело не попадает.
//  Старый сервер ручки не знает (405/404) — «Доступно после обновления сайта».
//  Пока запрос идёт — окно не закрывается. Обрыв связи (исход неизвестен) —
//  форма заблокирована, «Повторить» шлёт то же тело, «Закрыть» перечитывает список.
// ============================================================================

/// Состояние отправки правки (общее для двух окон).
@MainActor
final class ModifierEditSender: ObservableObject {
    @Published var saving = false
    @Published var error: String?
    /// Исход неизвестен: поля заблокированы, повтор — тем же телом.
    @Published var unknownOutcome = false
    private var pendingBody: [String: Any?]?

    /// true — сохранено (окно можно закрыть).
    func send(_ body: [String: Any?], op: @escaping ([String: Any?]) async throws -> Void) async -> Bool {
        guard !saving else { return false }
        let payload = unknownOutcome ? (pendingBody ?? body) : body
        pendingBody = payload
        saving = true
        defer { saving = false }
        error = nil
        do {
            try await op(payload)
            pendingBody = nil
            unknownOutcome = false
            return true
        } catch {
            if API.isNoRoute(error) {
                pendingBody = nil
                unknownOutcome = false
                self.error = AnalyticsExtraText.unavailable
            } else if API.keyedOutcomeUnknown(error) {
                unknownOutcome = true
                let raw = error.localizedDescription
                let msg = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
                self.error = msg + ". Изменения могли сохраниться — нажмите «Повторить» или закройте окно и проверьте список."
            } else {
                // Ответ сервера получен (проверка полей, 401, 403, 429…) — форма снова открыта.
                pendingBody = nil
                unknownOutcome = false
                self.error = error.localizedDescription
            }
            return false
        }
    }
}

// ── Вариант ──────────────────────────────────────────────────────────────────
struct ModifierOptionEditSheet: View {
    let option: ModifierOption
    let canPrice: Bool
    /// Закрыли окно: changed — сохранено или исход неизвестен (перечитать список).
    let onClose: (Bool) -> Void

    @StateObject private var sender = ModifierEditSender()
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var priceText: String
    @State private var available: Bool

    init(option: ModifierOption, canPrice: Bool, onClose: @escaping (Bool) -> Void) {
        self.option = option
        self.canPrice = canPrice
        self.onClose = onClose
        _name = State(initialValue: option.name ?? "")
        _priceText = State(initialValue: option.price.map { "\($0)".replacingOccurrences(of: ".", with: ",") } ?? "0")
        _available = State(initialValue: option.isAvailable != false)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedPrice: Decimal? {
        let t = priceText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? 0 : Money.strict(t)
    }

    /// Только изменённые поля.
    private var changes: [String: Any?] {
        var body: [String: Any?] = [:]
        if trimmedName != (option.name ?? "") { body["name"] = trimmedName }
        if canPrice, let p = parsedPrice, p != (option.price ?? 0) { body["price"] = "\(p)" }
        if available != (option.isAvailable != false) { body["is_available"] = available ? 1 : 0 }
        return body
    }

    private var locked: Bool { sender.saving || sender.unknownOutcome }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $name).disabled(locked)
                    TextField("Цена", text: $priceText)
                        .keyboardType(.decimalPad)
                        .disabled(locked || !canPrice)
                    Toggle("В наличии", isOn: $available).disabled(locked)
                } footer: {
                    if !canPrice {
                        Text("Цену меняет сотрудник с правом «Менять цены»")
                    } else if parsedPrice == nil {
                        Text("Цена — число, например 50 или 49,90").foregroundColor(Brand.red)
                    }
                }
                .listRowBackground(Brand.card)
                if let err = sender.error {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                        .listRowBackground(Brand.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Изменить вариант")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sender.unknownOutcome ? "Закрыть" : "Отмена") {
                        let reread = sender.unknownOutcome
                        dismiss()
                        onClose(reread)
                    }
                    .disabled(sender.saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sender.saving {
                        ProgressView()
                    } else {
                        Button(sender.unknownOutcome ? "Повторить" : "Сохранить") {
                            let id = option.optionId
                            let body = changes
                            Task {
                                if await sender.send(body, op: { try await API.shared.updateModifierOption(id: id, fields: $0) }) {
                                    dismiss()
                                    onClose(true)
                                }
                            }
                        }
                        .disabled(!sender.unknownOutcome
                                  && (changes.isEmpty || (changes["name"] != nil && trimmedName.isEmpty)
                                      || (canPrice && parsedPrice == nil)))
                    }
                }
            }
        }
        .interactiveDismissDisabled(sender.saving || sender.unknownOutcome)
    }
}

// ── Группа ───────────────────────────────────────────────────────────────────
struct ModifierGroupEditSheet: View {
    let group: ModifierGroup
    let onClose: (Bool) -> Void

    @StateObject private var sender = ModifierEditSender()
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var multiple: Bool
    @State private var required: Bool
    @State private var minQty: Int
    @State private var maxQty: Int

    init(group: ModifierGroup, onClose: @escaping (Bool) -> Void) {
        self.group = group
        self.onClose = onClose
        _name = State(initialValue: group.name ?? "")
        _multiple = State(initialValue: group.isMultiple)
        _required = State(initialValue: group.isRequired == true)
        _minQty = State(initialValue: group.minQty ?? 0)
        _maxQty = State(initialValue: group.maxQty ?? 0)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var minMaxInvalid: Bool { maxQty > 0 && minQty > maxQty }
    private var stepperTop: Int { min(999, max(20, group.minQty ?? 0, group.maxQty ?? 0)) }
    /// «Один вариант» — выбрать можно не больше одного (как проверяет сервер).
    private var singleInvalid: Bool { !multiple && (maxQty > 1 || minQty > 1) }

    private var changes: [String: Any?] {
        var body: [String: Any?] = [:]
        if trimmedName != (group.name ?? "") { body["name"] = trimmedName }
        if multiple != group.isMultiple { body["type"] = multiple ? "multi" : "single" }
        if required != (group.isRequired == true) { body["is_required"] = required ? 1 : 0 }
        if minQty != (group.minQty ?? 0) { body["min_qty"] = minQty }
        // 0 — «без ограничения»: серверу явный null (иначе ключ выпал бы из тела).
        if maxQty != (group.maxQty ?? 0) { body["max_qty"] = maxQty == 0 ? NSNull() : maxQty }
        return body
    }

    private var locked: Bool { sender.saving || sender.unknownOutcome }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название группы", text: $name)
                    Toggle("Можно выбрать несколько", isOn: $multiple)
                    Toggle("Обязательная группа", isOn: $required)
                    // Верх — не меньше сохранённого значения (сервер допускает до 999).
                    Stepper("Минимум: \(minQty)", value: $minQty, in: 0...stepperTop)
                    Stepper(maxQty == 0 ? "Максимум: без ограничения" : "Максимум: \(maxQty)",
                            value: $maxQty, in: 0...stepperTop)
                } footer: {
                    if minMaxInvalid {
                        Text("Минимум не может быть больше максимума").foregroundColor(Brand.red)
                    } else if singleInvalid {
                        Text("В группе «один вариант» можно выбрать не больше одного").foregroundColor(Brand.red)
                    }
                }
                .disabled(locked)
                .listRowBackground(Brand.card)
                if let err = sender.error {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                        .listRowBackground(Brand.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Изменить группу")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sender.unknownOutcome ? "Закрыть" : "Отмена") {
                        let reread = sender.unknownOutcome
                        dismiss()
                        onClose(reread)
                    }
                    .disabled(sender.saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sender.saving {
                        ProgressView()
                    } else {
                        Button(sender.unknownOutcome ? "Повторить" : "Сохранить") {
                            let id = group.groupId
                            let body = changes
                            Task {
                                if await sender.send(body, op: { try await API.shared.updateModifierGroup(id: id, fields: $0) }) {
                                    dismiss()
                                    onClose(true)
                                }
                            }
                        }
                        .disabled(!sender.unknownOutcome
                                  && (changes.isEmpty || (changes["name"] != nil && trimmedName.isEmpty)
                                      || minMaxInvalid || singleInvalid))
                    }
                }
            }
        }
        .interactiveDismissDisabled(sender.saving || sender.unknownOutcome)
    }
}
