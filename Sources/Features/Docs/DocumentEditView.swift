import SwiftUI

// ============================================================================
//  Создание складского документа.
//
//  Что зависит от типа (ровно как на сервере):
//   • перемещение — обязателен склад-получатель;
//   • списание — у каждой строки причина;
//   • инвентаризация — две колонки количества: план (учёт) и факт (пересчёт);
//   • приход и возврат — можно указать поставщика.
//
//  «Создать и провести» — это флаг post у той же ручки: сервер сам проведёт
//  документ сразу после создания, отдельного запроса не нужно.
// ============================================================================

@MainActor
final class DocumentEditViewModel: ObservableObject {
    let type: DocType

    @Published var items: [DocItemDraft] = []
    @Published var warehouses: [WarehouseInfo] = []
    @Published var suppliers: [Supplier] = []
    @Published var warehouseId: Int?
    @Published var warehouseToId: Int?
    @Published var supplierId: Int?
    @Published var comment = ""
    @Published var saving = false
    @Published var error: String?
    /// Паритет с Android: «Создать и провести» сохранило черновик, а провести не
    /// вышло (сервер: 403 «сохранён черновиком» / 409 «не удалось провести»).
    /// Повторное «Готово» создало бы второй документ — кнопку закрываем.
    @Published var draftSaved = false
    /// Паритет с Android: инвентаризация — «По учёту» взят из остатка склада на
    /// момент добавления строки; сменили склад — у старых строк он прежний.
    @Published var planStale = false
    /// Ответ на последнюю отправку не пришёл (обрыв, таймаут, 5xx): документ мог создаться.
    /// Ключ повтора (postKeyed) — по отпечатку тела, а в теле есть post. Сервер
    /// (apiIdemReplay) сверяет повтор по телу: «Черновик» после упавшего «Провести»
    /// получил бы новый ключ и второй документ. Пока исход неизвестен — только то же
    /// действие (true — «Создать и провести», false — «Сохранить черновик»; nil — известен).
    @Published var pendingPost: Bool?
    /// Ключи повтора ЭТОГО окна документа: без срока (общие живут 5 минут), пропадают
    /// вместе с окном. «Нажмите ещё раз» через 6 минут после обрыва уходит с тем же ключом.
    let idemKeys = IdempotencyKeys.form()
    /// 403 на список складов / поставщиков: у сотрудника только «Документы склада».
    /// Это не сбой — пишем подсказку, без алерта «закройте и откройте снова».
    /// С сайта А102 (П-54 №1) оба GET открыты и «Документам склада», поставщики — коротким
    /// списком (id, shop_id, name, inn, is_active; Supplier терпит отсутствие остальных
    /// полей). «Нового поставщика» в документе нет — создание только разделом «Поставщики».
    /// 403 здесь — старый сервер.
    @Published var whNoAccess = false
    @Published var supNoAccess = false

    // ── А99: приёмка по накладной ────────────────────────────────────────
    // Пробный price-info с пустым списком: новый сервер отвечает режимом магазина
    // и правами (retail_on_income, may_price). Право в приложении не проверяем — решает
    // сервер: с сайта А100 (П-51) price-info открыт праву «Склад» ИЛИ «Документы склада»,
    // и сотрудник только с «Документами» тоже видит «было N ₽» и наценку.
    // Пока rcv == nil (проба идёт; нет связи, таймаут, 429/5xx; старый сервер 404, отказ
    // 403), режим магазина НЕИЗВЕСТЕН. В «Полном магазине» проведение прихода
    // (seller_warehouse.php → applyRetailOnIncome) считает розницу от закупки строки,
    // поэтому розница из поиска, подставленная в закупку, поднимала розничную цену на
    // наценку категории. Теперь: товару закупку не подставляем, без закупки не проводим,
    // перед проведением спрашиваем; пробу повторяем при добавлении строки и перед «Провести».
    @Published var rcv: PriceInfoResponse?
    @Published var probeBusy = false
    @Published var infos: [String: PriceInfoItem] = [:]
    @Published var supplierDocNo = ""
    @Published var supplierDocDate = Date()
    @Published var bulkMarkup = ""
    @Published var bulkRounding = "integer"
    @Published var note: String?
    /// Сведения не пришли (нет связи, сбой) — строку помечаем и даём «Повторить»:
    /// молча оставлять её нельзя, иначе закупка в ней — розничная цена из поиска.
    @Published var infoFailed: Set<String> = []
    @Published var infoLoading: Set<String> = []

    init(type: DocType) { self.type = type }

    var isIncome: Bool { type == .income }
    /// Номер и дата накладной — только на сервере с волной А99 (иначе их молча не сохранить).
    var docFieldsOn: Bool { isIncome && (rcv != nil || RevalFeature.shared.available) }
    var retailOn: Bool { rcv?.retailOnIncome == true }
    var mayPrice: Bool { rcv?.mayPrice == true && Session.shared.can("products.price") }

    func info(_ d: DocItemDraft) -> PriceInfoItem? { infos[d.kind + ":\(d.entityId)"] }

    func retail(_ d: DocItemDraft) -> ReceiptMath.Retail {
        let inf = info(d)
        let manual = d.retailText.isEmpty ? nil : Money.strict(d.retailText)
        return ReceiptMath.retailOf(isProduct: d.kind != "ingredient", retailOn: retailOn, mayPrice: mayPrice,
                                    hasInfo: inf != nil, old: inf?.retail, retailManual: inf?.retailManual == true,
                                    markup: inf?.markupPercent, roundingMode: inf?.roundingMode,
                                    manual: manual, purchase: d.price)
    }

