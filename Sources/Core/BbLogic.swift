import Foundation

// ============================================================================
//  ВВ (сайт А619–А918, ответ на П-66): чистая логика новых отказов и признаков
//  сервера для кабинета продавца — без сети и экранов.
//   1. товар скрыт модератором (moderation_hidden / moderation_reason, bulk moderation_blocked)
//   2. пауза администратором (settings.pause.admin, 409 admin_paused)
//   3. «Курьеры Yumurta» (право «Курьеры», «Проблема с доставкой» без суммы для «Не сдал деньги»)
//  Тексты — дословно те же, что на Android (core/BbLogic.kt).
//  Принцип: новое поведение включается только по признаку в самом ответе
//  (поле есть / пришёл код ошибки); старый сервер — всё как раньше.
// ============================================================================

enum Bb {
    // ── 1. Скрыт модератором ────────────────────────────────────────────────
    static let moderationBadge = "Скрыт модератором"
    static let moderationNote =
        "Товар скрыт модератором площадки. Вернуть его в продажу можно только через администратора — напишите в поддержку."
    static let supportButton = "Написать в поддержку"

    /// Подпись статуса в списке: «Скрыт модератором» / «скрыт» (сам продавец) / nil.
    static func hiddenLabel(status: String?, moderationHidden: Bool) -> String? {
        if moderationHidden { return moderationBadge }
        if status == "hidden" { return "скрыт" }
        return nil
    }

    /// «Причина: …» из moderation_reason; пусто — nil.
    static func moderationReasonLine(_ reason: String?) -> String? {
        let r = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? nil : "Причина: " + r
    }

    /// Статус для тела сохранения карточки: у скрытого модератором товара статус НЕ шлём
    /// (сервер всё равно оставит hidden, а ключ статуса создал бы вид, что включилось).
    static func statusForSave(hidden: Bool, moderationHidden: Bool) -> String? {
        if moderationHidden { return nil }
        return hidden ? "hidden" : "active"
    }

    /// Текст после массового действия: `message` сервера дословно; нет текста, но есть
    /// moderation_blocked — свой запасной. Ничего нет — nil.
    static func bulkNotice(message: String?, blocked: [Int]?) -> String? {
        let m = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        let n = blocked?.count ?? 0
        return n > 0 ? "Не показано: \(n) — скрыто модератором площадки" : nil
    }

    // ── 2. Пауза администратором ────────────────────────────────────────────
    static let adminPaused = "Приём остановлен администратором площадки — напишите в поддержку"

    /// Машинный код 409 POST /settings/status.
    static func isAdminPaused(_ error: Error) -> Bool {
        (error as? APIDetailedError)?.code == "admin_paused"
    }

    // ── 3. Курьеры Yumurta ──────────────────────────────────────────────────
    static let couriersRightHint = "Подтверждает сотрудник с правом «Курьеры»"
    static let problemMoneyHint = "По этой причине сумма не указывается — деньги учтены при доставке и расчётах с курьером."

    /// Поле суммы в окне «Проблема с доставкой»: для «Не сдал деньги» (money) его нет.
    static func problemShowsAmount(reason: String) -> Bool { reason != "money" }

    /// Сумма для запроса: money — nil (ключ amount не уходит); иначе как введено (пусто → «0»).
    static func problemAmountToSend(reason: String, amount: String) -> String? {
        if !problemShowsAmount(reason: reason) { return nil }
        let a = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? "0" : a
    }
}
