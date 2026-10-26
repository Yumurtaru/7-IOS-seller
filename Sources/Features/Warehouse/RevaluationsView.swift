import SwiftUI
import Combine

// ============================================================================
//  Волна А99: «Склад» → «Переоценка» — как раздел кабинета
//  (seller/revaluations.php, seller-receipt.js): переоценки по правилу с
//  округлением, предпросмотр «было → станет», применение и отмена (право
//  «Менять цены»), наценки категорий и журнал цен. Тексты — те же, что в
//  кабинете и в приложении для Android.
//
//  Раздел есть только на сервере с волной А99: старый ответит 404 — пункта
//  в «Ещё» нет. Сотруднику нужен раздел «Документы склада» (revaluations →
//  documents в StaffAccess); применять и отменять — право products.price.
// ============================================================================

/// Есть ли «Переоценка» на сервере. 404 (старый сервер), 403 (нет права или у
/// магазина нет склада) — пункта нет. Проверка — раз в 10 минут на организацию.
/// Класс без @MainActor (как PoolFeature): его берут через @ObservedObject … =
/// .shared; состояние меняется только в методах @MainActor.
final class RevalFeature: ObservableObject {
    static let shared = RevalFeature()
    @Published private(set) var available = false

    private var checkedShop: Int?
    private var checkedAt = Date.distantPast
    private var checkingShop: Int?

    private init() {}

    @MainActor
    func refresh(shopId: Int?) async {
        guard let sid = shopId, Session.shared.can("documents") else { available = false; return }
        if checkedShop != sid { available = false }
        if checkedShop == sid && Date().timeIntervalSince(checkedAt) < 600 { return }
        guard checkingShop != sid else { return }
        checkingShop = sid
        defer { if checkingShop == sid { checkingShop = nil } }
        // Самый лёгкий запрос раздела — черновики (обычно их единицы), без повторов.
        let r = await SR.fetch { try await API.shared.revaluations(status: "draft", retries: 0) }
        guard Session.shared.activeShopId == sid else { return }
        switch r {
        case .ok:
            available = true; checkedShop = sid; checkedAt = Date()
        case .hidden:
            available = false; checkedShop = sid; checkedAt = Date()
        default:
            break   // сеть мигнула — спросим в следующий раз
        }
    }
}

private let revalHelp = "help/pereocenka-i-nacenka"

private func revalStatusColor(_ s: String?) -> Color {
    switch s {
    case "applied": return Brand.green
    case "cancelled": return Brand.red
    default: return Brand.amber
    }
}

/// «+12,5 ₽» / «-3 ₽».
private func signedRub(_ v: Decimal) -> String { (v > 0 ? "+" : "") + Money.rub(v) }

private struct RevOpen: Identifiable { let id: Int }

// ── Раздел ──────────────────────────────────────────────────────────────────

struct RevaluationsView: View {
    @StateObject private var listVM = RevalListViewModel()
    /// Наценки держим здесь, а не во вкладке: смена вкладки не стирает несохранённые правки.
    @StateObject private var markupVM = MarkupCategoriesViewModel()
    @State private var tab = "list"
    @State private var openRev: RevOpen?

    /// «Наценки категорий» — только «Полный магазин» и право «Товары» (ручка категорий).
    private var tabs: [(String, String)] {
        var t: [(String, String)] = [("list", "Переоценки")]
        if Session.shared.shopMode == "shop" && Session.shared.can("products") { t.append(("markup", "Наценки категорий")) }
        t.append(("log", "Журнал цен"))
        return t
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tabs, id: \.0) { k, t in
                        FilterChip(title: t, selected: tab == k) { tab = k }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            switch tab {
            case "markup": MarkupCategoriesPane(vm: markupVM)
            case "log": PriceLogPane { openRev = RevOpen(id: $0) }
            default: RevalListPane(vm: listVM) { openRev = RevOpen(id: $0) }
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Переоценка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openRev = RevOpen(id: 0) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Новая переоценка")
            }
        }
        .sheet(item: $openRev, onDismiss: { Task { await listVM.load() } }) { r in
            NavigationStack { RevaluationEditView(revId: r.id) }
        }
    }
}

// ── Список ──────────────────────────────────────────────────────────────────

@MainActor
final class RevalListViewModel: ObservableObject {
    @Published var items: [Revaluation] = []
    @Published var state: LoadState = .idle
    @Published var status: String? { didSet { if status != oldValue { items = []; state = .loading; Task { await load() } } } }
    private var loadGen = 0

    static let statusChips: [(String?, String)] = [(nil, "Все"), ("draft", "Черновики"), ("applied", "Применённые"), ("cancelled", "Отменённые")]

