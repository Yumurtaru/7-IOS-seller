import SwiftUI

// ============================================================================
//  Массовая правка выбранных товаров (волна М1 сайта).
//  «Посмотреть изменения» -> dry_run; «Применить» -> тот же запрос с idempotency_key
//  (один ключ на одно нажатие: повтор после обрыва уходит с тем же ключом, новый —
//  после изменения полей или успешного ответа); «Отменить изменения» -> undo.
// ============================================================================

@MainActor
final class BulkEditModel: ObservableObject {
    let ids: [Int]
    let categories: [SellerCategory]
    /// Пачка применена или отменена — перечитать список.
    let onChanged: () -> Void

    @Published var form = BulkForm()
    @Published var busy = false
    @Published var error: String?
    @Published var preview: BulkEditResult?
    @Published var applied: BulkEditResult?
    @Published var undo: BulkEditUndo?
    @Published var history: [BulkEditBatch]?
    @Published var showHistory = false
    @Published var toast: String?

    private var applyKey: String?
    private var applyPrint = ""
    static let showLimit = 300

    init(ids: [Int], categories: [SellerCategory], onChanged: @escaping () -> Void) {
        self.ids = ids
        self.categories = categories
        self.onChanged = onChanged
    }

    func categoryName(_ id: Int) -> String? {
        if id == 0 { return "Без категории" }
        return categories.first(where: { $0.categoryId == id })?.name
    }

    private func changes(canPrice: Bool, canStock: Bool) -> [String: Any]? {
        switch BulkEditLogic.build(form, canPrice: canPrice, canStock: canStock) {
        case .ok(let c):
            return c
        case .bad(let text):
            error = text
            return nil
        }
    }

