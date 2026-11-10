import Foundation

// ============================================================================
//  План закупок: чистая логика (группы по поставщику, итог «Создать заказы»,
//  решение «забыть ключ повтора», хранение ключа на телефоне).
// ============================================================================

/// Есть ли «План закупок» на сервере. Проба — GET /status.
/// 403 / 404 / 405 / 503 — пункта нет. Класс без @MainActor, как RevalFeature.
final class ReplenishmentFeature: ObservableObject {
    static let shared = ReplenishmentFeature()
    @Published private(set) var available = false

    private var checkedShop: Int?
    private var checkedAt = Date.distantPast
    private var checkingShop: Int?

    private init() {}

    @MainActor
    func refresh(shopId: Int?) async {
        guard let sid = shopId, Session.shared.can("warehouse") else {
            // Нет магазина или права (в т.ч. вышли из аккаунта): забываем прежнюю пробу, иначе пункт
            // оставался бы скрытым ещё 10 минут после возврата права или входа другого пользователя.
            available = false; checkedShop = nil; checkedAt = Date.distantPast
            return
        }
        if checkedShop != sid { available = false }
        if checkedShop == sid && Date().timeIntervalSince(checkedAt) < 600 { return }
        guard checkingShop != sid else { return }
        checkingShop = sid
        defer { if checkingShop == sid { checkingShop = nil } }
        do {
            _ = try await API.shared.replStatus(retries: 0)
            guard Session.shared.activeShopId == sid else { return }
            available = true; checkedShop = sid; checkedAt = Date()
        } catch {
            guard Session.shared.activeShopId == sid else { return }
            switch FeatureProbe.from(error) {
            case .hidden:
                available = false; checkedShop = sid; checkedAt = Date()
            default:
                break
            }
        }
    }
}

/// Блок плана: один поставщик (или «Без поставщика») и его строки.
struct ReplBlock: Identifiable {
    let id: String
    let name: String
    let group: ReplGroup?
    let lines: [ReplLine]
}

/// Ключ повтора «Создать заказы», сохранённый на телефоне ДО отправки.
/// Вместе с ним лежит тело запроса (период и исключённые строки): повтор после
/// обрыва или после перезапуска приложения уходит с тем же ключом и тем же телом.
struct ReplPendingOrders: Codable, Equatable {
    var key: String
    var horizon: String
    var exclude: [String]
}

enum ReplPendingStore {
    private static let prefix = "repl_orders_pending_"

    /// Имя записи: по магазину И пользователю — у другого сотрудника или магазина свой запрос.
    static func name(shopId: Int?, userId: Int?) -> String { prefix + "\(shopId ?? 0)_\(userId ?? 0)" }

    static func load(shopId: Int?, userId: Int?) -> ReplPendingOrders? {
        guard let data = UserDefaults.standard.data(forKey: name(shopId: shopId, userId: userId)) else { return nil }
        return try? JSONDecoder().decode(ReplPendingOrders.self, from: data)
    }

    static func save(_ p: ReplPendingOrders, shopId: Int?, userId: Int?) {
        if let data = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(data, forKey: name(shopId: shopId, userId: userId))
        }
    }

    static func clear(shopId: Int?, userId: Int?) {
        UserDefaults.standard.removeObject(forKey: name(shopId: shopId, userId: userId))
    }

    /// Выход из аккаунта: забыть все такие записи (и старые, без пользователя в имени).
    static func clearAll() {
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix(prefix) { d.removeObject(forKey: k) }
    }
}

enum ReplLogic {
    static let pollNanos: UInt64 = 2_500_000_000
    /// Через 10 минут опрос останавливается (как на Android): текст и кнопка «Проверить ещё раз».
    static let pollGiveUpSeconds: TimeInterval = 600
    static let slowText = "Пересчёт идёт дольше обычного."
    static let checkAgain = "Проверить ещё раз"
    static let cancelSend = "Отменить отправку"
    static let cancelSendTitle = "Отменить незавершённую отправку?"
    static let cancelSendNote = "Если заказы уже успели создаться, они останутся в разделе «Закупки»."
    static let cancelSendKeep = "Не надо"

    static func partialText(shown: Int, total: Int) -> String {
        "Показаны не все позиции (\(shown) из \(total)) — в заказ попадут все выбранные"
    }

    /// Пришла только часть плана: всего позиций больше, чем строк в ответе.
    static func isPartial(_ plan: ReplPlan) -> Bool { (plan.total ?? 0) > plan.lines.count }

    /// «В заказы попадёт»: при неполной выдаче — серверная сводка (order_lines, order_amount) минус то,
    /// что снято вручную в загруженных строках; иначе (или без сводки) — по строкам на экране.
    static func orderTotals(_ plan: ReplPlan, excluded: Set<String>) -> (count: Int, amount: Decimal) {
        let local = included(plan, excluded: excluded)
        guard isPartial(plan), let s = plan.summary, let sl = s.orderLines, let sa = s.orderAmount else {
            return (local.count, includedAmount(local))
        }
        let dropped = plan.lines.filter { ($0.selected ?? false) && excluded.contains($0.key) && ($0.qty ?? 0) > 0 }
        return (max(0, sl - dropped.count), max(Decimal(0), sa - includedAmount(dropped)))
    }

    static let horizons: [(value: String, title: String)] = [
        ("7", "7 дней"), ("14", "14 дней"), ("30", "30 дней"), ("next_delivery", "До следующей поставки"),
    ]

    static func horizonTitle(_ value: String) -> String {
        horizons.first(where: { $0.value == value })?.title ?? value
    }

