import SwiftUI

// ============================================================================
//  Конструктор акции — POST/PUT /api/seller/promotions (поля promoSave()),
//  типы условий/наград/аудиторий — GET /api/seller/promotions/catalog
//  (сервер уже отфильтровал по режиму магазина). Условия и награды при
//  сохранении заменяются целиком: [{type, config:{…}}].
// ============================================================================

/// Редактируемое условие/награда: тип из каталога + значения его полей.
struct EditablePromoPart: Identifiable {
    let id = UUID()
    var type: String
    var label: String
    var fields: [String]
    var values: [String: String] = [:]
    /// Какие поля в сохранённой акции были строкой и какие — списком. Без этого
    /// промокод «007» уходил числом 7, а список из одного товара
    /// {"product_ids":[5]} — числом 5: условие переставало работать после
    /// любого пересохранения (даже просто тумблера «Акция включена»).
    var stringKeys: Set<String> = []
    var arrayKeys: Set<String> = []
    /// А57/П-22.13: описание полей из каталога (field_defs) по ключу; пусто —
    /// старый сервер, подписи и разбор как раньше.
    var defs: [String: PromoFieldDef] = [:]

    /// config для сервера: числа — числами, "1,2,3" — массивом, прочее — строкой.
    var config: [String: Any] {
        var out: [String: Any] = [:]
        for (key, raw) in values {
            let v = raw.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { continue }
            let input = defs[key]?.input
            // А57/П-22.12: days у «дня недели» — массив ISO-дней [6] (1=Пн…7=Вс),
            // а у «дня рождения» — число «± дней»: раньше и оно уходило массивом [3].
            let numberOnly = input == "number" || (key == "days" && type == "birthday")
            // Списковые поля (ID товаров, дни недели) — массивом, даже из одного
            // значения; "5,5" в числовых полях — это десятичная запятая, НЕ список.
            if !numberOnly && (arrayKeys.contains(key) || key.hasSuffix("_ids") || key == "days"
                               || input == "weekdays" || input == "product_ids") {
                let parts = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) {
                    out[key] = parts.compactMap { Int($0) }
                    continue
                }
                if arrayKeys.contains(key) { out[key] = parts; continue }
            }
            // Код промокода «007» — строка (в новом условии stringKeys пуст);
            // «1 500» — число 1500, а не строка, которую сервер читал как 1.
            if stringKeys.contains(key) || key == "code" {
                out[key] = v
            } else if let i = Int(v.filter { !$0.isWhitespace }) {
                out[key] = i
            } else if let d = Money.strict(v, maxFraction: 4) {
                out[key] = NSDecimalNumber(decimal: d).doubleValue
            } else {
                out[key] = v
            }
        }
        return out
    }
}

@MainActor
final class PromotionEditViewModel: ObservableObject {
    let promotionId: Int?

    @Published var catalog: PromoCatalog?
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var saving = false
    /// Сама акция загрузилась (а не только каталог). Пока нет — сохранять
    /// нельзя: пустая форма затёрла бы условия и награды.
    @Published var promotionLoaded = false

    // promoSave() поля
    @Published var name = ""
    @Published var descriptionText = ""
    @Published var isActive = true
    /// Акция была включена при загрузке: остановить её — право «Удалять акции» (А396).
    @Published var loadedActive = false
    @Published var hasStart = false
    @Published var startsAt = Date()
    @Published var hasEnd = false
    @Published var endsAt = Date()
    @Published var priority = 0
    @Published var stackable = false
    @Published var audience = "all"
    @Published var audienceValue = ""
    @Published var conditionLogic = "and"
    @Published var usageLimit = ""
    @Published var perClientLimit = ""
    @Published var perDayLimit = ""
    @Published var budgetAmount = ""
    @Published var conditions: [EditablePromoPart] = []
    @Published var rewards: [EditablePromoPart] = []

    init(promotionId: Int?) { self.promotionId = promotionId }