    func runPreview(canPrice: Bool, canStock: Bool) async {
        guard !busy else { return }
        error = nil
        guard let c = changes(canPrice: canPrice, canStock: canStock) else { return }
        busy = true
        defer { busy = false }
        do {
            preview = try await API.shared.bulkEditPreview(ids: ids, changes: c)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func runApply(canPrice: Bool, canStock: Bool) async {
        guard !busy else { return }
        error = nil
        guard let c = changes(canPrice: canPrice, canStock: canStock) else { return }
        let sig = BulkEditLogic.fingerprint(ids: ids, changes: c)
        if applyKey == nil || applyPrint != sig {
            applyKey = UUID().uuidString
            applyPrint = sig
        }
        let key = applyKey ?? UUID().uuidString
        busy = true
        defer { busy = false }
        do {
            let r = try await API.shared.bulkEditApply(ids: ids, changes: c, key: key)
            applyKey = nil
            applied = r
            preview = nil
            undo = nil
            toast = r.message ?? "Готово"
            onChanged()
        } catch {
            // Ключ остаётся: повтор после обрыва или таймаута уйдёт с ним же.
            self.error = error.localizedDescription
        }
    }

    func runUndo(batchId: Int, fromHistory: Bool) async {
        guard !busy else { return }
        error = nil
        busy = true
        defer { busy = false }
        do {
            let r = try await API.shared.bulkEditUndo(batchId: batchId)
            if !fromHistory { undo = r }
            toast = r.message ?? "Изменения отменены"
            onChanged()
            if fromHistory { history = (try? await API.shared.bulkEditHistory()) ?? history }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func openHistory() async {
        showHistory = true
        error = nil
        do {
            history = try await API.shared.bulkEditHistory()
        } catch {
            self.error = error.localizedDescription
            history = []
        }
    }
}

struct BulkEditView: View {
    @EnvironmentObject var session: Session
    @StateObject private var m: BulkEditModel
    @Environment(\.dismiss) private var dismiss

    init(ids: [Int], categories: [SellerCategory], onChanged: @escaping () -> Void) {
        _m = StateObject(wrappedValue: BulkEditModel(ids: ids, categories: categories, onChanged: onChanged))
    }

    private var canPrice: Bool { session.can("products.price") }
    private var canStock: Bool { session.can("products.create") }

    var body: some View {
        Form {
            if let err = m.error {
                Section { Text(err).foregroundColor(Brand.red) }
            }
            if let t = m.toast {
                Section { Text(t).foregroundColor(Brand.green) }
            }
            content
            if m.busy {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(m.showHistory ? "История правок" : "Изменить: \(m.ids.count)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !m.showHistory && m.applied == nil && m.preview == nil {
                    Button("История") { Task { await m.openHistory() } }
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if m.showHistory {
            historySection
        } else if let ap = m.applied {
            resultSection(ap, title: "Готово")
            appliedActions(ap)
        } else if let pv = m.preview {
            resultSection(pv, title: "Что изменится")
            previewActions(pv)
        } else {
            formSections
            Section {
                Button("Посмотреть изменения") {
                    Task { await m.runPreview(canPrice: canPrice, canStock: canStock) }
                }
                .disabled(m.busy)
            }
        }
    }

    // ── Форма ───────────────────────────────────────────────────────────────

    @ViewBuilder private var formSections: some View {
        Section {
            Text("Меняется только заполненное. Остальные поля остаются как есть.")
                .font(.footnote).foregroundColor(Brand.muted)
        }
        priceSection
        if canPrice { priceOldSection }
        categorySection
        unitSection
        stockSection
        tagsSection
        visibilitySection
    }

    private var priceSection: some View {
        Section("Цена") {
            if canPrice {
                Picker("Действие", selection: $m.form.priceMode) {
                    Text("Не менять").tag("")
                    Text("Изменить на %").tag("percent")
                    Text("Изменить на ₽").tag("delta")
                    Text("Задать").tag("set")
                }
                if !m.form.priceMode.isEmpty {
                    TextField(priceHint, text: $m.form.priceValue)
                        .keyboardType(.numbersAndPunctuation)
                    Picker("Округление", selection: $m.form.rounding) {
                        ForEach(BulkEditLogic.roundings, id: \.0) { r in Text(r.1).tag(r.0) }
                    }
                }
            } else {
                Text("Нет права «Цены» — поля закрыты").foregroundColor(Brand.muted)
            }
        }
    }

    private var priceHint: String {
        switch m.form.priceMode {
        case "percent": return "На сколько %, например 10 или -5"
        case "delta": return "На сколько ₽, например 5 или -2,5"
        default: return "Новая цена, ₽"
        }
    }

    private var priceOldSection: some View {
        Section("Старая цена") {
            Picker("Действие", selection: $m.form.oldMode) {
                Text("Не менять").tag("")
                Text("Очистить").tag("clear")
                Text("Из прежней цены").tag("from_price")
                Text("Задать").tag("set")
            }
            if m.form.oldMode == "set" {
                TextField("Старая цена, ₽", text: $m.form.oldValue).keyboardType(.decimalPad)
            }
            if m.form.oldMode == "from_price" {
                Text("Ставится прежняя цена, если она выше новой. Нужно менять цену выше.")
                    .font(.footnote).foregroundColor(Brand.muted)
            }
            Picker("Розничная цена задана вручную", selection: $m.form.retail) {
                Text("Не менять").tag("")
                Text("Да").tag("1")
                Text("Нет").tag("0")
            }
        }
    }

    private var categorySection: some View {
        Section("Категория") {
            Picker("Категория", selection: categoryBinding) {
                Text("Не менять").tag(-1)
                Text("Без категории").tag(0)
                ForEach(m.categories) { cat in
                    Text(cat.name ?? "—").tag(cat.categoryId ?? 0)
                }
            }
        }
    }

    private var categoryBinding: Binding<Int> {
        Binding(
            get: { m.form.categoryTouched ? m.form.categoryId : -1 },
            set: { v in
                m.form.categoryTouched = v >= 0
                m.form.categoryId = max(v, 0)
            }
        )
    }

    private var unitSection: some View {
        Section("Единица и дробность") {
            TextField("Единица, например кг", text: $m.form.unit)
                .disabled(m.form.unitClear)
            Toggle("Убрать единицу", isOn: $m.form.unitClear)
            Picker("Дробное количество", selection: $m.form.fractional) {
                Text("Не менять").tag("")
                Text("Дробное").tag("1")
                Text("Целое").tag("0")
                Text("Как в категории").tag("cat")
            }
            TextField("Шаг количества, например 0,1", text: $m.form.step)
                .keyboardType(.decimalPad)
                .disabled(m.form.stepCat)
            Toggle("Шаг как в категории", isOn: $m.form.stepCat)
        }
    }

    private var stockSection: some View {
        Section {
            TextField("Мин. остаток", text: $m.form.stockMin).keyboardType(.decimalPad)
            if canStock {
                Picker("Остаток", selection: $m.form.stockMode) {
                    Text("Не менять").tag("")
                    Text("Задать").tag("set")
                    Text("± к остатку").tag("delta")
                }
                if !m.form.stockMode.isEmpty {
                    TextField("Остаток", text: $m.form.stockValue).keyboardType(.numbersAndPunctuation)
                }
            }
        } header: {
            Text("Остатки")
        } footer: {
            if canStock {
                Text("Остаток: только магазин без склада. Иначе меняйте документом инвентаризации.")
            }
        }
    }

    private var tagsSection: some View {
        Section("Метки") {
            TextField("Добавить, через запятую", text: $m.form.tagsAdd)
            TextField("Убрать, через запятую", text: $m.form.tagsRemove)
        }
    }

    private var visibilitySection: some View {
        Section("Видимость и наличие") {
            Picker("Видимость", selection: $m.form.status) {
                Text("Не менять").tag("")
                Text("Показать").tag("active")
                Text("Скрыть").tag("hidden")
            }
            Picker("Наличие", selection: $m.form.avail) {
                Text("Не менять").tag("")
                Text("В наличии").tag("1")
                Text("Нет в наличии").tag("0")
            }
        }
    }

    // ── Предпросмотр / результат ────────────────────────────────────────────

    @ViewBuilder private func resultSection(_ r: BulkEditResult, title: String) -> some View {
        Section(title) {
            Text(r.message ?? "").font(.subheadline.weight(.semibold))
            ForEach(Array(r.items.prefix(BulkEditModel.showLimit).enumerated()), id: \.offset) { _, item in
                itemRow(item)
            }
            let total = r.itemsTotal ?? r.items.count
            if total > BulkEditModel.showLimit {
                Text("Показаны первые \(BulkEditModel.showLimit) из \(total)")
                    .font(.footnote).foregroundColor(Brand.muted)
            }
            if (r.notFound ?? 0) > 0 {
                Text("Не найдено: \(r.notFound ?? 0)").font(.footnote).foregroundColor(Brand.muted)
            }
        }
        if !r.skipped.isEmpty {
            Section("Пропущено") {
                ForEach(Array(r.skipped.prefix(BulkEditModel.showLimit).enumerated()), id: \.offset) { _, n in
                    Text(noteTitle(n) + ": " + (n.reason ?? "")).font(.footnote)
                }
            }
        }
        if !r.warnings.isEmpty {
            Section("Предупреждения") {
                ForEach(Array(r.warnings.prefix(BulkEditModel.showLimit).enumerated()), id: \.offset) { _, n in
                    Text(noteTitle(n) + ": " + (n.text ?? n.reason ?? ""))
                        .font(.footnote).foregroundColor(Brand.amber)
                }
            }
        }
    }

    private func itemTitle(_ name: String?, _ id: Int?) -> String {
        if let n = name, !n.isEmpty { return n }
        return "№" + String(id ?? 0)
    }

    private func keptText(_ k: BulkEditKept) -> String {
        let fields = k.fields.joined(separator: ", ")
        return "не возвращено, менялось позже: " + itemTitle(k.name, k.id) + " (" + fields + ")"
    }

    private func noteTitle(_ n: BulkEditNote) -> String { itemTitle(n.name, n.id) }

    private func itemRow(_ item: BulkEditItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(itemTitle(item.name, item.id)).font(.subheadline.weight(.semibold))
            ForEach(Array(item.changes.enumerated()), id: \.offset) { _, c in
                Text(BulkEditLogic.line(c, categoryName: { m.categoryName($0) }))
                    .font(.footnote).foregroundColor(Brand.muted)
            }
        }
    }

    @ViewBuilder private func previewActions(_ pv: BulkEditResult) -> some View {
        Section {
            Button("Применить") {
                Task { await m.runApply(canPrice: canPrice, canStock: canStock) }
            }
            .disabled(m.busy || (pv.changed ?? pv.items.count) <= 0)
            Button("Изменить поля") {
                m.preview = nil
                m.error = nil
            }
            .disabled(m.busy)
        }
    }

    @ViewBuilder private func appliedActions(_ ap: BulkEditResult) -> some View {
        if let u = m.undo {
            Section("Отмена") {
                Text(u.message ?? "Изменения отменены").font(.subheadline.weight(.semibold))
                ForEach(Array(u.kept.enumerated()), id: \.offset) { _, k in
                    Text(keptText(k))
                        .font(.footnote).foregroundColor(Brand.muted)
                }
            }
        } else if let bid = ap.batchId {
            Section {
                Button("Отменить изменения", role: .destructive) {
                    Task { await m.runUndo(batchId: bid, fromHistory: false) }
                }
                .disabled(m.busy)
            }
        }
        Section {
            Button("Закрыть") { dismiss() }
        }
    }

    // ── История ─────────────────────────────────────────────────────────────

    @ViewBuilder private var historySection: some View {
        if let list = m.history {
            if list.isEmpty {
                Section { Text("Пока нет массовых правок").foregroundColor(Brand.muted) }
            } else {
                ForEach(list) { b in
                    Section { historyRow(b) }
                }
            }
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }
        }
        Section {
            Button("К форме") {
                m.showHistory = false
                m.error = nil
            }
        }
    }

    private func historyRow(_ b: BulkEditBatch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(b.summary ?? "Правка №\(b.id)").font(.subheadline.weight(.semibold))
            Text(historyMeta(b)).font(.footnote).foregroundColor(Brand.muted)
            if b.canUndo == true {
                Button("Отменить") {
                    Task { await m.runUndo(batchId: b.id, fromHistory: true) }
                }
                .disabled(m.busy)
            }
        }
    }

    private func historyMeta(_ b: BulkEditBatch) -> String {
        var parts: [String] = []
        if let d = b.createdAt, !d.isEmpty { parts.append(d) }
        if let u = b.userName, !u.isEmpty { parts.append(u) }
        if let n = b.itemsCount { parts.append("товаров: \(n)") }
        if let u = b.undoneAt, !u.isEmpty { parts.append("отменена \(u)") }
        return parts.joined(separator: " · ")
    }
}