    func loadReceiptProbe() async {
        guard isIncome, rcv == nil, !probeBusy else { return }
        probeBusy = true
        let r = try? await API.shared.priceInfo([])
        probeBusy = false
        if rcv == nil { rcv = r }
        // Строки, добавленные до ответа пробы, получают сведения сразу.
        if rcv != nil { await loadInfo(for: items.filter { info($0) == nil }) }
    }

    /// Приход, режим магазина неизвестен (проба не ответила).
    var modeUnknown: Bool { isIncome && rcv == nil }

    private func key(_ d: DocItemDraft) -> String { d.kind + ":\(d.entityId)" }

    /// Строка прихода без сведений о цене — её нет в наценке и в рознице.
    func noInfo(_ d: DocItemDraft) -> Bool { isIncome && rcv != nil && info(d) == nil }
    func isInfoLoading(_ d: DocItemDraft) -> Bool { infoLoading.contains(key(d)) }

    /// Сведения по строкам одним запросом; не пришедшие — в infoFailed.
    func loadInfo(for list: [DocItemDraft]) async {
        guard rcv != nil else { return }
        for d in list { if let inf = infos[key(d)] { applyDefaultPrice(key: key(d), inf) } }
        var seen = Set<String>()
        let need = list.filter { infos[key($0)] == nil && !infoLoading.contains(key($0)) && seen.insert(key($0)).inserted }
        guard !need.isEmpty else { return }
        let keys = Set(need.map { key($0) })
        infoLoading.formUnion(keys)
        let r = try? await API.shared.priceInfo(need.map { (kind: $0.kind, id: $0.entityId) })
        infoLoading.subtract(keys)
        for it in r?.items ?? [] { infos[it.key] = it }
        let got = keys.filter { infos[$0] != nil }
        infoFailed.subtract(got)
        infoFailed.formUnion(keys.subtracting(got))
        for k in got { if let inf = infos[k] { applyDefaultPrice(key: k, inf) } }
    }

    /// Закупка по умолчанию — как в кабинете: прошлый приход, у ингредиента — средняя
    /// себестоимость; у товара без приходов — пусто (а не розничная цена из поиска).
    private func applyDefaultPrice(key: String, _ inf: PriceInfoItem) {
        // Исход отправки неизвестен — тело не меняем, иначе повтор ушёл бы с новым ключом.
        guard pendingPost == nil,
              let idx = items.firstIndex(where: { $0.kind + ":\($0.entityId)" == key }), !items[idx].priceTouched else { return }
        if let last = inf.last {
            items[idx].price = last
        } else if !inf.isProduct, let avg = inf.avgCost, avg > 0 {
            items[idx].price = avg
        } else if inf.isProduct {
            items[idx].price = 0
        }
        items[idx].priceTouched = true
    }

    func loadInfo(kind: String, id: Int) async {
        guard let d = items.first(where: { $0.kind == kind && $0.entityId == id }) else { return }
        await loadInfo(for: [d])
    }

    /// Наценка в строке: розница = закупка × (1 + наценка) с округлением категории.
    func setMarkup(id: UUID, text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let t = text.filter { $0.isNumber || $0 == "," || $0 == "." }
        items[i].markupText = t
        let m = t.isEmpty ? nil : ReceiptMath.parse(t, maxFraction: 3)
        let mode = info(items[i])?.roundingMode ?? "integer"
        if let m, let r = ReceiptMath.byMarkup(items[i].price, m, mode) {
            items[i].retailText = ReceiptMath.moneyInput(r)
        } else {
            items[i].retailText = ""
        }
    }

