import Foundation

// ============================================================================
//  «Помощник Yumurta» (сайт А100, routes/assistant.php). audience=seller —
//  организация та, что выбрана в сессии (switch-shop), как у /api/seller/*;
//  отдельного заголовка нет. Bearer-запросы проходят middleware csrf без
//  токена страницы (Middleware::csrf). Старый сервер — 404: кнопки нет.
// ============================================================================

extension API {
    func assistantStatus() async throws -> AssistantStatus {
        let (s, d) = try await rawRequest("GET", "api/v1/assistant/status", query: ["audience": AssistantText.audience])
        return try AssistantEnvelope<AssistantStatus>.unwrap(status: s, data: d)
    }

    func assistantChat(id: String) async throws -> AssistantChatHistory {
        let (s, d) = try await rawRequest("GET", "api/v1/assistant/chat",
                                          query: ["id": id, "audience": AssistantText.audience])
        return try AssistantEnvelope<AssistantChatHistory>.unwrap(status: s, data: d)
    }

    /// Вопрос: ответ модели — 10–30 с, ждём до 60. chatId = nil — новая переписка.
    /// 502 — AssistantError с chatId (вопрос сохранён).
    func assistantAsk(text: String, chatId: String?) async throws -> AssistantAskResult {
        let body: [String: Any?] = ["text": text, "audience": AssistantText.audience,
                                    "chat_id": chatId, "page": AssistantText.page]
        let (s, d) = try await rawRequest("POST", "api/v1/assistant/messages", body: body, long: true)
        return try AssistantEnvelope<AssistantAskResult>.unwrap(status: s, data: d)
    }

    /// rating: 1 | -1 | 0 (0 — снять оценку).
    func assistantRate(chatId: String, messageId: Int, rating: Int) async throws -> AssistantRateResult {
        let body: [String: Any?] = ["chat_id": chatId, "message_id": messageId, "rating": rating,
                                    "audience": AssistantText.audience]
        let (s, d) = try await rawRequest("POST", "api/v1/assistant/rate", body: body)
        return try AssistantEnvelope<AssistantRateResult>.unwrap(status: s, data: d)
    }

    func assistantHandoff(chatId: String) async throws -> AssistantHandoffResult {
        let body: [String: Any?] = ["chat_id": chatId, "audience": AssistantText.audience]
        let (s, d) = try await rawRequest("POST", "api/v1/assistant/handoff", body: body)
        return try AssistantEnvelope<AssistantHandoffResult>.unwrap(status: s, data: d)
    }
}