    func load() async {
        state = .loading
        do {
            catalog = try await API.shared.promotionsCatalog()
            if let id = promotionId {
                let p = try await API.shared.promotion(id: id)
                fill(from: p)
                promotionLoaded = true
            }
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func fill(from p: Promotion) {
        name = p.name ?? ""
        descriptionText = p.description ?? ""
        isActive = p.isActive ?? false
        loadedActive = isActive
        if let s = p.startsAt, let d = DateFmt.parse(s) { hasStart = true; startsAt = d }
        if let e = p.endsAt, let d = DateFmt.parse(e) { hasEnd = true; endsAt = d }
        priority = p.priority ?? 0
        stackable = p.stackable ?? false
        audience = p.audience ?? "all"
        audienceValue = p.audienceValue ?? ""
        conditionLogic = p.conditionLogic ?? "and"
        usageLimit = p.usageLimit.map(String.init) ?? ""
        perClientLimit = p.perClientLimit.map(String.init) ?? ""
        perDayLimit = p.perDayLimit.map(String.init) ?? ""
        budgetAmount = p.budgetAmount.map { "\($0)" } ?? ""
        conditions = (p.conditions ?? []).map { editable(from: $0, in: catalog?.conditions ?? []) }
        rewards = (p.rewards ?? []).map { editable(from: $0, in: catalog?.rewards ?? []) }
    }

    private func editable(from part: PromoPart, in types: [PromoCatalogType]) -> EditablePromoPart {
        let meta = types.first(where: { $0.type == part.type })
        var values: [String: String] = [:]
        var stringKeys = Set<String>(), arrayKeys = Set<String>()
        for (k, v) in part.config {
            if let arr = v as? [Any] {
                values[k] = arr.map { "\($0)" }.joined(separator: ",")
                arrayKeys.insert(k)
            } else if let str = v as? String {
                values[k] = str
                stringKeys.insert(k)
            } else {
                values[k] = "\(v)"
            }
        }
        return EditablePromoPart(type: part.type ?? "",
                                 label: meta?.label ?? (part.type ?? ""),
                                 fields: meta?.fields ?? Array(values.keys),
                                 values: values,
                                 stringKeys: stringKeys,
                                 arrayKeys: arrayKeys,
                                 defs: Self.defsByKey(meta))
    }

    /// А57/П-22.13: field_defs по ключу поля (дубли ключей — первый).
    static func defsByKey(_ meta: PromoCatalogType?) -> [String: PromoFieldDef] {
        let defs = (meta?.fieldDefs ?? []).filter { !$0.key.isEmpty }
        return Dictionary(defs.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func addPart(_ meta: PromoCatalogType, isCondition: Bool) {
        let part = EditablePromoPart(type: meta.type ?? "", label: meta.label ?? "",
                                     fields: meta.fields ?? [], defs: Self.defsByKey(meta))
        if isCondition { conditions.append(part) } else { rewards.append(part) }
    }

    func save() async -> Bool {
        // Кнопка гаснет только к следующему кадру: два быстрых тапа запускали
        // два save() — новая акция создавалась дважды.
        guard !saving else { return false }
        error = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { error = "Введите название акции"; return false }
        guard promotionId == nil || promotionLoaded else {
            error = "Акция не загрузилась — обновите экран, иначе сохранятся пустые условия"
            return false
        }
        // Паритет с Android: без награды акция ничего не даёт — сервер такую
        // сохраняет молча, и «пустышка» выглядела рабочей.
        guard !rewards.isEmpty else { error = "Добавьте хотя бы одну награду — без неё акция ничего не даёт"; return false }
        // «1 500» Decimal(string:) читал как 1 — бюджет становился 1 ₽.
        let budget = String(budgetAmount.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            .replacingOccurrences(of: ",", with: ".")
        var budgetValue: Decimal?
        if !budget.isEmpty {
            guard budget.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  budget.filter({ $0 == "." }).count <= 1,
                  let b = Decimal(string: budget) else {
                error = "Проверьте бюджет акции"
                return false
            }
            budgetValue = b
        }
        // Конец раньше начала — акция не сработает ни разу, а сохранялась молча.
        if hasStart && hasEnd && endsAt <= startsAt {
            error = "Дата окончания должна быть позже даты начала"
            return false
        }
        saving = true
        defer { saving = false }
        let serverFmt = DateFormatter()
        serverFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        serverFmt.locale = Locale(identifier: "en_US_POSIX")
        serverFmt.timeZone = TimeZone(identifier: "Europe/Moscow")
        var fields: [String: Any?] = [
            "name": trimmed,
            "description": descriptionText.isEmpty ? nil : descriptionText,
            "is_active": isActive ? 1 : 0,
            "starts_at": hasStart ? serverFmt.string(from: startsAt) : nil,
            "ends_at": hasEnd ? serverFmt.string(from: endsAt) : nil,
            "priority": priority,
            "stackable": stackable ? 1 : 0,
            "audience": audience,
            "audience_value": audienceValue.isEmpty ? nil : audienceValue,
            "condition_logic": conditionLogic,
            "conditions": conditions.map { ["type": $0.type, "config": $0.config] },
            "rewards": rewards.map { ["type": $0.type, "config": $0.config] },
        ]
        // Лимиты: «1 000» раньше не отправлялось вовсе. Пусто при правке —
        // явный null (лимит снят), иначе ключ выпадал и старый лимит оставался.
        for (raw, key, label) in [(usageLimit, "usage_limit", "Лимит использований"),
                                  (perClientLimit, "per_client_limit", "Лимит на клиента"),
                                  (perDayLimit, "per_day_limit", "Лимит в день")] {
            let t = raw.filter { !$0.isWhitespace }
            if t.isEmpty { if promotionId != nil { fields[key] = NSNull() } }
            else if let v = Int(t) { fields[key] = v }
            else { error = "\(label) — целое число"; return false }
        }
        // Бюджет акции — деньги, поэтому строкой (сервер делает (float)):
        // Double печатается с хвостом плавающей точки.
        if let v = budgetValue {
            fields["budget_amount"] = "\(v)"
        } else if promotionId != nil {
            // Стёртый бюджет при правке — явный null, иначе оставался прежний.
            fields["budget_amount"] = NSNull()
        }
        // Правка: снятые даты, пустое описание и аудитория — явный null, иначе
        // nil выпадал из тела, и выключенная «Дата окончания» оставалась.
        if promotionId != nil {
            for key in ["description", "starts_at", "ends_at", "audience_value"] {
                if let v = fields[key], v == nil { fields[key] = NSNull() }
            }
        }
        do {
            try await API.shared.savePromotion(id: promotionId, fields: fields)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct PromotionEditView: View {
    @StateObject private var vm: PromotionEditViewModel
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pickerFor: PartPickerKind?

    enum PartPickerKind: Identifiable {
        case condition, reward
        var id: Int { self == .condition ? 0 : 1 }
    }

    init(promotionId: Int?, onSaved: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: PromotionEditViewModel(promotionId: promotionId))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                mainSection
                scheduleSection
                audienceSection
                partsSection(title: "Условия (когда действует)", parts: $vm.conditions, kind: .condition)
                partsSection(title: "Награды (что даёт)", parts: $vm.rewards, kind: .reward)
                limitsSection
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(vm.promotionId == nil ? "Новая акция" : "Акция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(vm.saving ? "…" : "Сохранить") {
                        Task { if await vm.save() { onSaved(); dismiss() } }
                    }
                    .disabled(vm.saving)
                }
            }
            // Каталог загрузился, а сама акция — нет: раньше ошибка пряталась
            // (список «не пуст»), и показывалась пустая форма.
            .listState(vm.state, isEmpty: vm.catalog == nil || (vm.promotionId != nil && !vm.promotionLoaded),
                       emptyIcon: "megaphone", emptyTitle: "Загрузка…",
                       retry: { Task { await vm.load() } })
            .sheet(item: $pickerFor) { kind in
                PartTypePicker(
                    types: kind == .condition ? (vm.catalog?.conditions ?? []) : (vm.catalog?.rewards ?? []),
                    onPick: { meta in vm.addPart(meta, isCondition: kind == .condition) }
                )
            }
            // Повторный показ (вернулись из выбора товаров и т. п.) не должен
            // перезаливать форму данными сервера поверх правок.
            .task { if vm.catalog == nil || (vm.promotionId != nil && !vm.promotionLoaded) { await vm.load() } }
            // «Сохранить» — вверху, а ошибка («Введите название», отказ сервера)
            // писалась строкой в самом низу длинной формы: казалось, что кнопка
            // не работает. Показываем ещё и окном.
            .errorAlert($vm.error)
        }
        // Длинная форма акции: смахивание вниз у верхнего края закрывало лист и
        // стирало все условия и награды без вопроса. Закрыть — кнопкой «Отмена».
        .interactiveDismissDisabled(vm.saving || vm.state == .loaded)
    }

    private var stopLocked: Bool {
        vm.promotionId != nil && vm.loadedActive && !Session.shared.can("promotions.delete")
    }

    private var mainSection: some View {
        Section("Основное") {
            TextField("Название акции", text: $vm.name)
            TextField("Описание для клиента", text: $vm.descriptionText, axis: .vertical)
                .lineLimit(2...4)
            Toggle("Акция включена", isOn: $vm.isActive).tint(Brand.green)
                .disabled(stopLocked && vm.isActive)
            if stopLocked {
                // А396: остановка действующей акции — право «Удалять акции», иначе 403.
                Text("Остановить действующую акцию (выключить, поставить прошедшую дату окончания или лимит не больше использованного) может владелец или сотрудник с правом «Удалять акции».")
                    .font(.caption).foregroundColor(Brand.muted)
            }
            Toggle("Складывается с другими", isOn: $vm.stackable).tint(Brand.accent)
            Stepper("Приоритет: \(vm.priority)", value: $vm.priority, in: 0...100)
        }
    }

    private var scheduleSection: some View {
        Section("Период действия") {
            Toggle("Дата начала", isOn: $vm.hasStart).tint(Brand.accent)
            if vm.hasStart {
                DatePicker("Начало", selection: $vm.startsAt, displayedComponents: [.date, .hourAndMinute])
            }
            Toggle("Дата окончания", isOn: $vm.hasEnd).tint(Brand.accent)
            if vm.hasEnd {
                DatePicker("Конец", selection: $vm.endsAt, displayedComponents: [.date, .hourAndMinute])
            }
        }
    }

    private var audienceSection: some View {
        Section("Аудитория") {
            Picker("Кому доступна", selection: $vm.audience) {
                ForEach(vm.catalog?.audiences ?? [], id: \.id) { a in
                    Text(a.label ?? a.type ?? "").tag(a.type ?? "all")
                }
            }
            if let meta = vm.catalog?.audiences?.first(where: { $0.type == vm.audience }),
               meta.fields?.isEmpty == false {
                // А57/П-22.13: подпись и варианты — из field_defs сервера, если есть.
                let key = meta.fields?.first ?? ""
                PromoFieldEditor(def: meta.def(for: key), field: key,
                                 fallbackTitle: "Параметр аудитории", text: $vm.audienceValue)
            }
            Picker("Логика условий", selection: $vm.conditionLogic) {
                Text("Все условия (И)").tag("and")
                Text("Любое условие (ИЛИ)").tag("or")
            }
        }
    }

    private func partsSection(title: String, parts: Binding<[EditablePromoPart]>, kind: PartPickerKind) -> some View {
        Section(title) {
            ForEach(parts) { $part in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(part.label).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button(role: .destructive) {
                            // Поле этой строки могло быть в фокусе: удаление в том же
                            // кадре роняло SwiftUI (Index out of range) — сначала фокус.
                            let removeId = part.id
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            DispatchQueue.main.async { parts.wrappedValue.removeAll { $0.id == removeId } }
                        } label: {
                            Image(systemName: "trash").font(.caption)
                        }
                        .tint(Brand.red)
                    }
                    ForEach(part.fields, id: \.self) { field in
                        // А57/П-22.13: подпись/вид ввода/варианты — из field_defs;
                        // без них — прежнее текстовое поле со своей подписью.
                        PromoFieldEditor(def: part.defs[field], field: field, fallbackTitle: nil, text: Binding(
                            get: { part.values[field] ?? "" },
                            set: { $part.wrappedValue.values[field] = $0 }
                        ))
                    }
                }
                .padding(.vertical, 2)
            }
            Button {
                pickerFor = kind
            } label: {
                Label(kind == .condition ? "Добавить условие" : "Добавить награду", systemImage: "plus.circle")
            }
            .tint(Brand.accent)
        }
    }

    private var limitsSection: some View {
        Section("Лимиты (пусто = без лимита)") {
            TextField("Общий лимит применений", text: $vm.usageLimit).keyboardType(.numberPad)
            TextField("Лимит на клиента", text: $vm.perClientLimit).keyboardType(.numberPad)
            TextField("Лимит в сутки", text: $vm.perDayLimit).keyboardType(.numberPad)
            TextField("Бюджет акции, ₽", text: $vm.budgetAmount).keyboardType(.decimalPad)
        }
    }
}

/// А57/П-22.13: поле условия/награды/аудитории по описанию сервера (field_defs):
/// select — выбор из вариантов, weekdays — кнопки дней (хранятся «1,3» и уходят
/// массивом ISO-дней), number — цифровая клавиатура. Без описания — как раньше,
/// текстовое поле со своей подписью.
private struct PromoFieldEditor: View {
    let def: PromoFieldDef?
    let field: String
    let fallbackTitle: String?
    @Binding var text: String

    private var title: String {
        if let l = def?.label, !l.isEmpty { return l }
        return fallbackTitle ?? PromoFieldLabels.label(field)
    }

    private var options: [PromoFieldOption] { (def?.options ?? []).filter { !$0.value.isEmpty } }

    var body: some View {
        if def?.input == "select" && !options.isEmpty {
            Picker(title, selection: $text) {
                Text("Не выбрано").tag("")
                ForEach(options, id: \.value) { o in
                    Text(o.label).tag(o.value)
                }
                // Значение старой акции не из списка — не теряем его при показе.
                if !text.isEmpty && !options.contains(where: { $0.value == text }) {
                    Text(text).tag(text)
                }
            }
            .font(.subheadline)
        } else if def?.input == "weekdays" && !options.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundColor(Brand.muted)
                HStack(spacing: 4) {
                    ForEach(options, id: \.value) { o in
                        let on = selected.contains(o.value)
                        Button {
                            toggle(o.value)
                        } label: {
                            Text(o.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.6)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(on ? Brand.accent : Brand.chip)
                                .foregroundColor(on ? .white : Brand.text)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        // Без стиля кнопка в строке Form срабатывает от тапа по всей строке.
                        .buttonStyle(.borderless)
                    }
                }
            }
        } else {
            TextField(title, text: $text)
                .keyboardType(def?.input == "number" ? .decimalPad : .default)
                .font(.subheadline)
        }
    }

    private var selected: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func toggle(_ value: String) {
        var s = selected
        if let i = s.firstIndex(of: value) { s.remove(at: i) } else { s.append(value) }
        // По порядку дней: 1=Пн … 7=Вс.
        s.sort { (Int($0) ?? 0) < (Int($1) ?? 0) }
        text = s.joined(separator: ",")
    }
}

/// Подписи полей config условий/наград (ключи — из promoCatalog() на сервере).
enum PromoFieldLabels {
    static func label(_ field: String) -> String {
        switch field {
        case "threshold": return "Порог (сумма/кол-во)"
        case "product_id": return "ID товара"
        case "category_id": return "ID категории"
        case "product_ids": return "ID товаров через запятую"
        case "brand": return "Бренд"
        case "every_n": return "Каждый N-й"
        case "days": return "Дни (для ДР — ±дней; для расписания — 1,2,…7)"
        case "from": return "С (ЧЧ:ММ)"
        case "to": return "До (ЧЧ:ММ)"
        case "code": return "Промокод"
        case "min_percent": return "Мин. уровень лояльности, %"
        case "type": return "Тип (referred / referrer)"
        case "scope": return "Область (cart / product / category)"
        case "percent": return "Процент, %"
        case "max_amount": return "Макс. скидка, ₽"
        case "amount": return "Сумма, ₽"
        case "qty": return "Количество"
        case "group": return "Группа"
        case "mode": return "Режим (fixed / percent)"
        case "value": return "Значение"
        case "min_sum": return "Мин. сумма заказа, ₽"
        case "price": return "Цена набора, ₽"
        default: return field
        }
    }
}

/// Выбор типа условия/награды из каталога.
private struct PartTypePicker: View {
    let types: [PromoCatalogType]
    let onPick: (PromoCatalogType) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(types) { meta in
                Button {
                    onPick(meta)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.label ?? meta.type ?? "")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Brand.text)
                        if let fields = meta.fields, !fields.isEmpty {
                            // А57/П-22.13: подписи сервера, если он их прислал.
                            Text(fields.map { (f: String) -> String in
                                if let l = meta.def(for: f)?.label, !l.isEmpty { return l }
                                return PromoFieldLabels.label(f)
                            }.joined(separator: " · "))
                                .font(.caption2).foregroundColor(Brand.muted)
                        }
                    }
                }
                .listRowBackground(Brand.card)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Выберите тип")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
        }
    }
}