    func setRetail(id: UUID, text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].retailText = text.filter { $0.isNumber || $0 == "," || $0 == "." }
        items[i].markupText = nil
    }

    /// «Наценка для всех товаров» — с выбранным округлением.
    func applyBulk() {
        guard let m = ReceiptMath.parse(bulkMarkup, maxFraction: 3) else { note = "Укажите наценку, %"; return }
        var n = 0
        // Только строки со сведениями сервера: без них закупка может быть розничной
        // ценой из поиска, и наценка дала бы ложную «ручную» цену.
        for i in items.indices where items[i].kind != "ingredient" && info(items[i]) != nil {
            if let r = ReceiptMath.byMarkup(items[i].price, m, bulkRounding) {
                items[i].retailText = ReceiptMath.moneyInput(r)
                items[i].markupText = nil
                n += 1
            }
        }
        note = "Наценка \(ReceiptMath.oneDecimal(m))% применена к \(n) товарам"
    }

    /// «По категориям» — розница снова по наценке категорий.
    func resetBulk() {
        for i in items.indices { items[i].retailText = ""; items[i].markupText = nil }
        note = "Розничные цены — по наценке категорий"
    }

    /// Розницу передаём, только если её задали вручную (или наценкой) и она не совпала
    /// с расчётом по категории. Без права «Менять цены» и на старом сервере — никогда.
    func manualRetailOut(_ d: DocItemDraft) -> Decimal? {
        guard rcv != nil, retailOn, mayPrice, d.kind != "ingredient", info(d) != nil else { return nil }
        let r = retail(d)
        guard r.src == .manual, let price = r.price else { return nil }
        let inf = info(d)
        if ReceiptMath.sameAsAuto(retailManual: inf?.retailManual == true, markup: inf?.markupPercent,
                                  roundingMode: inf?.roundingMode, purchase: d.price, price: price) { return nil }
        return ReceiptMath.round(price, 2)
    }

    struct IncomeTotals { var sum: Decimal = 0; var rSum: Decimal = 0; var markup: Decimal?; var changed = 0 }

    /// Итоги прихода — как подвал экрана приёмки в кабинете.
    var incomeTotals: IncomeTotals {
        var t = IncomeTotals()
        var rBase: Decimal = 0
        for d in items {
            let s = d.qty * d.price
            t.sum += s
            let r = retail(d)
            if let p = r.price, p > 0 { t.rSum += d.qty * p; rBase += s }
            if let o = r.old, let p = r.price, !ReceiptMath.samePrice(p, o) { t.changed += 1 }
        }
        t.markup = rBase > 0 ? ReceiptMath.changePercent(t.rSum, rBase) : nil
        return t
    }

    private func isLoss(_ d: DocItemDraft) -> Bool {
        guard let p = retail(d).price else { return false }
        return p > 0 && d.price > 0 && p < d.price
    }

    /// А99: провести приход без закупочной цены нельзя (как в кабинете); черновик — можно.
    /// И когда режим магазина неизвестен: закупка 0 в «Полном магазине» — тоже беда.
    var postBlocker: String? {
        guard isIncome else { return nil }
        guard let d = items.first(where: { $0.kind != "ingredient" && $0.price <= 0 }) else { return nil }
        return "Укажите закупочную цену: \(d.name)"
    }

    /// Перед проведением спросить: меняются розничные цены, скачет закупка или розница ниже закупки.
    var postNeedsConfirm: Bool {
        guard isIncome else { return false }
        // Режим магазина неизвестен — спрашиваем всегда.
        if rcv == nil { return true }
        return items.contains { d in
            if noInfo(d) { return true }
            let r = retail(d)
            if let o = r.old, let p = r.price, !ReceiptMath.samePrice(p, o) { return true }
            return ReceiptMath.isJump(d.price, last: info(d)?.last) || isLoss(d)
        }
    }

    /// Текст «Провести приход?» — итог и список товаров, у которых изменится цена.
    var postSummary: String {
        let t = incomeTotals
        var lines = ["Позиций: \(items.count) · сумма закупки \(Money.rub(t.sum))"]
        if modeUnknown {
            lines.append("Не удалось узнать режим магазина. Если включён «Полный магазин», приход пересчитает "
                + "розничные цены по наценке категорий от указанной закупки — проверьте закупочные цены.")
        }
        if retailOn {
            lines.append("В рознице \(Money.rub(t.rSum)) · наценка \(t.markup.map { ReceiptMath.pct($0) } ?? "—")")
        }
        let jumps = items.filter { ReceiptMath.isJump($0.price, last: info($0)?.last) }.count
        if jumps > 0 { lines.append("Закупочная цена резко изменилась у \(jumps) позиций — проверьте накладную.") }
        let loss = items.filter { isLoss($0) }.map { $0.name }
        if !loss.isEmpty {
            lines.append("Розница ниже закупки: " + loss.prefix(5).joined(separator: ", ") + (loss.count > 5 ? "…" : ""))
        }
        let changes: [(String, Decimal, Decimal)] = items.compactMap { d in
            let r = retail(d)
            guard let o = r.old, let p = r.price, !ReceiptMath.samePrice(p, o) else { return nil }
            return (d.name, o, p)
        }
        if !changes.isEmpty {
            lines.append("Изменятся розничные цены: \(changes.count)")
            for (n, o, p) in changes.prefix(20) { lines.append("\(n): \(Money.rub(o)) → \(Money.rub(p))") }
            if changes.count > 20 { lines.append("…и ещё \(changes.count - 20)") }
        }
        let missing = items.filter { noInfo($0) }.map { $0.name }
        if changes.isEmpty && retailOn && missing.isEmpty {
            lines.append("Розничные цены не изменятся.")
        }
        if !missing.isEmpty {
            lines.append("Нет данных о цене: " + missing.prefix(5).joined(separator: ", ") + (missing.count > 5 ? "…" : "")
                + (retailOn ? " — цена может измениться по наценке категории — сведения не загрузились" : " — сведения не загрузились"))
        }
        lines.append("Остатки увеличатся сразу после проведения. Отменить проведение можно в списке документов.")
        return lines.joined(separator: "\n")
    }

    var total: Decimal { items.reduce(0) { $0 + $1.amount } }

    /// Что мешает сохранить — показываем текстом, а не просто гасим кнопку.
    var blocker: String? {
        if items.isEmpty { return "Добавьте хотя бы одну позицию" }
        if type.needsTargetWarehouse && (warehouseToId ?? 0) == 0 { return "Выберите склад-получатель" }
        if type.needsTargetWarehouse && warehouseId == warehouseToId { return "Склады должны быть разными" }
        if type.needsReason && items.contains(where: { ($0.reason ?? "").isEmpty }) { return "У каждой строки списания нужна причина" }
        // Пустое или нулевое количество раньше уходило в проводку строкой «0».
        // В инвентаризации ноль — законный факт («ничего не осталось»).
        if !type.isInventory && items.contains(where: { $0.qty <= 0 }) { return "Укажите количество в каждой строке" }
        // А99: розница строки прихода — число.
        if items.contains(where: { !$0.retailText.isEmpty && Money.strict($0.retailText) == nil }) {
            return "Проверьте розничную цену: число, например 149 или 99,90"
        }
        return nil
    }

    func loadRefs() async {
        async let s = Self.fetchSuppliers()
        // Склады не загрузились — говорим об этом. Раньше список молча был
        // пустым, и перемещение навсегда упиралось в «Выберите склад-получатель».
        do {
            warehouses = try await API.shared.warehousesDetailed()
        } catch is CancellationError {
        } catch let e as APIDetailedError where e.status == 403 {
            // Нет права «Склад»: без склада сервер проводит документ на основном.
            whNoAccess = true
        } catch {
            self.error = "Не удалось загрузить склады — закройте документ и откройте снова"
        }
        // Удалённый поставщик на сервере только выключается (is_active = 0) и
        // по-прежнему приходит в списке — в выбор его не даём, как в закупках.
        let (list, denied) = await s
        supNoAccess = denied
        suppliers = (list ?? []).filter { $0.isActive != false }
        if warehouseId == nil {
            warehouseId = warehouses.first(where: { $0.isDefault == true })?.warehouseId ?? warehouses.first?.warehouseId
        }
    }

    /// Поставщики: (список, 403 — нет права «Поставщики»). Прочие сбои — молча, как раньше.
    private nonisolated static func fetchSuppliers() async -> ([Supplier]?, Bool) {
        do { return (try await API.shared.suppliersDetailed(), false) }
        catch let e as APIDetailedError where e.status == 403 { return (nil, true) }
        catch { return (nil, false) }
    }

    func add(_ hit: StockSearchItem) {
        // Один и тот же товар дважды в документе — источник ошибок при
        // проведении, поэтому вместо второй строки увеличиваем количество.
        // Вид считаем так же, как у новой строки: без kind в ответе раньше
        // сравнивали с "", а строку клали с "product" — дубль не находился.
        let hitKind = hit.kind ?? "product"
        if let idx = items.firstIndex(where: { $0.entityId == hit.entityId && $0.kind == hitKind }) {
            items[idx].qty += 1
            return
        }
        items.append(DocItemDraft(
            kind: hitKind,
            entityId: hit.entityId,
            name: hit.name ?? "—",
            unit: hit.unit ?? "шт",
            qty: 1,
            // «По учёту» — учётный остаток склада из поиска (stock_qty). Раньше
            // стоял 0, и экран обещал расхождение «факт − 0», хотя сервер при
            // проведении считает от реального остатка. Минус в документ не
            // пускается сервером, поэтому не ниже нуля.
            qtyPlan: type.isInventory ? max(0, hit.stockQty ?? 0) : nil,
            // Приход: у товара в поиске — РОЗНИЧНАЯ цена, закупкой её не ставим (закупку
            // подставят сведения сервера или человек). Ингредиенту — price_per_unit, как раньше.
            price: isIncome && hitKind != "ingredient" ? 0 : (hit.anyPrice ?? 0),
            reason: type.needsReason ? DocWriteoffReason.spoilage.rawValue : nil
        ))
        // А99: сведения о позиции для прихода (было N ₽, розница, наценка).
        if isIncome && rcv != nil {
            Task { await loadInfo(kind: hitKind, id: hit.entityId) }
        } else if isIncome {
            // Режим магазина ещё не узнали — пробуем снова.
            Task { await loadReceiptProbe() }
        }
    }

    func save(post: Bool) async -> Bool {
        // Двойной тап «Провести» создавал два проведённых документа — склад менялся дважды.
        guard !saving else { return false }
        saving = true; defer { saving = false }
        // А99: розница строки — только ручная; накладная — только с номером (дата без
        // номера не уходит, как в кабинете).
        let out: [DocItemDraft] = items.map { d in
            var x = d
            x.retailPriceOut = manualRetailOut(d)
            return x
        }
        let no = docFieldsOn ? String(supplierDocNo.trimmingCharacters(in: .whitespaces).prefix(64)) : ""
        do {
            _ = try await API.shared.createDocument(
                type: type, warehouseId: warehouseId, warehouseToId: warehouseToId,
                supplierId: supplierId, comment: comment, post: post, items: out,
                supplierDocNo: no.isEmpty ? nil : no,
                supplierDocDate: no.isEmpty ? nil : DateFmt.ymd(supplierDocDate),
                keys: idemKeys
            )
            pendingPost = nil
            return true
        } catch let e as APIDetailedError {
            // Паритет с Android — по HTTP-коду, а не по тексту ответа.
            if e.status >= 500 || e.code == "idempotency_in_progress" {
                return unknownOutcome(post: post, e.message)
            }
            pendingPost = nil
            if e.code == "idempotency_unknown_outcome" {
                // Сервер не знает, чем кончилась прошлая попытка, а ключ уже сброшен —
                // ещё одно нажатие могло бы создать копию. Закрываем кнопку, «Закрыть» обновит список.
                draftSaved = true
                self.error = "\(e.message). Закройте окно и проверьте список документов."
                return false
            }
            // Сервер (seller_warehouse.php, POST /stock-documents) сначала сохраняет
            // черновик, потом проводит: 409 «не удалось провести» и 403 «сохранён
            // черновиком» с document_id — документ уже в списке.
            if post, e.status == 409 || (e.status == 403 && e.documentId != nil) {
                draftSaved = true
                self.error = "Документ сохранён черновиком, но не проведён: \(e.message). Закройте окно — черновик в списке, проведите его после исправления."
                return false
            }
            self.error = e.message
            return false
        } catch let e as APIError {
            switch e {
            // Ответа нет — ключ повтора остался (postKeyed), повторять можно только то же действие.
            case .network, .timeout, .http: return unknownOutcome(post: post, e.localizedDescription)
            // 200 пришёл, но ответ не разобрался — документ, скорее всего, создан. Повтор
            // снова получил бы тот же неразборчивый ответ: кнопки закрываем, как при
            // сохранённом черновике, «Закрыть» обновит список.
            case .decoding:
                pendingPost = nil
                draftSaved = true
                self.error = "Документ, скорее всего, создан — закройте окно и проверьте список документов."
                return false
            default:
                pendingPost = nil
                self.error = e.localizedDescription
                return false
            }
        } catch {
            pendingPost = nil
            self.error = error.localizedDescription
            return false
        }
    }

    private func unknownOutcome(post: Bool, _ message: String) -> Bool {
        pendingPost = post
        self.error = "\(message). Документ мог создаться — нажмите «\(post ? "Создать и провести" : "Сохранить черновик")» "
            + "ещё раз, ничего не меняя: второй документ сервер не создаст."
        return false
    }
}