    /// Расчёт закончен (успешно или с ошибкой) — опрос не нужен.
    static func isTerminal(_ s: ReplStatus?) -> Bool {
        guard let s else { return true }
        if s.running ?? false { return false }
        let st = s.status ?? ""
        return st != "pending" && st != "running"
    }

    /// Строка попадает в список по умолчанию: риск дефицита или нужно заказать.
    static func needsOrder(_ line: ReplLine) -> Bool {
        let s = line.status ?? ""
        return s == "risk" || s == "order"
    }

    /// Строки по поставщикам: порядок групп — как у сервера; строки с неизвестным
    /// поставщиком уходят в «Без поставщика». onlyOrder — только «риск» и «к заказу».
    static func blocks(_ plan: ReplPlan, onlyOrder: Bool) -> [ReplBlock] {
        let lines = onlyOrder ? plan.lines.filter { needsOrder($0) } : plan.lines
        var used = Set<String>()
        var out: [ReplBlock] = []
        let groupIds = Set(plan.suppliers.compactMap { $0.supplierId })
        for g in plan.suppliers {
            let mine = lines.filter { l in
                let sid = l.supplier?.supplierId
                if let gid = g.supplierId { return sid == gid }
                return sid == nil || !(groupIds.contains(sid ?? -1))
            }
            mine.forEach { used.insert($0.key) }
            if mine.isEmpty { continue }
            let name = (g.name ?? "").isEmpty ? "Без поставщика" : (g.name ?? "")
            out.append(ReplBlock(id: "s\(g.supplierId ?? 0)", name: name, group: g, lines: mine))
        }
        let rest = lines.filter { !used.contains($0.key) }
        if !rest.isEmpty {
            out.append(ReplBlock(id: "rest", name: "Без поставщика", group: nil, lines: rest))
        }
        return out
    }

    /// Что реально уйдёт в заказы: выбранные сервером строки без исключённых вручную.
    static func included(_ plan: ReplPlan, excluded: Set<String>) -> [ReplLine] {
        plan.lines.filter { ($0.selected ?? false) && !excluded.contains($0.key) && ($0.qty ?? 0) > 0 }
    }

    static func includedAmount(_ lines: [ReplLine]) -> Decimal {
        lines.reduce(Decimal(0)) { $0 + ($1.amount ?? 0) }
    }

    /// Сумма блока поставщика: только строки, которые реально уйдут в заказ (без снятых галочек).
    static func blockAmount(_ block: ReplBlock, excluded: Set<String>) -> Decimal {
        includedAmount(block.lines.filter { ($0.selected ?? false) && !excluded.contains($0.key) && ($0.qty ?? 0) > 0 })
    }

    /// «3,2 дн.», «14 дн.» (без «,0»), «100+ дн.»; нет данных — «—». Те же слова на Android.
    static func coverText(_ days: Double?) -> String {
        guard let d = days, d.isFinite else { return "—" }
        if d >= 100 { return "100+ дн." }
        // Округление «от нуля» (как HALF_UP на Android), а не банковское.
        let rounded = (d * 10).rounded(.toNearestOrAwayFromZero) / 10
        var t = String(format: "%.1f", rounded).replacingOccurrences(of: ".", with: ",")
        if t.hasSuffix(",0") { t.removeLast(2) }
        return t + " дн."
    }

    // ── Тексты, общие с Android (core/ReplLogic.kt) ─────────────────────────
    static let emptyText = "Заказывать пока нечего: товара хватает."
    static let noDataText = "План ещё не рассчитан. Нажмите «Пересчитать»."
    static let needSuppliersRight = "Создавать заказы может сотрудник с правом «Поставщики»"
    static let creating = "Создаём…"

    /// Ключ повтора можно забыть: ответ сервера получен и ясен (успех, отказ проверки,
    /// отказ ключа). Обрыв, таймаут, 5xx, 409 «уже идёт» и неразобранный ответ — исход
    /// неизвестен: ключ остаётся, повтор пойдёт с ним.
    static func shouldForgetKey(_ error: Error) -> Bool {
        if let e = error as? IdempotencyError {
            return e.code == "idempotency_key_reused" || e.code == "idempotency_unknown_outcome"
        }
        if let e = error as? APIDetailedError {
            if e.status >= 500 || e.status == 0 { return false }
            if e.status == 401 { return false }   // сессия истекла: исход неизвестен, повтор после входа — тем же ключом
            if e.status == 409 { return false }
            return true
        }
        return false
    }

    /// Строки итога после «Создать заказы».
    static func resultLines(_ r: ReplOrdersResult) -> [String] {
        var out: [String] = []
        if !r.created.isEmpty { out.append("Создано заказов: \(r.created.count)") }
        if !r.reused.isEmpty { out.append("Уже были: \(r.reused.count)") }
        if !r.skipped.isEmpty {
            out.append("Пропущено: \(r.skipped.count)" + reasonSuffix(r.skipped.compactMap { $0.reason }))
        }
        if !r.failed.isEmpty {
            out.append("Не удалось: \(r.failed.count)" + reasonSuffix(r.failed.compactMap { $0.error }))
        }
        if out.isEmpty { out.append("Заказы не созданы") }
        return out
    }

    /// " (причина1, причина2)" — повторы убираем, не больше трёх причин.
    static func reasonSuffix(_ reasons: [String]) -> String {
        var seen: [String] = []
        for raw in reasons {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !seen.contains(t) { seen.append(t) }
        }
        if seen.isEmpty { return "" }
        return " (" + seen.prefix(3).joined(separator: ", ") + ")"
    }

    static func hasOrders(_ r: ReplOrdersResult) -> Bool { !r.created.isEmpty || !r.reused.isEmpty }
}
