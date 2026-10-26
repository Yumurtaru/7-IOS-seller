import Foundation

// ============================================================================
//  «Помощник Yumurta» — ИИ-ассистент поддержки (сайт, волна А100):
//  routes/assistant.php + core/Assistant.php (present()). Мобильный конверт
//  {success, data, meta, error: {message, details}}. Все модели терпимы к
//  отсутствующим полям и числам строкой: разошедшееся поле не роняет экран.
//
//  GET  /api/v1/assistant/status?audience=seller
//  GET  /api/v1/assistant/chat?id=&audience=
//  POST /api/v1/assistant/messages {chat_id?, text, audience, page?}
//  POST /api/v1/assistant/rate {chat_id, message_id, rating 1|-1|0}
//  POST /api/v1/assistant/handoff {chat_id, audience}
// ============================================================================

private extension KeyedDecodingContainer {
    func str(_ k: Key) -> String? { (try? decodeIfPresent(String.self, forKey: k)) ?? nil }
    func int(_ k: Key) -> Int? { (try? decode(LenientInt.self, forKey: k))?.wrappedValue }
    func bool(_ k: Key) -> Bool { (try? decode(LenientBool.self, forKey: k))?.wrappedValue ?? false }
}

/// Включён ли помощник и чем он здоровается. left_today = nil — без ограничения.
struct AssistantStatus: Decodable {
    let enabled: Bool
    /// seller | client | guest — кем сервер нас посчитал (seller — есть вход в панель).
    let audience: String
    let name: String
    let greeting: String
    let disclaimer: String
    let suggestions: [String]
    let canHandoff: Bool
    let loginRequired: Bool
    let leftToday: Int?
    let maxLength: Int

    enum CodingKeys: String, CodingKey {
        case enabled, audience, name, greeting, disclaimer, suggestions
        case canHandoff = "can_handoff", loginRequired = "login_required"
        case leftToday = "left_today", maxLength = "max_length"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.bool(.enabled)
        audience = c.str(.audience) ?? ""
        name = c.str(.name) ?? ""
        greeting = c.str(.greeting) ?? ""
        disclaimer = c.str(.disclaimer) ?? ""
        suggestions = ((try? c.decodeIfPresent([String].self, forKey: .suggestions)) ?? nil) ?? []
        canHandoff = c.bool(.canHandoff)
        loginRequired = c.bool(.loginRequired)
        leftToday = c.int(.leftToday)
        maxLength = c.int(.maxLength) ?? 0
    }
}

/// Источник ответа: url ОТНОСИТЕЛЬНЫЙ («/help/…»); cited — уже есть ссылкой в тексте.
struct AssistantSource: Decodable, Equatable {
    let title: String?
    let url: String?
    let cited: Bool

    enum CodingKeys: String, CodingKey { case title, url, cited }

    init(title: String?, url: String?, cited: Bool) {
        self.title = title; self.url = url; self.cited = cited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.str(.title)
        url = c.str(.url)
        cited = c.bool(.cited)
    }
}

/// Сообщение переписки: role user | assistant; rating 1 | -1 | nil (только у ответов).
/// id < 0 — вопрос на экране, ещё не подтверждённый сервером.
struct AssistantMessage: Decodable, Identifiable, Equatable {
    let id: Int
    let role: String
    let text: String
    let sources: [AssistantSource]
    var rating: Int?
    let createdAt: String?

    var isUser: Bool { role == "user" }

    enum CodingKeys: String, CodingKey {
        case id, role, text, sources, rating
        case createdAt = "created_at"
    }

    init(id: Int, role: String, text: String, sources: [AssistantSource] = [], rating: Int? = nil, createdAt: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.sources = sources; self.rating = rating; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        role = c.str(.role) ?? "assistant"
        text = c.str(.text) ?? ""
        sources = ((try? c.decodeIfPresent([AssistantSource].self, forKey: .sources)) ?? nil) ?? []
        rating = c.int(.rating)
        createdAt = c.str(.createdAt)
    }
}