struct DocumentEditView: View {
    let type: DocType
    var onSaved: () -> Void = {}

    @StateObject private var vm: DocumentEditViewModel
    @State private var searching = false
    /// А99: «Провести приход?» — что изменится, перед проведением.
    @State private var confirmPost = false
    @Environment(\.dismiss) private var dismiss

    init(type: DocType, onSaved: @escaping () -> Void = {}) {
        self.type = type
        self.onSaved = onSaved
        _vm = StateObject(wrappedValue: DocumentEditViewModel(type: type))
    }

    var body: some View {
        Form {
            // Исход отправки неизвестен: всё, что входит в тело, заморожено (новое тело —
            // новый ключ повтора и второй документ на сервере).
            if let p = vm.pendingPost {
                Section {
                    Text("Ждём ответ сервера — нажмите «\(p ? "Создать и провести" : "Сохранить черновик")» ещё раз, ничего не меняя")
                        .font(.caption).foregroundColor(Brand.amber)
                }
                .listRowBackground(Brand.card)
            }
            Section("Склад") {
                if vm.whNoAccess {
                    Text(type.needsTargetWarehouse
                         ? "Нет доступа к списку складов — для перемещения нужно право «Склад» (выдаёт владелец)"
                         : "Нет доступа к списку складов — документ будет на основном складе")
                        .font(.caption).foregroundColor(Brand.muted)
                }
                Picker("Склад", selection: Binding(
                    get: { vm.warehouseId ?? 0 },
                    set: { newValue in
                        if type.isInventory && !vm.items.isEmpty && newValue != vm.warehouseId { vm.planStale = true }
                        vm.warehouseId = newValue
                    }
                )) {
                    ForEach(vm.warehouses) { w in
                        Text(w.name ?? "Склад").tag(w.warehouseId)
                    }
                }
                if vm.planStale && !vm.items.isEmpty {
                    Text("Склад сменился — добавьте строки заново, чтобы обновить «По учёту»")
                        .font(.caption).foregroundColor(Brand.amber)
                }
                if type.needsTargetWarehouse {
                    Picker("Куда", selection: Binding(
                        get: { vm.warehouseToId ?? 0 },
                        set: { vm.warehouseToId = $0 }
                    )) {
                        Text("Не выбран").tag(0)
                        ForEach(vm.warehouses) { w in
                            Text(w.name ?? "Склад").tag(w.warehouseId)
                        }
                    }
                }
                if (type == .income || type == .returnSupplier) && vm.supNoAccess {
                    Text("Нет доступа к списку поставщиков").font(.caption).foregroundColor(Brand.muted)
                }
                if type == .income || type == .returnSupplier {
                    Picker("Поставщик", selection: Binding(
                        get: { vm.supplierId ?? 0 },
                        set: { vm.supplierId = $0 }
                    )) {
                        Text("Не указан").tag(0)
                        ForEach(vm.suppliers) { s in
                            Text(s.name ?? "Поставщик").tag(s.supplierId ?? 0)
                        }
                    }
                }
                // А99: номер и дата накладной поставщика — видны в списке и в карточке прихода.
                if vm.docFieldsOn {
                    TextField("№ накладной поставщика", text: Binding(
                        get: { vm.supplierDocNo },
                        set: { vm.supplierDocNo = String($0.prefix(64)) }
                    ))
                    DatePicker("Дата накладной", selection: $vm.supplierDocDate, displayedComponents: .date)
                }
            }
            .disabled(vm.pendingPost != nil)
            .listRowBackground(Brand.card)

            // А99: наценка для всех товаров прихода разом (только «Полный магазин»).
            if vm.isIncome && vm.retailOn {
                if !vm.mayPrice {
                    Section {
                        Text("Нет права «Менять цены» — розничные цены приход не изменит")
                            .font(.caption).foregroundColor(Brand.amber)
                    }
                    .listRowBackground(Brand.card)
                } else if vm.items.contains(where: { $0.kind != "ingredient" }) {
                    Section("Наценка для всех товаров") {
                        HStack(spacing: 8) {
                            TextField("%", text: $vm.bulkMarkup)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Button("Применить") { vm.applyBulk() }
                                .buttonStyle(.borderless)
                            Spacer()
                            Button("По категориям") { vm.resetBulk() }
                                .buttonStyle(.borderless)
                        }
                        Picker("Округление", selection: $vm.bulkRounding) {
                            ForEach(ReceiptMath.rounding, id: \.0) { v, t in Text(t).tag(v) }
                        }
                        .pickerStyle(.menu)
                        if let n = vm.note {
                            Text(n).font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                    .disabled(vm.pendingPost != nil)
                    .listRowBackground(Brand.card)
                }
            }

            Section("Позиции") {
                ForEach($vm.items) { $item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(item.name).font(.subheadline).foregroundColor(Brand.text)
                            Spacer()
                            Text(Money.rub(item.amount)).font(.caption.weight(.semibold)).foregroundColor(Brand.text)
                        }
                        if type.isInventory {
                            // План — сколько числится, факт — сколько пересчитали.
                            HStack(spacing: 8) {
                                decimalField("По учёту", value: Binding(
                                    get: { item.qtyPlan ?? 0 },
                                    set: { item.qtyPlan = $0 }
                                ))
                                decimalField("Факт", value: $item.qty)
                            }
                        } else {
                            HStack(spacing: 8) {
                                decimalField("Кол-во", value: $item.qty)
                                // А99: закупку, поправленную руками, сервер больше не подставляет.
                                decimalField(vm.isIncome ? "Закупка, ₽" : "Цена", value: Binding(
                                    get: { item.price },
                                    set: { item.price = $0; item.priceTouched = true; item.markupText = nil }
                                ))
                            }
                            // А99: «было N ₽», розница сейчас, наценка и новая розничная цена.
                            if vm.isIncome, let inf = vm.info(item) {
                                IncomeLineExtras(vm: vm, item: item, inf: inf)
                            } else if vm.noInfo(item) {
                                // Сведения не пришли — честно пишем и даём повторить.
                                HStack {
                                    Text(vm.isInfoLoading(item) ? "загружаем сведения о цене…" : "нет данных о цене — сведения не загрузились")
                                        .font(.caption2).foregroundColor(Brand.amber)
                                    Spacer()
                                    if !vm.isInfoLoading(item) {
                                        Button("Повторить") { Task { await vm.loadInfo(for: [item]) } }
                                            .font(.caption2).buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        if type.needsReason {
                            Picker("Причина", selection: Binding(
                                get: { item.reason ?? DocWriteoffReason.spoilage.rawValue },
                                set: { item.reason = $0 }
                            )) {
                                ForEach(DocWriteoffReason.allCases) { r in
                                    Text(r.title).tag(r.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { offsets in
                    // Исход отправки неизвестен — строки не трогаем (см. pendingPost).
                    guard vm.pendingPost == nil else { return }
                    // Строка в ForEach($…) с полем в фокусе: удаление в том же кадре
                    // роняло SwiftUI (Index out of range). Сначала снимаем фокус.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    // Удаляем по id, а не по номерам: к следующему кадру список мог измениться.
                    let ids = Set(offsets.map { vm.items[$0].id })
                    DispatchQueue.main.async { vm.items.removeAll { ids.contains($0.id) } }
                }

                Button { searching = true } label: {
                    Label("Добавить позицию", systemImage: "plus.circle")
                }
            }
            .disabled(vm.pendingPost != nil)
            .listRowBackground(Brand.card)

            Section {
                TextField("Комментарий", text: $vm.comment, axis: .vertical)
                    .disabled(vm.pendingPost != nil)
                InfoRow(label: "Итого", value: Money.rub(vm.total))
                // А99: итоги прихода — в рознице, средняя наценка, сколько цен изменится.
                if vm.isIncome && vm.rcv != nil && vm.retailOn && !vm.items.isEmpty {
                    let t = vm.incomeTotals
                    InfoRow(label: "В рознице", value: Money.rub(t.rSum))
                    InfoRow(label: "Наценка", value: t.markup.map { ReceiptMath.pct($0) } ?? "—")
                    InfoRow(label: "Новых цен", value: "\(t.changed)")
                }
                if let b = vm.blocker ?? (Session.shared.can("documents.post") ? vm.postBlocker : nil) {
                    Text(b).font(.caption).foregroundColor(Brand.amber)
                }
                // Режим магазина неизвестен — закупку не подставляли, перед проведением спросим.
                if vm.modeUnknown && vm.items.contains(where: { $0.kind != "ingredient" }) {
                    Text(vm.probeBusy ? "Узнаём режим магазина…" : "Режим магазина не загрузился — укажите закупочные цены по накладной")
                        .font(.caption).foregroundColor(Brand.muted)
                }
                if vm.isIncome && vm.rcv != nil {
                    HelpLink(path: "help/priemka-tovara", title: "Как это работает")
                }
            }
            .listRowBackground(Brand.card)
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(type.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Черновик уже сохранён — «Закрыть» перечитывает список, чтобы он там появился.
            ToolbarItem(placement: .cancellationAction) {
                Button(vm.draftSaved ? "Закрыть" : "Отмена") {
                    // Исход отправки неизвестен — документ мог создаться: тоже перечитываем список.
                    if vm.draftSaved || vm.pendingPost != nil { onSaved() }
                    dismiss()
                }
                // Пока документ уходит — не закрываем (ключ повтора живёт с окном).
                .disabled(vm.saving)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Сохранить черновик") {
                        Task { if await vm.save(post: false) { onSaved(); dismiss() } }
                    }
                    // Исход «Создать и провести» неизвестен — черновик дал бы второй документ.
                    .disabled(vm.pendingPost == true)
                    // Проведение двигает остатки — называем это прямо.
                    // Своё право documents.post (как кнопка «Провести» в списке
                    // и на Android): кладовщик составляет черновик, проводит старший.
                    if Session.shared.can("documents.post") {
                        Button("Создать и провести") {
                            // Сведения не загрузились — ещё раз спросим, пока человек смотрит подтверждение.
                            let missing = vm.items.filter { vm.noInfo($0) }
                            if !missing.isEmpty { Task { await vm.loadInfo(for: missing) } }
                            // Режим магазина не узнали — тоже спросим ещё раз.
                            if vm.modeUnknown { Task { await vm.loadReceiptProbe() } }
                            // А99: приход меняет розничные цены или закупка резко скачет —
                            // сначала показываем, что изменится (как «Провести приход?» в кабинете).
                            if vm.postNeedsConfirm {
                                confirmPost = true
                            } else {
                                Task { if await vm.save(post: true) { onSaved(); dismiss() } }
                            }
                        }
                        // А99: без закупочной цены приход не проводим (черновик — можно).
                        // Исход «Сохранить черновик» неизвестен — проведение дало бы второй документ.
                        .disabled(vm.postBlocker != nil || vm.pendingPost == false)
                    }
                } label: { Text("Готово") }
                .disabled(vm.saving || vm.blocker != nil || vm.draftSaved)
            }
        }
        .task { await vm.loadRefs() }
        // А99: проба приёмки — параллельно со складами (старый сервер — ничего не меняется).
        .task { await vm.loadReceiptProbe() }
        .alert("Провести приход?", isPresented: $confirmPost) {
            Button("Провести") { Task { if await vm.save(post: true) { onSaved(); dismiss() } } }
            Button("Вернуться", role: .cancel) {}
        } message: { Text(vm.postSummary) }
        // Документ открыт листом: случайный свайп вниз закрывал его и стирал все
        // набранные строки (пересчёт инвентаризации — заново). Есть строки —
        // закрыть можно только кнопкой «Отмена».
        .interactiveDismissDisabled(!vm.items.isEmpty || vm.saving)
        .sheet(isPresented: $searching) {
            StockSearchSheet(warehouseId: vm.warehouseId) { hit in
                vm.add(hit)
                searching = false
            }
        }
        .alert("Не получилось", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("Понятно", role: .cancel) { vm.error = nil }
        } message: { Text(vm.error ?? "") }
    }

    /// Поле числа с запятой: на русской клавиатуре десятичный разделитель —
    /// запятая, а Decimal(string:) понимает только точку.
    private func decimalField(_ title: String, value: Binding<Decimal>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(Brand.muted)
            DecimalInputField(title: title, value: value)
        }
    }
}

/// А99: строка прихода на сервере с волной А99 — закупка к прошлому приходу
/// («было N ₽»), остаток и цена сейчас; в «Полном магазине» — наценка и новая
/// розничная цена (тексты — как в кабинете и в приложении для Android).
struct IncomeLineExtras: View {
    @ObservedObject var vm: DocumentEditViewModel
    let item: DocItemDraft
    let inf: PriceInfoItem

    private var change: Decimal? {
        guard let last = inf.last, item.price > 0 else { return nil }
        return ReceiptMath.changePercent(item.price, last)
    }

    private var lastLine: (String, Color) {
        guard let last = inf.last else { return ("первый приход", Brand.green) }
        var whenWho: [String] = []
        if let at = inf.lastAt, !at.isEmpty { whenWho.append(ReceiptMath.ruDate(at)) }
        if let s = inf.lastSupplier, !s.isEmpty { whenWho.append(s) }
        var text = "было " + Money.rub(last)
        if !whenWho.isEmpty { text += " (" + whenWho.joined(separator: ", ") + ")" }
        if let ch = change, (ch < 0 ? -ch : ch) >= Decimal(string: "0.5")! {
            text += (ch > 0 ? " ▲ " : " ▼ ") + ReceiptMath.pct(ch)
            return (text, ch > 0 ? Brand.red : Brand.green)
        }
        return (text, Brand.muted)
    }

    private var meta: String {
        var parts = ["остаток " + QtyFmt.qty(inf.stockQty) + " " + item.unit]
        if let c = inf.category, !c.isEmpty { parts.append(c) }
        if inf.isProduct { parts.append("цена сейчас " + Money.rub(inf.retail)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let r = vm.retail(item)
        let mk = (r.price != nil && item.price > 0) ? ReceiptMath.markupPercent(r.price!, item.price) : nil
        VStack(alignment: .leading, spacing: 4) {
            Text(lastLine.0).font(.caption2).foregroundColor(lastLine.1)
            Text(meta).font(.caption2).foregroundColor(Brand.muted)
            if item.price <= 0 {
                Text("нет закупочной цены").font(.caption2).foregroundColor(Brand.red)
            }
            if let ch = change, ReceiptMath.isJump(item.price, last: inf.last) {
                Text("закупка \(ReceiptMath.pct(ch)) к прошлой — проверьте накладную")
                    .font(.caption2).foregroundColor(Brand.amber)
            }
            if vm.retailOn && inf.isProduct && vm.mayPrice {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Наценка, %").font(.caption2).foregroundColor(Brand.muted)
                        TextField("%", text: Binding(
                            get: { item.markupText ?? mk.map { ReceiptMath.oneDecimal($0) } ?? "" },
                            set: { vm.setMarkup(id: item.id, text: $0) }
                        ))
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Розница, ₽").font(.caption2).foregroundColor(Brand.muted)
                        TextField(r.price.map { ReceiptMath.moneyInput($0) } ?? "авто", text: Binding(
                            get: { item.retailText },
                            set: { vm.setRetail(id: item.id, text: $0) }
                        ))
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                    }
                }
                Text(retailHint(r, mk)).font(.caption2).foregroundColor(Brand.muted)
                if let p = r.price, p > 0, item.price > 0, p < item.price {
                    Text("розница ниже закупки").font(.caption2).foregroundColor(Brand.red)
                }
            }
        }
    }

    private func retailHint(_ r: ReceiptMath.Retail, _ mk: Decimal?) -> String {
        var parts: [String] = []
        if let o = r.old, let p = r.price, !ReceiptMath.samePrice(p, o) {
            parts.append("сейчас \(Money.rub(o)) → \(Money.rub(p))")
        } else if r.old != nil {
            parts.append("без изменений")
        }
        let src = ReceiptMath.srcText(r.src, markup: inf.markupPercent)
        if !src.isEmpty { parts.append(src) }
        if mk != nil, let p = r.price { parts.append("маржа " + Money.rub(p - item.price)) }
        return parts.joined(separator: " · ")
    }
}

/// Числовое поле, которое хранит СВОЙ текст. Раньше каждое нажатие
/// превращалось в число и обратно: после «0,» в поле снова стояло «0», и
/// «0,5» кг становилось 5 — документ проводил в 10 раз больше.
struct DecimalInputField: View {
    let title: String
    @Binding var value: Decimal
    @State private var text = ""
    @State private var shown: Decimal?

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.decimalPad)
            .textFieldStyle(.roundedBorder)
            .onAppear {
                if shown == nil { text = Self.format(value); shown = value }
            }
            .onChange(of: text) { t in
                // Пусто — 0. Не число («1,5,») — оставляем последнее верное
                // значение: раньше становилось 0, и инвентаризация проводила
                // «факт 0», списывая весь остаток.
                let v: Decimal
                if t.trimmingCharacters(in: .whitespaces).isEmpty { v = 0 }
                else if let p = Self.parse(t) { v = p }
                else { return }
                shown = v
                if v != value { value = v }
            }
            .onChange(of: value) { v in
                // Значение поменяли не набором (например, «+1» при повторном
                // добавлении позиции) — показываем новое.
                if v != shown { text = Self.format(v); shown = v }
            }
    }

    static func parse(_ s: String) -> Decimal? {
        let t = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t != ".",
              t.range(of: #"^\d*\.?\d*$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: t)
    }

    static func format(_ v: Decimal) -> String {
        v == 0 ? "" : NSDecimalNumber(decimal: v).stringValue.replacingOccurrences(of: ".", with: ",")
    }
}

// ── Поиск позиции ────────────────────────────────────────────────────────────

struct StockSearchSheet: View {
    /// Склад документа: поиск вернёт остаток именно этого склада.
    var warehouseId: Int? = nil
    /// А99: в переоценке выбираем только товары (без ингредиентов).
    var productsOnly: Bool = false
    let onPick: (StockSearchItem) -> Void

    @State private var query = ""
    @State private var hits: [StockSearchItem] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    private func scheduleSearch() {
        searchTask?.cancel()
        // Поиск «уже идёт» с момента ввода: иначе за 350 мс задержки мелькало
        // «Ничего не найдено», хотя запрос ещё даже не ушёл.
        if query.trimmingCharacters(in: .whitespaces).count >= 2 { searching = true }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await search()
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(hits, id: \.id) { hit in
                    Button { onPick(hit); dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                                Text(hit.isIngredient ? "ингредиент" : "товар")
                                    .font(.caption2).foregroundColor(Brand.muted)
                            }
                            Spacer()
                            Text(Money.rub(hit.anyPrice)).font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .searchable(text: $query, prompt: "Название, артикул или штрихкод")
            .onSubmit(of: .search) { Task { await search() } }
            // С задержкой: раньше каждая буква слала поиск по складу, и на
            // медленной сети ответы приходили пачкой с опозданием.
            .onChange(of: query) { _ in scheduleSearch() }
            .overlay {
                // «Ничего не найдено» — только когда поиск действительно шёл
                // (от 2 символов), а не после первой буквы.
                if hits.isEmpty && query.trimmingCharacters(in: .whitespaces).count >= 2 && !searching {
                    // Сбой сети — не «ничего не найдено»: раньше кладовщик решал,
                    // что товара нет в базе, и заводил дубль.
                    if let err = searchError {
                        ErrorBanner(message: err) { Task { await search() } }
                    } else {
                        EmptyState(icon: "magnifyingglass", title: "Ничего не найдено", subtitle: nil)
                    }
                } else if hits.isEmpty && query.trimmingCharacters(in: .whitespaces).count < 2 {
                    // Пустой белый лист до ввода выглядел сломанным — особенно у
                    // нового магазина, где позиций ещё нет.
                    EmptyState(icon: "magnifyingglass", title: "Найдите позицию",
                               subtitle: "Введите от 2 букв названия, артикул или штрихкод. Ищутся товары и ингредиенты магазина.")
                }
            }
            .navigationTitle(productsOnly ? "Добавить товар" : "Добавить позицию")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
    }

    /// Сервер ищет и по товарам, и по ингредиентам; пустой запрос он не любит.
    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { hits = []; searchError = nil; searching = false; return }
        searching = true
        var found: [StockSearchItem] = []
        var failure: String?
        do {
            found = try await API.shared.stockSearch(q: q, warehouseId: warehouseId)
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
        // Пока ждали ответ, запрос уже уточнили: старый ответ («мол») не должен
        // перетереть новый («моло»).
        guard q == query.trimmingCharacters(in: .whitespaces) else { return }
        hits = productsOnly ? found.filter { !$0.isIngredient } : found
        searchError = failure
        searching = false
    }
}
