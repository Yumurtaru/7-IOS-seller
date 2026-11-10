import Foundation

// ============================================================================
//  «Помощник Yumurta»: когда показывать входы (дашборд, «Ещё», «Техподдержка») и
//  как часто перечитывать GET /api/v1/assistant/status. Чистая логика без UI.
//  Тексты те же, что на Android (дословно).
// ============================================================================

enum AssistantGate {
    static let title = "Помощник"
    static let subtitle = "Ответит на вопросы о товарах, складе, кассе и доставке"
    static let offText = "Помощник сейчас выключен — напишите в поддержку"
    static let writeSupport = "Написать в поддержку"

    /// Возврат из фона — не чаще раза в минуту.
    static let minInterval: TimeInterval = 60

    /// Открытие экрана, смена магазина, жест вниз: только защита от двойного запроса подряд.
    static let dedupe: TimeInterval = 2

    /// Пора ли идти на сервер. last = nil — ещё не спрашивали; часы пошли назад — спрашиваем.
    static func due(last: Date?, now: Date, minGap: TimeInterval) -> Bool {
        guard let last else { return true }
        let d = now.timeIntervalSince(last)
        return d < 0 || d >= minGap
    }

    /// Видны ли входы после ответа status. Успех: enabled и audience = seller. Ошибка сети и
    /// прочие сбои (5xx, 401…) — остаётся прежнее состояние (не мигаем); 404 и 405 — старый
    /// сервер без помощника: скрыть.
    static func nextVisible(previous: Bool, failed: Bool, httpCode: Int, enabled: Bool, audience: String?) -> Bool {
        if failed { return (httpCode == 404 || httpCode == 405) ? false : previous }
        return enabled && audience == "seller"
    }

    /// Текст для экрана «выключен»: слово сервера, иначе стандартная фраза.
    static func offText(serverMessage: String?) -> String {
        let t = (serverMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? offText : t
    }
}
