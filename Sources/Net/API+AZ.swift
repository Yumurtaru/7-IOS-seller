import Foundation

// ============================================================================
//  АZ (сайт А617): новые ручки продавца. Старый сервер их не знает — вызывающий
//  молча прячет новое (404/405/любая ошибка), см. комментарии у каждого экрана.
// ============================================================================

extension API {
    /// GET /api/seller/settings/telegram → {enabled, bot, connected, chat_id, chat_kind, can_link}.
    func telegramState() async throws -> TelegramState {
        try await get("api/seller/settings/telegram", as: TelegramState.self)
    }

    /// POST /api/seller/settings/telegram/link (тело {}) → {code, bot, url, group_url, ttl}.
    /// 403 — не владелец, 503 — бот не настроен, 429 — лимит: текст сервера в APIError.
    func telegramLink() async throws -> TelegramLink {
        try await post("api/seller/settings/telegram/link", body: [:], as: TelegramLink.self)
    }

    /// GET /api/seller/slots/day?date=ГГГГ-ММ-ДД — журнал записи на день (все окна всех услуг).
    /// getDetailed: проба пункта «Журнал» отличает 404/405 (старый сервер) от обрыва по статусу.
    func slotsDay(date: String) async throws -> SlotDay {
        try await getDetailed("api/seller/slots/day", query: ["date": date], as: SlotDay.self)
    }

    /// POST /api/seller/loss-control/review — {key, status} или {keys:[…], status}.
    /// status: "ok" | "violation" | "" (снять отметку); note обязательна для violation.
    /// Запрос идемпотентен: после обрыва можно повторить.
    func reviewLoss(key: String? = nil, keys: [String]? = nil, status: String, note: String? = nil) async throws -> LossReviewAck {
        var body: [String: Any?] = ["status": status]
        if let keys, !keys.isEmpty { body["keys"] = keys } else if let key { body["key"] = key }
        if let note, !note.isEmpty { body["note"] = note }
        return try await post("api/seller/loss-control/review", body: body, as: LossReviewAck.self)
    }
}
