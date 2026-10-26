import SwiftUI

// ============================================================================
//  Способы оплаты — GET /api/seller/settings/payment (shop_payment_methods),
//  сохранение POST {methods:[{type, is_enabled, comment, available_for[]}]}.
//  Типы сервера: cash | card_courier | sbp | online_card.
// ============================================================================

/// Локальное редактируемое состояние способа оплаты.
struct EditablePaymentMethod: Identifiable {
    let type: String
    var isEnabled: Bool
    var comment: String
    var availableFor: Set<String>
    var id: String { type }

    // Онлайн-оплаты заказов нет (ЮKassa — только кошелёк и объявления):
    // сервер способ «online_card» не сохраняет, поэтому и не показываем.
    static let allTypes = ["cash", "card_courier", "sbp"]
    static let contexts: [(String, String)] = [
        ("delivery", "Доставка"), ("pickup", "Самовывоз"), ("dine_in", "В зале"),
    ]

    static func title(_ type: String) -> String { PaymentLabels.type(type) }
}

@MainActor
final class PaymentSettingsViewModel: ObservableObject {
    /// Правка снимает «Сохранено» — надпись не должна висеть над несохранённым.
    @Published var methods: [EditablePaymentMethod] = [] { didSet { success = false } }
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var success = false
    @Published var saving = false
    /// Способы ещё ни разу не сохраняли (новая организация).
    @Published var notConfigured = false

    func load() async {
        state = .loading
        do {
            let rows = try await API.shared.paymentMethods()
            // Новая организация: строк нет, и сервер принимает ЛЮБОЙ способ
            // (orderAcceptCheck, cart.php payment_methods_configured). Экран же
            // рисовал все выключенными, и «Сохранить» без правок выключало
            // оплату совсем — заказ оформить было нечем. Показываем как есть.
            let fresh = rows.isEmpty
            notConfigured = fresh
            // Полный список типов; сохранённые перекрывают дефолты.
            methods = EditablePaymentMethod.allTypes.map { type in
                if let row = rows.first(where: { $0.type == type }) {
                    return EditablePaymentMethod(type: type,
                                                 isEnabled: row.isEnabled ?? false,
                                                 comment: row.comment ?? "",
                                                 availableFor: Set(row.availableForList))
                }
                return EditablePaymentMethod(type: type, isEnabled: fresh, comment: "",
                                             availableFor: ["delivery", "pickup", "dine_in"])
            }
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func save() async {
        // Способы не загрузились (загрузка идёт или упала) — список пуст, и
        // «Сохранить» отправляло methods: [] — сервер заменял список целиком,
        // покупателям нечем было платить. Двойной тап — один запрос.
        guard state == .loaded, !methods.isEmpty, !saving else { return }
        saving = true
        defer { saving = false }
        error = nil
        success = false
        // Пустой список «где доступен» сервер заменяет на все три способа
        // получения (seller_settings.php, settings/payment) — снятые галочки
        // молча превращались в «везде». Просим выбрать или выключить способ.
        if let m = methods.first(where: { $0.isEnabled && $0.availableFor.isEmpty }) {
            error = "«\(EditablePaymentMethod.title(m.type))»: отметьте, где способ доступен, или выключите его"
            return
        }
        let payload: [[String: Any]] = methods.map { m in
            [
                "type": m.type,
                "is_enabled": m.isEnabled ? 1 : 0,
                "comment": m.comment,
                "available_for": Array(m.availableFor),
            ]
        }
        do {
            try await API.shared.savePaymentMethods(payload)
            success = true
            notConfigured = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PaymentSettingsView: View {
    @StateObject private var vm = PaymentSettingsViewModel()

    var body: some View {
        Form {
            if vm.notConfigured && vm.state == .loaded {
                Section {
                    Text("Способы оплаты ещё не настроены — сейчас клиент может выбрать любой. Оставьте нужные и нажмите «Сохранить».")
                        .font(.footnote).foregroundColor(Brand.amber)
                }
                .listRowBackground(Brand.card)
            }
            ForEach($vm.methods) { $method in
                Section(EditablePaymentMethod.title(method.type)) {
                    Toggle("Включён", isOn: $method.isEnabled).tint(Brand.green)
                    if method.isEnabled {
                        TextField("Комментарий для клиента", text: $method.comment)
                        ForEach(EditablePaymentMethod.contexts, id: \.0) { key, title in
                            Toggle(title, isOn: Binding(
                                get: { method.availableFor.contains(key) },
                                set: { on in
                                    if on { $method.wrappedValue.availableFor.insert(key) }
                                    else { $method.wrappedValue.availableFor.remove(key) }
                                }
                            ))
                            .tint(Brand.accent)
                        }
                    }
                }
                .listRowBackground(Brand.card)
            }
            Section {
                Button("Сохранить") { Task { await vm.save() } }
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.accent)
                    .disabled(vm.state != .loaded || vm.methods.isEmpty || vm.saving)
                // Все выключены — сервер не примет ни одного способа (заказ не оформить).
                if vm.state == .loaded && !vm.methods.isEmpty && !vm.methods.contains(where: { $0.isEnabled }) {
                    Text("Все способы выключены — клиенты не смогут оформить заказ.")
                        .font(.footnote).foregroundColor(Brand.amber)
                }
                if vm.success {
                    Text("Сохранено").font(.footnote).foregroundColor(Brand.green)
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .listRowBackground(Brand.card)
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Способы оплаты")
        .navigationBarTitleDisplayMode(.inline)
        .listState(vm.state, isEmpty: vm.methods.isEmpty,
                   emptyIcon: "creditcard", emptyTitle: "Загрузка…",
                   retry: { Task { await vm.load() } })
        // Только первая загрузка (или повтор после ошибки): .task срабатывает
        // при каждом возврате на экран (из «Часов работы», с другой вкладки) и
        // затирал несохранённые правки данными сервера.
        .task {
            // Пропускаем, только если загрузка ЗАВЕРШИЛАСЬ: ушли с экрана посреди
            // первой загрузки — она отменилась, состояние осталось .loading, и
            // экран висел со спиннером навсегда.
            if vm.state != .loaded { await vm.load() }
        }
    }
}