/// POST messages → {chat_id, question, reply, left_today}.
struct AssistantAskResult: Decodable {
    let chatId: String?
    let question: AssistantMessage?
    let reply: AssistantMessage?
    let leftToday: Int?

    enum CodingKeys: String, CodingKey {
        case question, reply
        case chatId = "chat_id", leftToday = "left_today"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chatId = c.str(.chatId)
        question = (try? c.decodeIfPresent(AssistantMessage.self, forKey: .question)) ?? nil
        reply = (try? c.decodeIfPresent(AssistantMessage.self, forKey: .reply)) ?? nil
        leftToday = c.int(.leftToday)
    }
}

/// GET chat → {chat: {id, status open|handed, handoff_kind}, messages}.
struct AssistantChatHistory: Decodable {
    let status: String?
    let messages: [AssistantMessage]

    enum CodingKeys: String, CodingKey { case chat, messages }
    enum ChatKeys: String, CodingKey { case status }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let chat = try? c.nestedContainer(keyedBy: ChatKeys.self, forKey: .chat)
        status = chat?.str(.status)
        messages = ((try? c.decodeIfPresent([AssistantMessage].self, forKey: .messages)) ?? nil) ?? []
    }
}

/// POST rate → {rating: 1 | -1 | null}.
struct AssistantRateResult: Decodable {
    let rating: Int?
    enum CodingKeys: String, CodingKey { case rating }
    init(from decoder: Decoder) throws {
        rating = (try decoder.container(keyedBy: CodingKeys.self)).int(.rating)
    }
}

/// POST handoff → {kind: shop_support | ticket, id, url, already}.
struct AssistantHandoffResult: Decodable {
    let kind: String
    let id: Int
    let already: Bool

    enum CodingKeys: String, CodingKey { case kind, id, already }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.str(.kind) ?? ""
        id = c.int(.id) ?? 0
        already = c.bool(.already)
    }
}

/// Отказ ручки помощника: HTTP-статус, текст для человека и — у 502 — id
/// переписки (error.details.chat_id: вопрос сохранён, переписка продолжается).
struct AssistantError: LocalizedError {
    let status: Int
    let message: String
    let chatId: String?
    var errorDescription: String? { message }
}

/// Конверт ответа: мобильный {success, data, error:{message, details}} и, на всякий
/// случай, кабинетный {ok, data, error, errors} — сервер отдаёт v1, но 429 лимитера
/// и исключения могли бы прийти и в другом виде.
struct AssistantEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let message: String?
    let chatId: String?

    enum CodingKeys: String, CodingKey { case success, ok, data, error, errors }
    enum ErrorKeys: String, CodingKey { case message, details }
    enum DetailKeys: String, CodingKey { case chatId = "chat_id" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = c.bool(.success) || c.bool(.ok)
        data = (try? c.decodeIfPresent(T.self, forKey: .data)) ?? nil
        var msg: String?
        var chat: String?
        if let s = c.str(.error) {
            msg = s
        } else if let e = try? c.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error) {
            msg = e.str(.message)
            chat = (try? e.nestedContainer(keyedBy: DetailKeys.self, forKey: .details))?.str(.chatId)
        }
        if chat == nil {
            chat = (try? c.nestedContainer(keyedBy: DetailKeys.self, forKey: .errors))?.str(.chatId)
        }
        message = msg
        chatId = AssistantText.isChatId(chat) ? chat : nil
    }

    /// Разбор ответа ручки: данные или AssistantError с текстом сервера
    /// (без текста — понятная подпись по коду, как у остальных экранов).
    static func unwrap(status: Int, data: Data) throws -> T {
        let env = try? JSONDecoder().decode(AssistantEnvelope<T>.self, from: data)
        if (200..<300).contains(status), let env, env.success, let d = env.data { return d }
        if (200..<300).contains(status) { throw APIError.decoding }
        let text = env?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw AssistantError(status: status,
                             message: text.isEmpty ? API.statusText(status) : text,
                             chatId: env?.chatId)
    }
}
