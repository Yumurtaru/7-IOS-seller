import SwiftUI

// ============================================================================
//  А1328: обнуление остатков — POST /api/seller/products/zero-stock.
//  Один сценарий на карточку товара и на массовое действие в списке:
//   1. dry_run=true — сервер считает, ничего не меняя. items пусто — показываем message и всё;
//   2. иначе подтверждение «Обнулить остаток у N товаров?» со списком «Имя: 12,5 → 0»
//      (до 30 строк + «и ещё K») и «Пропущены: имя — причина»;
//   3. «Обнулить» — тот же запрос без dry_run с Idempotency-Key (ключи экрана: ключ тот же
//      при повторе после обрыва связи, новый — после ответа сервера) — показываем message.
//  warehouse_id не отправляем: обнуляются все склады. Ошибки — текст сервера.
// ============================================================================

@MainActor
final class ZeroStockFlow: ObservableObject {
    struct Plan {
        let ids: [Int]
        let count: Int
        let message: String
    }

    @Published var busy = false
    /// Подтверждение; nil — не показано.
    @Published var plan: Plan?
    /// Итог или ошибка (alert); noticeIsError выбирает заголовок.
    @Published var notice: String?
    @Published var noticeIsError = false

    /// Ключи этого экрана: один ключ на одно и то же действие (путь + тело).
    private let keys = IdempotencyKeys.form()

    static let showLimit = 30

    /// Шаг 1: расчёт (dry_run). После него либо notice (нечего обнулять / ошибка), либо plan.
    func start(ids: [Int]) async {
        guard !busy, !ids.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await API.shared.zeroStock(productIds: ids, dryRun: true, keys: nil)
            let items = r.items ?? []
            if items.isEmpty {
                noticeIsError = false
                let skipped = r.skipped ?? []
                if skipped.isEmpty {
                    notice = "Нечего обнулять: остатки уже нулевые"
                } else {
                    notice = "Нечего обнулять.\n\n" + Self.skippedText(skipped)
                }
                return
            }
            // Сервер отдаёт в items не больше 300 строк: общий счётчик — zeroed.
            let total = max(r.zeroed ?? 0, items.count)
            plan = Plan(ids: ids, count: total, message: Self.planText(r, total: total))
        } catch is CancellationError {
        } catch {
            noticeIsError = true
            notice = error.localizedDescription
        }
    }

    /// Шаг 2: реальное обнуление. true — запрос прошёл (список/карточку перечитать).
    func confirm(ids: [Int]) async -> Bool {
        guard !busy, !ids.isEmpty else { return false }
        busy = true
        defer { busy = false }
        do {
            let r = try await API.shared.zeroStock(productIds: ids, dryRun: false, keys: keys)
            noticeIsError = false
            notice = Self.messageOrDefault(r.message, "Остаток обнулён")
            return true
        } catch is CancellationError {
            return false
        } catch {
            noticeIsError = true
            notice = error.localizedDescription
            return false
        }
    }

    private static func messageOrDefault(_ m: String?, _ fallback: String) -> String {
        let t = (m ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }

    /// Остаток ДО — строка сервера ("12.5"): показываем с запятой и без хвостовых нулей.
    private static func qtyText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "?" }
        if let d = Decimal(string: raw) { return QtyFmt.qty(d) }
        return raw
    }

    static func skippedText(_ skipped: [ZeroStockSkip]) -> String {
        var lines: [String] = ["Пропущены:"]
        for s in skipped.prefix(10) {
            let name = (s.name ?? "").isEmpty ? "Товар №\(s.id ?? 0)" : (s.name ?? "")
            let reason = (s.reason ?? "").isEmpty ? "" : " — \(s.reason ?? "")"
            lines.append("\(name)\(reason)")
        }
        if skipped.count > 10 { lines.append("и ещё \(skipped.count - 10)") }
        return lines.joined(separator: "\n")
    }

    static func planText(_ r: ZeroStockResult, total: Int) -> String {
        var lines: [String] = []
        let items = r.items ?? []
        for it in items.prefix(showLimit) {
            let name = (it.name ?? "").isEmpty ? "Товар №\(it.id ?? 0)" : (it.name ?? "")
            lines.append("\(name): \(qtyText(it.qty)) → 0")
        }
        if total > showLimit { lines.append("и ещё \(total - showLimit)") }
        let skipped = r.skipped ?? []
        if !skipped.isEmpty {
            lines.append("")
            lines.append(skippedText(skipped))
        }
        return lines.joined(separator: "\n")
    }

    /// «у 1 товара», «у 5 товаров».
    static func goodsWord(_ n: Int) -> String {
        (n % 10 == 1 && n % 100 != 11) ? "товара" : "товаров"
    }
}

/// Два alert-а сценария: подтверждение и итог. Подключается одним вызовом к любому экрану.
struct ZeroStockAlerts: ViewModifier {
    @ObservedObject var flow: ZeroStockFlow
    let onDone: () -> Void

    private var planTitle: String {
        let n = flow.plan?.count ?? 0
        return "Обнулить остаток у \(n) \(ZeroStockFlow.goodsWord(n))?"
    }

    func body(content: Content) -> some View {
        content
            .alert(planTitle, isPresented: Binding(
                get: { flow.plan != nil },
                set: { if !$0 { flow.plan = nil } }
            )) {
                Button("Обнулить", role: .destructive) {
                    // Копируем до закрытия окна: сеттер выше обнулит plan.
                    let ids = flow.plan?.ids ?? []
                    let done = onDone
                    Task { if await flow.confirm(ids: ids) { done() } }
                }
                Button("Отмена", role: .cancel) { flow.plan = nil }
            } message: {
                Text(flow.plan?.message ?? "")
            }
            .alert(flow.noticeIsError ? "Не получилось" : "Готово", isPresented: Binding(
                get: { flow.notice != nil },
                set: { if !$0 { flow.notice = nil } }
            )) {
                Button("Понятно", role: .cancel) { flow.notice = nil }
            } message: {
                Text(flow.notice ?? "")
            }
    }
}

extension View {
    func zeroStockAlerts(_ flow: ZeroStockFlow, onDone: @escaping () -> Void) -> some View {
        modifier(ZeroStockAlerts(flow: flow, onDone: onDone))
    }
}