    func load() async {
        loadGen += 1
        let my = loadGen
        if items.isEmpty { state = .loading }
        do {
            let fresh = try await API.shared.revaluations(status: status)
            guard my == loadGen else { return }
            items = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard my == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct RevalListPane: View {
    @ObservedObject var vm: RevalListViewModel
    let open: (Int) -> Void

    var body: some View {
        let isAll = vm.status == nil
        let newAction: (() -> Void)? = isAll ? { open(0) } : nil
        return VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RevalListViewModel.statusChips, id: \.1) { v, t in
                        FilterChip(title: t, selected: vm.status == v) { vm.status = v }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            }
            List {
                if !vm.items.isEmpty {
                    HelpLink(path: revalHelp, title: "Как это работает")
                        .listRowBackground(Color.clear)
                }
                ForEach(vm.items) { d in
                    Button { open(d.id) } label: { row(d) }
                        .buttonStyle(.plain)
                        .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.items.isEmpty, emptyIcon: "tag",
                       emptyTitle: vm.status == nil ? "Переоценок пока нет" : "Нет переоценок с таким статусом",
                       emptySubtitle: vm.status == nil ? "Поднимите или снизьте цены группе товаров по правилу — на процент, на сумму или по наценке на закупку." : nil,
                       retry: { Task { await vm.load() } },
                       emptyActionTitle: isAll ? "Новая переоценка" : nil,
                       emptyAction: newAction)
        }
        .task { if vm.state != .loaded { await vm.load() } }
    }

    private func row(_ d: Revaluation) -> some View {
        let diff = (d.sumNew ?? 0) - (d.sumOld ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Переоценка \(d.number ?? "")").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                    if let b = d.basis, !b.isEmpty { Text(b).font(.caption2).foregroundColor(Brand.muted) }
                    Text(DateFmt.short(d.appliedAt ?? d.createdAt)).font(.caption).foregroundColor(Brand.muted)
                }
                Spacer(minLength: 8)
                StatusBadge(text: d.statusText, color: revalStatusColor(d.status))
            }
            Text("Товаров: \(d.itemsCount ?? 0) · остаток \(Money.rub(d.sumOld)) → \(Money.rub(d.sumNew))")
                .font(.caption).foregroundColor(Brand.text)
            Text("Разница: " + signedRub(diff)).font(.caption)
                .foregroundColor(diff > 0 ? Brand.green : (diff < 0 ? Brand.red : Brand.muted))
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// ── Редактор ────────────────────────────────────────────────────────────────

/// Строка переоценки на экране. newText — текст поля «Станет».
struct RevLineDraft: Identifiable {
    let productId: Int
    let name: String
    let oldPrice: Decimal
    var newText: String
    let cost: Decimal?
    let stockQty: Decimal
    var current: Decimal? = nil
    var barcode: String? = nil

    var id: Int { productId }
    var newValue: Decimal? { Money.strict(newText) }
}

@MainActor
final class RevEditViewModel: ObservableObject {
    @Published var docId: Int?
    @Published var doc: Revaluation?
    @Published var state: LoadState = .idle
    @Published var lines: [RevLineDraft] = []
    @Published var skipped: [RevalPreviewItem] = []
    /// lines | category | supplier | all
    @Published var scope = "category"
    @Published var categoryId = 0
    @Published var supplierId = 0
    @Published var mode = "percent"
    @Published var value = "10"
    @Published var rounding = "integer"
    @Published var inStock = false
    @Published var basis = ""
    @Published var comment = ""
    @Published var categories: [ProductCategory] = []
    @Published var suppliers: [Supplier] = []
    @Published var busy = false
    @Published var notice: String?
    @Published var error: String?
    @Published var dirty = false
    /// Правило последнего «Рассчитать» (или из документа) — уходит при сохранении.
    var rule: [String: Any]?
    /// А102: ключи повтора создания ЭТОГО окна (новый черновик и «Копия»): без срока,
    /// пропадают вместе с окном. Повтор после обрыва уходит с тем же ключом и тем же
    /// телом — сервер отдаёт тот же {id}; новое окно — новый ключ.
    let idemKeys = IdempotencyKeys.form()
    /// Запрос СОЗДАНИЯ в полёте: окно не закрывается («Закрыть», смахивание).
    @Published var creating = false
    /// Ответ на создание не пришёл (обрыв, таймаут, 5xx) — черновик мог создаться. Ключ жив;
    /// всё, что входит в тело, заморожено: новое тело — новый ключ и вторая переоценка.
    @Published var createPending = false
    /// Исход прошлой попытки сервер не знает (idempotency_unknown_outcome) или ответ не
    /// разобрался — ключ сброшен, новое нажатие могло бы создать копию: кнопки закрыты.
    @Published var createLost = false

    var editable: Bool { doc == nil || doc?.isDraft == true }
    /// Строки, правило и поля тела создания можно менять. Пока создание в полёте (creating) —
    /// тоже нельзя: после таймаута повтор ушёл бы с другим телом и новым ключом — вторая переоценка.
    var canEdit: Bool { editable && !creating && !createPending && !createLost }
    /// Секции правила видны (в полёте — видны, но неактивны).
    var ruleVisible: Bool { editable && !createPending && !createLost }
    private var inited = false

    func initLoad(id: Int?) async {
        guard !inited else { return }
        inited = true
        docId = id
        // Справочники для «Что переоценить»: без права их нет — пункты прячем.
        if let cats = try? await API.shared.catalogCategories() {
            categories = cats
            if categoryId == 0 { categoryId = cats.first?.categoryId ?? 0 }
        }
        if let sups = try? await API.shared.suppliers() {
            suppliers = sups.filter { $0.isActive != false }
            if supplierId == 0 { supplierId = suppliers.first?.supplierId ?? 0 }
        }
        if categories.isEmpty && scope == "category" { scope = suppliers.isEmpty ? "all" : "supplier" }
        await load()
    }

    func load() async {
        guard let id = docId else { state = .loaded; return }
        if doc == nil { state = .loading }
        do {
            let d = try await API.shared.revaluation(id: id)
            doc = d
            lines = (d.items ?? []).map {
                RevLineDraft(productId: $0.productId ?? 0, name: $0.name ?? "—", oldPrice: $0.oldPrice ?? 0,
                             newText: ReceiptMath.moneyInput($0.newPrice ?? 0),
                             cost: ($0.cost ?? 0) > 0 ? $0.cost : nil, stockQty: $0.stockQty ?? 0,
                             current: $0.currentPrice, barcode: $0.barcode)
            }
            skipped = []
            if !lines.isEmpty { scope = "lines" }
            if let r = d.rule {
                if let m = r.mode, ReceiptMath.revalModes.contains(where: { $0.0 == m }) { mode = m }
                if let v = r.value { value = ReceiptMath.moneyInput(v) }
                if let rd = r.rounding, ReceiptMath.rounding.contains(where: { $0.0 == rd }) { rounding = rd }
                var obj: [String: Any] = [:]
                if let m = r.mode { obj["mode"] = m }
                if let v = r.value { obj["value"] = NSDecimalNumber(decimal: v) }
                if let rd = r.rounding { obj["rounding"] = rd }
                rule = obj.isEmpty ? nil : obj
            }
            basis = d.basis ?? ""
            comment = d.comment ?? ""
            dirty = false
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func currentRule() -> [String: Any]? {
        let v = ReceiptMath.parse(value, maxFraction: 2, allowNegative: true)
        if mode != "category" && v == nil { return nil }
        return ["mode": mode, "value": NSDecimalNumber(decimal: v ?? 0), "rounding": mode == "category" ? "none" : rounding]
    }

    /// «Рассчитать»: сервер считает новые цены по правилу (как в кабинете).
    func calc() async {
        guard !busy, canEdit else { return }
        guard let r = currentRule() else { error = "Значение — число, например 10 или -5"; return }
        var sc: [String: Any] = ["in_stock": inStock]
        switch scope {
        case "lines":
            guard !lines.isEmpty else { error = "Добавьте товары поиском или выберите категорию"; return }
            sc["product_ids"] = lines.map { $0.productId }
        case "category": sc["category_id"] = categoryId
        case "supplier": sc["supplier_id"] = supplierId
        default: sc["all"] = true
        }
        busy = true; defer { busy = false }
        do {
            let p = try await API.shared.revaluationPreview(rule: r, scope: sc, keepSame: scope == "lines")
            let got: [RevLineDraft] = (p.items ?? []).map {
                RevLineDraft(productId: $0.productId ?? 0, name: $0.name ?? "—", oldPrice: $0.oldPrice ?? 0,
                             newText: ReceiptMath.moneyInput($0.newPrice ?? 0),
                             cost: ($0.cost ?? 0) > 0 ? $0.cost : nil, stockQty: $0.stockQty ?? 0, barcode: $0.barcode)
            }
            if scope == "lines" {
                let by = Dictionary(got.map { ($0.productId, $0) }, uniquingKeysWith: { a, _ in a })
                lines = lines.map { by[$0.productId] ?? $0 }
            } else {
                var out = lines
                var have: [Int: Int] = [:]
                for (i, l) in out.enumerated() { have[l.productId] = i }
                for g in got {
                    if let i = have[g.productId] { out[i] = g } else { have[g.productId] = out.count; out.append(g) }
                }
                lines = out
            }
            skipped = p.skipped ?? []
            rule = r
            dirty = true
            var msg = "Рассчитано: \(got.count)"
            if let u = p.unchanged, u > 0 { msg += ", цена не меняется: \(u)" }
            if !skipped.isEmpty { msg += ", пропущено: \(skipped.count)" }
            if p.truncated == true { msg += " (первые 3000)" }
            notice = msg
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Товар из поиска: цены и остаток — из price-info (нет его — из поиска).
    func add(_ hit: StockSearchItem) async {
        guard canEdit else { return }
        let pid = hit.entityId
        guard !lines.contains(where: { $0.productId == pid }) else { notice = "Уже в списке"; return }
        let inf = try? await API.shared.priceInfo([(kind: "product", id: pid)]).items?.first
        let old = inf?.retail ?? hit.price ?? 0
        // Пока ждали price-info, могло начаться создание (или исход стал неизвестен):
        // тело запроса не трогаем — проверяем ещё раз после await.
        guard canEdit, !lines.contains(where: { $0.productId == pid }) else { return }
        lines.append(RevLineDraft(productId: pid, name: hit.name ?? "—", oldPrice: old, newText: ReceiptMath.moneyInput(old),
                                  cost: inf?.last, stockQty: inf?.stockQty ?? hit.stockQty ?? 0, barcode: hit.barcode))
        dirty = true
    }

    /// Проверка перед сохранением: текст причины или nil.
    var saveBlocker: String? {
        if lines.isEmpty { return "Добавьте товары" }
        if let bad = lines.first(where: { ($0.newValue ?? 0) <= 0 }) { return "Цена должна быть больше нуля: \(bad.name)" }
        return nil
    }

    var changedCount: Int { lines.filter { l in l.newValue.map { !ReceiptMath.samePrice($0, l.oldPrice) } ?? false }.count }
    var belowCostCount: Int { lines.filter { l in if let c = l.cost, c > 0, let n = l.newValue { return n < c }; return false }.count }

    private var bodyItems: [(productId: Int, newPrice: Decimal)] {
        lines.map { (productId: $0.productId, newPrice: ReceiptMath.round($0.newValue ?? 0, 2)) }
    }
    private static let defaultRule: [String: Any] = ["mode": "percent", "value": 10, "rounding": "integer"]

    /// Исход создания по ошибке (паритет с Android и DocumentEditView): неизвестен — ключ
    /// жив, тело заморожено; потерян — кнопки закрыты; иначе — отказ с текстом сервера.
    private func createFailed(_ error: Error, what: String) {
        var unknown = false, lost = false
        var text = error.localizedDescription
        if let e = error as? APIDetailedError {
            text = e.message
            // По HTTP-коду, а не по тексту ответа.
            if e.status >= 500 || e.code == "idempotency_in_progress" { unknown = true }
            else if e.code == "idempotency_unknown_outcome" { lost = true }
        } else if let e = error as? APIError {
            switch e {
            // Ответа нет — ключ повтора остался (postKeyed).
            case .network, .timeout, .http: unknown = true
            // 200 пришёл, но не разобрался — черновик, скорее всего, создан; ключ сброшен.
            case .decoding:
                lost = true
                text = "Черновик, скорее всего, создан"
            default: break
            }
        }
        createPending = unknown
        createLost = lost
        if unknown {
            self.error = "\(text). \(what) создаться — нажмите ещё раз, ничего не меняя: второй переоценки сервер не создаст."
        } else if lost {
            self.error = "\(text). Закройте окно и проверьте список переоценок."
        } else {
            self.error = text
        }
    }

    func save(apply: Bool) async {
        guard !busy, !createLost else { return }
        if let b = saveBlocker { error = b; return }
        busy = true; defer { busy = false }
        let b = basis.trimmingCharacters(in: .whitespaces), c = comment.trimmingCharacters(in: .whitespaces)
        if let id = docId {
            do {
                try await API.shared.updateRevaluation(id: id, items: bodyItems, rule: rule ?? Self.defaultRule, basis: b, comment: c)
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                return
            }
        } else {
            creating = true; defer { creating = false }
            do {
                // А102: ключ окна — повтор с тем же телом вернёт тот же {id}.
                let ack = try await API.shared.createRevaluation(items: bodyItems, rule: rule ?? Self.defaultRule,
                                                                 basis: b, comment: c, keys: idemKeys)
                if let id = ack.id, id > 0 { docId = id }
                createPending = false
            } catch is CancellationError {
                return
            } catch {
                createFailed(error, what: "Черновик мог")
                return
            }
        }
        var msg = "Черновик сохранён"
        if apply, let id = docId {
            do {
                let a = try await API.shared.applyRevaluation(id: id)
                msg = "Переоценка применена: изменено цен \(a.changed ?? 0)"
            } catch {
                // 403 без права «Менять цены», 409 — уже применили в другом окне: текст сервера.
                msg = ""
                self.error = error.localizedDescription
            }
        }
        dirty = false
        if !msg.isEmpty { notice = msg }
        await load()
    }

    func cancelApplied() async {
        guard let id = docId, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let r = try await API.shared.cancelRevaluation(id: id)
            var msg = "Цены возвращены: \(r.restored ?? 0)"
            if let k = r.keptCount, k > 0 { msg += "; не тронуты (цену уже меняли): \(k)" }
            notice = msg
        } catch {
            self.error = error.localizedDescription
        }
        await load()
    }

    /// «Копия» применённой или отменённой — новый черновик с теми же строками. Тело — из
    /// документа (он не редактируется): повтор после обрыва уходит тем же телом с тем же
    /// ключом окна, и сервер отдаёт ту же копию.
    func duplicate() async {
        guard !busy, !createLost, !lines.isEmpty else { return }
        busy = true; defer { busy = false }
        creating = true; defer { creating = false }
        do {
            let ack = try await API.shared.createRevaluation(items: bodyItems, rule: rule,
                                                             basis: basis.trimmingCharacters(in: .whitespaces),
                                                             comment: comment.trimmingCharacters(in: .whitespaces),
                                                             keys: idemKeys)
            createPending = false
            if let id = ack.id, id > 0 {
                docId = id
                doc = nil
                notice = "Создана копия — черновик"
                await load()
            }
        } catch is CancellationError {
        } catch {
            createFailed(error, what: "Копия могла")
        }
    }

    func delete() async -> Bool {
        guard let id = docId, !busy else { return false }
        busy = true; defer { busy = false }
        do {
            try await API.shared.deleteRevaluation(id: id)
            dirty = false
            return true
        } catch {
            self.error = error.localizedDescription
            await load()
            return false
        }
    }
}

private enum RevConfirm { case apply, cancel, delete, leave }

struct RevaluationEditView: View {
    let revId: Int
    @StateObject private var vm = RevEditViewModel()
    @State private var searching = false
    @State private var confirm: RevConfirm?
    @Environment(\.dismiss) private var dismiss

    private var mayPrice: Bool { Session.shared.can("products.price") }

    private var confirmTitle: String {
        switch confirm {
        case .apply: return "Применить переоценку?"
        case .cancel: return "Отменить переоценку?"
        case .delete: return "Удалить черновик?"
        case .leave: return "Выйти без сохранения?"
        case nil: return ""
        }
    }

    private var confirmMessage: String {
        switch confirm {
        case .apply:
            var t = "Изменятся цены \(vm.changedCount) товаров — на сайте, в приложениях и на кассе."
            if vm.belowCostCount > 0 { t += "\n\nВнимание: у \(vm.belowCostCount) товаров новая цена ниже закупочной." }
            return t
        case .cancel: return "Вернуть прежние цены? Товары, цену которых уже поменяли после переоценки, останутся с новой ценой."
        case .delete: return "Цены товаров не изменятся."
        case .leave:
            if vm.createPending || vm.createLost { return "Ответ сервера не пришёл — черновик мог создаться. После выхода проверьте список переоценок." }
            return "Расчёт и правки цен не сохранены. Сохраните черновик, чтобы вернуться к ним позже."
        case nil: return ""
        }
    }

    var body: some View {
        Form {
            if let n = vm.notice {
                Section { Text(n).font(.footnote).foregroundColor(Brand.green) }
                    .listRowBackground(Brand.card)
            }
            if let d = vm.doc {
                Section {
                    HStack {
                        Text("Переоценка \(d.number ?? "")").font(.subheadline.weight(.semibold))
                        Spacer()
                        StatusBadge(text: d.statusText, color: revalStatusColor(d.status))
                    }
                }
                .listRowBackground(Brand.card)
            }
            if vm.createPending || vm.createLost {
                Section {
                    Text(vm.createLost ? "Исход сохранения неизвестен — закройте окно и проверьте список переоценок"
                         : (vm.editable ? "Ждём ответ сервера — нажмите «Сохранить черновик» или «Применить» ещё раз, ничего не меняя"
                            : "Ждём ответ сервера — нажмите «Копия» ещё раз"))
                        .font(.footnote).foregroundColor(Brand.amber)
                }
                .listRowBackground(Brand.card)
            }
            // Исход создания неизвестен — правило и строки заморожены (тело запроса то же).
            if vm.ruleVisible { ruleSections.disabled(!vm.canEdit) }
            if !vm.skipped.isEmpty {
                Section {
                    DisclosureGroup("Пропущено товаров: \(vm.skipped.count)") {
                        ForEach(Array(vm.skipped.prefix(50).enumerated()), id: \.offset) { _, x in
                            Text("\(x.name ?? "—") — \(x.reason ?? "")").font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                    .foregroundColor(Brand.amber)
                }
                .listRowBackground(Brand.card)
            }
            Section("Товары") {
                if vm.lines.isEmpty {
                    Text("Выберите, что и как переоценить, и нажмите «Рассчитать» — или добавьте товары поиском")
                        .font(.footnote).foregroundColor(Brand.muted)
                }
                // Убрать строку можно только у черновика (у применённой — нельзя).
                ForEach($vm.lines) { $line in lineRow($line) }
                    .onDelete(perform: vm.canEdit ? { offsets in
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        let ids = Set(offsets.map { vm.lines[$0].id })
                        DispatchQueue.main.async { vm.lines.removeAll { ids.contains($0.id) }; vm.dirty = true }
                    } : nil)
            }
            .listRowBackground(Brand.card)
            Section {
                TextField("Основание, например «повышение цен поставщика»", text: Binding(
                    get: { vm.basis }, set: { vm.basis = String($0.prefix(255)); vm.dirty = true }))
                    .disabled(!vm.canEdit)
                TextField("Комментарий", text: Binding(
                    get: { vm.comment }, set: { vm.comment = String($0.prefix(500)); vm.dirty = true }))
                    .disabled(!vm.canEdit)
            }
            .listRowBackground(Brand.card)
            totalsSection
            actionsSection
            Section { HelpLink(path: revalHelp, title: "Как это работает") }
                .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(vm.doc == nil ? "Новая переоценка" : "Переоценка")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Закрыть") {
                    if vm.dirty && vm.editable { confirm = .leave } else { dismiss() }
                }
                // А102: пока создание уходит — не закрываем (ключ повтора живёт с окном).
                .disabled(vm.creating)
            }
        }
        .interactiveDismissDisabled(vm.creating || (vm.dirty && vm.editable))
        .overlay { if vm.state == .loading && vm.doc == nil { ProgressView() } }
        .task { await vm.initLoad(id: revId > 0 ? revId : nil) }
        .sheet(isPresented: $searching) {
            StockSearchSheet(warehouseId: nil, productsOnly: true) { hit in
                searching = false
                Task { await vm.add(hit) }
            }
        }
        .alert(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            switch confirm {
            case .apply:
                Button("Применить") { confirm = nil; Task { await vm.save(apply: true) } }
                Button("Вернуться", role: .cancel) { confirm = nil }
            case .cancel:
                Button("Отменить переоценку", role: .destructive) { confirm = nil; Task { await vm.cancelApplied() } }
                Button("Закрыть", role: .cancel) { confirm = nil }
            case .delete:
                Button("Удалить", role: .destructive) {
                    confirm = nil
                    Task { if await vm.delete() { dismiss() } }
                }
                Button("Отмена", role: .cancel) { confirm = nil }
            case .leave:
                Button("Выйти", role: .destructive) { confirm = nil; dismiss() }
                Button("Остаться", role: .cancel) { confirm = nil }
            case nil:
                Button("Понятно", role: .cancel) {}
            }
        } message: { Text(confirmMessage) }
        .errorAlert($vm.error)
    }

    @ViewBuilder
    private var ruleSections: some View {
        Section("Что переоценить") {
            Picker("Охват", selection: $vm.scope) {
                Text("Товары в списке").tag("lines")
                if !vm.categories.isEmpty { Text("Категорию").tag("category") }
                if !vm.suppliers.isEmpty { Text("Товары поставщика").tag("supplier") }
                Text("Все товары").tag("all")
            }
            .pickerStyle(.menu)
            if vm.scope == "category" {
                Picker("Категория", selection: $vm.categoryId) {
                    ForEach(vm.categories) { c in
                        Text(((c.parentId ?? 0) > 0 ? "└ " : "") + (c.name ?? "—")).tag(c.categoryId)
                    }
                }
                .pickerStyle(.menu)
            }
            if vm.scope == "supplier" {
                Picker("Поставщик", selection: $vm.supplierId) {
                    ForEach(vm.suppliers) { s in Text(s.name ?? "—").tag(s.supplierId ?? 0) }
                }
                .pickerStyle(.menu)
            }
            Toggle("только с остатком", isOn: $vm.inStock)
        }
        .listRowBackground(Brand.card)
        Section("Как") {
            Picker("Правило", selection: $vm.mode) {
                // «По наценке категории» — только «Полный магазин», как в кабинете.
                ForEach(ReceiptMath.revalModes.filter { $0.0 != "category" || Session.shared.shopMode == "shop" }, id: \.0) { v, t in
                    Text(t).tag(v)
                }
            }
            .pickerStyle(.menu)
            if vm.mode != "category" {
                VStack(alignment: .leading, spacing: 2) {
                    Text(valueTitle).font(.caption2).foregroundColor(Brand.muted)
                    TextField("10", text: $vm.value)
                        .keyboardType(.numbersAndPunctuation)
                        .textFieldStyle(.roundedBorder)
                }
                Picker("Округление", selection: $vm.rounding) {
                    ForEach(ReceiptMath.rounding, id: \.0) { v, t in Text(t).tag(v) }
                }
                .pickerStyle(.menu)
            }
            Button { Task { await vm.calc() } } label: { Label("Рассчитать", systemImage: "function") }
                .disabled(vm.busy)
            // Поиск товаров — stock/search. С сайта А100 (П-51) он открыт праву «Склад»
            // ИЛИ «Документы склада»; старый сервер «Документам» ответит 403 — тогда
            // окно поиска покажет текст сервера.
            if Session.shared.can("warehouse") || Session.shared.can("documents") {
                Button { searching = true } label: { Label("Добавить товар", systemImage: "plus.circle") }
                    .disabled(vm.busy)
            }
        }
        .listRowBackground(Brand.card)
    }

    private var valueTitle: String {
        switch vm.mode {
        case "delta": return "Сумма, ₽ (минус — снизить)"
        case "set": return "Цена, ₽"
        case "markup_cost": return "Наценка на закупку, %"
        default: return "Процент (минус — снизить)"
        }
    }

    /// «остаток 5 · 4600000000000».
    private func lineMeta(_ l: RevLineDraft) -> String {
        var t = "остаток " + QtyFmt.qty(l.stockQty)
        if let b = l.barcode, !b.isEmpty { t += " · " + b }
        return t
    }

    /// «Изменение: +10 ₽ (+8,3%) · наценка +30%».
    private func lineChange(_ l: RevLineDraft) -> (String, Color) {
        let n = l.newValue ?? 0
        let d = n - l.oldPrice
        var t = "Изменение: " + signedRub(d)
        if let p = ReceiptMath.changePercent(n, l.oldPrice) { t += " (" + ReceiptMath.pct(p) + ")" }
        let mk: Decimal? = l.cost.flatMap { ReceiptMath.markupPercent(n, $0) }
        t += " · наценка " + (mk.map { ReceiptMath.pct($0) } ?? "—")
        let negativeMarkup = (mk ?? 0) < 0
        let color: Color
        if negativeMarkup || d > 0 { color = Brand.red } else if d < 0 { color = Brand.green } else { color = Brand.muted }
        return (t, color)
    }

    private func lineRow(_ line: Binding<RevLineDraft>) -> some View {
        let l = line.wrappedValue
        let n: Decimal = l.newValue ?? 0
        let change = lineChange(l)
        let costText: String = l.cost.map { Money.rub($0) } ?? "—"
        return VStack(alignment: .leading, spacing: 4) {
            Text(l.name).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
            Text(lineMeta(l)).font(.caption2).foregroundColor(Brand.muted)
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Закупка: " + costText).font(.caption)
                    Text("Было: " + Money.rub(l.oldPrice)).font(.caption)
                    if let doc = vm.doc, !doc.isDraft, let cur = l.current {
                        Text("Сейчас: " + Money.rub(cur)).font(.caption).foregroundColor(Brand.muted)
                    }
                }
                Spacer()
                if vm.canEdit {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Станет, ₽").font(.caption2).foregroundColor(Brand.muted)
                        TextField("0", text: Binding(
                            get: { line.wrappedValue.newText },
                            set: { line.wrappedValue.newText = $0.filter { $0.isNumber || $0 == "," || $0 == "." }; vm.dirty = true }
                        ))
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    }
                } else {
                    Text("Станет: " + Money.rub(n)).font(.subheadline.weight(.bold))
                }
            }
            Text(change.0).font(.caption2).foregroundColor(change.1)
        }
        .padding(.vertical, 2)
    }

    private var totalsSection: some View {
        var up = 0, down = 0
        var so: Decimal = 0, sn: Decimal = 0
        for l in vm.lines {
            let n = l.newValue ?? 0
            if n > l.oldPrice { up += 1 } else if n < l.oldPrice { down += 1 }
            let q = max(0, l.stockQty)
            so += q * l.oldPrice; sn += q * n
        }
        let diff = sn - so
        return Section {
            InfoRow(label: "Товаров", value: "\(vm.lines.count)")
            InfoRow(label: "Повышение / снижение", value: "\(up) / \(down)")
            InfoRow(label: "Остаток в рознице", value: Money.rub(so) + " → " + Money.rub(sn))
            HStack {
                Text("Сумма переоценки").font(.subheadline).foregroundColor(Brand.muted)
                Spacer()
                Text(signedRub(diff)).font(.subheadline.weight(.semibold)).foregroundColor(diff >= 0 ? Brand.green : Brand.red)
            }
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if vm.editable {
                // createLost: исход прошлой попытки неизвестен, ключ сброшен — новое нажатие дало бы копию.
                Button("Сохранить черновик") { Task { await vm.save(apply: false) } }
                    .disabled(vm.busy || vm.createLost)
                if mayPrice {
                    Button("Применить") {
                        if let b = vm.saveBlocker { vm.error = b } else { confirm = .apply }
                    }
                    .foregroundColor(Brand.green)
                    .disabled(vm.busy || vm.createLost)
                } else {
                    Label("Применяет сотрудник с правом «Менять цены»", systemImage: "lock")
                        .font(.footnote).foregroundColor(Brand.amber)
                }
            }
            if let d = vm.doc {
                if d.isApplied && mayPrice {
                    Button("Отменить переоценку", role: .destructive) { confirm = .cancel }
                        .disabled(vm.busy)
                }
                if !d.isDraft && !vm.lines.isEmpty {
                    Button("Копия") { Task { await vm.duplicate() } }
                        .disabled(vm.busy || vm.createLost)
                }
                if d.isDraft {
                    Button("Удалить", role: .destructive) { confirm = .delete }
                        .disabled(vm.busy)
                }
            }
        }
        .listRowBackground(Brand.card)
    }
}

// ── Наценки категорий ───────────────────────────────────────────────────────

@MainActor
final class MarkupCategoriesViewModel: ObservableObject {
    @Published var cats: [ProductCategory] = []
    @Published var rows: [Int: (text: String, rounding: String)] = [:]
    @Published var state: LoadState = .idle
    @Published var saving = false
    @Published var notice: String?
    @Published var error: String?

    func load() async {
        if cats.isEmpty { state = .loading }
        do {
            let list = try await API.shared.catalogCategories()
            cats = list
            var r: [Int: (text: String, rounding: String)] = [:]
            for c in list {
                let mode = ["integer", "0.10", "0.50"].contains(c.roundingMode ?? "") ? (c.roundingMode ?? "integer") : "integer"
                r[c.categoryId] = (c.markupPercent.map { ReceiptMath.moneyInput($0) } ?? "", mode)
            }
            rows = r
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func fillAll(_ text: String, _ rounding: String) {
        for c in cats { rows[c.categoryId] = (text, rounding) }
    }

    /// Сохранить изменённые строки — по одной, как кабинет.
    func save() async {
        guard !saving else { return }
        saving = true; defer { saving = false }
        var n = 0, fail = 0
        var firstErr: String?
        for c in cats {
            guard let row = rows[c.categoryId] else { continue }
            let t = row.text.trimmingCharacters(in: .whitespaces)
            let parsed = t.isEmpty ? nil : Money.strict(t)
            if !t.isEmpty && parsed == nil { fail += 1; if firstErr == nil { firstErr = "Наценка «\(c.name ?? "")»: число, например 30" }; continue }
            let same: Bool = {
                switch (parsed, c.markupPercent) {
                case (nil, nil): return true
                case let (a?, b?): return a == b
                default: return false
                }
            }()
            if same && (c.roundingMode ?? "integer") == row.rounding { continue }
            do {
                try await API.shared.updateCategoryMarkup(id: c.categoryId, markup: parsed, rounding: row.rounding)
                n += 1
            } catch {
                fail += 1
                if firstErr == nil { firstErr = error.localizedDescription }
            }
        }
        if fail > 0 {
            error = "Сохранено: \(n), ошибок: \(fail)" + (firstErr.map { ". " + $0 } ?? "")
        } else {
            notice = n > 0 ? "Наценки сохранены: \(n)" : "Изменений нет"
        }
        // Перечитываем с сервера: наценка и округление — как их сохранил сервер.
        if n > 0 {
            let keep = rows
            await load()
            if fail > 0 { rows = keep }   // неудачные строки не теряем
        }
    }
}

private struct MarkupCategoriesPane: View {
    @ObservedObject var vm: MarkupCategoriesViewModel
    @State private var all = ""
    @State private var allRounding = "integer"

    var body: some View {
        List {
            Section {
                Text("Наценка категории работает при проведении прихода: розничная цена = закупочная × (1 + наценка), с округлением. Пустое поле — приход розничную цену не меняет. Товарам с ценой, заданной вручную, приход цену не меняет.")
                    .font(.footnote).foregroundColor(Brand.muted)
                if let n = vm.notice { Text(n).font(.footnote).foregroundColor(Brand.green) }
            }
            .listRowBackground(Brand.card)
            if !vm.cats.isEmpty {
                Section("Всем категориям") {
                    HStack {
                        TextField("%", text: $all).keyboardType(.decimalPad).textFieldStyle(.roundedBorder).frame(width: 90)
                        Picker("", selection: $allRounding) {
                            ForEach(ReceiptMath.categoryRounding, id: \.0) { v, t in Text(t).tag(v) }
                        }
                        .pickerStyle(.menu)
                        Spacer()
                        Button("Заполнить") { vm.fillAll(all, allRounding) }.buttonStyle(.borderless)
                    }
                    Text("потом «Сохранить»").font(.caption2).foregroundColor(Brand.muted)
                }
                .listRowBackground(Brand.card)
                Section {
                    ForEach(vm.cats) { c in markupRow(c) }
                }
                .listRowBackground(Brand.card)
                Section {
                    Button("Сохранить") { Task { await vm.save() } }
                        .disabled(vm.saving)
                    HelpLink(path: revalHelp, title: "Как это работает")
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.cats.isEmpty, emptyIcon: "folder",
                   emptyTitle: "Категорий пока нет", emptySubtitle: "Заведите их в разделе «Категории»",
                   retry: { Task { await vm.load() } })
        .task { if vm.state != .loaded { await vm.load() } }
        .errorAlert($vm.error)
    }

    private func markupRow(_ c: ProductCategory) -> some View {
        let row = vm.rows[c.categoryId] ?? (text: "", rounding: "integer")
        let v = row.text.isEmpty ? nil : Money.strict(row.text)
        let example: String = row.text.isEmpty ? "цена не меняется"
            : (v.map { "закупка 100 ₽ → " + Money.rub(ReceiptMath.retailFromPurchase(100, markup: $0, mode: row.rounding)) } ?? "проверьте число")
        return VStack(alignment: .leading, spacing: 6) {
            Text(((c.parentId ?? 0) > 0 ? "└ " : "") + (c.name ?? "—")).font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField("нет", text: Binding(
                    get: { vm.rows[c.categoryId]?.text ?? "" },
                    set: { vm.rows[c.categoryId] = ($0.filter { $0.isNumber || $0 == "," || $0 == "." }, vm.rows[c.categoryId]?.rounding ?? "integer") }
                ))
                .keyboardType(.decimalPad)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                Text("%").foregroundColor(Brand.muted)
                Picker("", selection: Binding(
                    get: { vm.rows[c.categoryId]?.rounding ?? "integer" },
                    set: { vm.rows[c.categoryId] = (vm.rows[c.categoryId]?.text ?? "", $0) }
                )) {
                    ForEach(ReceiptMath.categoryRounding, id: \.0) { v, t in Text(t).tag(v) }
                }
                .pickerStyle(.menu)
            }
            Text(example).font(.caption2).foregroundColor(Brand.muted)
        }
        .padding(.vertical, 2)
    }
}

// ── Журнал цен ──────────────────────────────────────────────────────────────

private struct PriceLogPane: View {
    let open: (Int) -> Void
    @State private var query = ""
    @State private var rows: [PriceLogRow] = []
    @State private var state: LoadState = .idle
    @State private var task: Task<Void, Never>?

    var body: some View {
        List {
            Section {
                TextField("Товар", text: $query)
                    .textInputAutocapitalization(.never)
            }
            .listRowBackground(Brand.card)
            ForEach(rows) { x in
                let isReval = x.documentId != nil && (x.source ?? "").hasPrefix("revaluation")
                Button { if isReval, let id = x.documentId { open(id) } } label: { row(x) }
                    .buttonStyle(.plain)
                    .disabled(!isReval)
                    .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .onChange(of: query) { _ in schedule() }
        .refreshable { await load() }
        .listState(state, isEmpty: rows.isEmpty, emptyIcon: "clock.arrow.circlepath",
                   emptyTitle: query.trimmingCharacters(in: .whitespaces).count >= 2 ? "Ничего не найдено" : "Изменений цен пока нет",
                   emptySubtitle: query.trimmingCharacters(in: .whitespaces).count >= 2 ? nil : "Сюда попадают цены, изменённые приходом и переоценкой.",
                   retry: { Task { await load() } })
        .task { if state != .loaded { await load() } }
    }

    private func schedule() {
        task?.cancel()
        task = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private func load() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        if rows.isEmpty { state = .loading }
        do {
            let r = try await API.shared.priceLog(q: q.count >= 2 ? q : nil)
            guard q == query.trimmingCharacters(in: .whitespaces) else { return }
            rows = r
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func row(_ x: PriceLogRow) -> some View {
        let o = x.oldPrice ?? 0, n = x.newPrice ?? 0
        let ch = ReceiptMath.changePercent(n, o)
        var meta = [DateFmt.short(x.createdAt)]
        if let s = x.sourceLabel ?? x.source { meta.append(s) }
        if let u = x.user, !u.isEmpty { meta.append(u) }
        return VStack(alignment: .leading, spacing: 3) {
            Text(x.name ?? "—").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
            HStack(spacing: 6) {
                Text(Money.rub(o) + " →").font(.caption).foregroundColor(Brand.text)
                Text(Money.rub(n)).font(.caption.weight(.bold)).foregroundColor(Brand.text)
                if let ch { Text(ReceiptMath.pct(ch)).font(.caption).foregroundColor(n > o ? Brand.red : Brand.green) }
            }
            Text(meta.joined(separator: " · ")).font(.caption2).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
