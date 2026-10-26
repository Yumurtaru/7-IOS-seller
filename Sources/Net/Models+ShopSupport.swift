import Foundation

// ============================================================================
//  Переписка организации с поддержкой площадки (сервер: волна А66,
//  routes/shop_support.php + core/ShopSupport.php). Одна переписка на
//  организацию. Все модели терпимы к отсутствующим полям и числам строкой:
//  разошедшееся поле не должно ронять весь экран.
//
//  GET  /api/seller/support/messages?after_id=&before_id=&limit=
//       → {items:[Msg], has_more, thread, support_name, max_body, max_file, max_image}
//  POST /api/seller/support/messages  → {message: Msg, thread}
//  POST /api/seller/support/read {up_to_id} → thread
//  GET  /api/seller/support/unread → {unread, last_message_id}
// ============================================================================

/// Вложение сообщения: url ОТНОСИТЕЛЬНЫЙ («/assets/uploads/…»), type image | pdf.
struct ShopSupportAttachment: Decodable, Hashable {
    let url: String?
    let type: String?
    let name: String?

    enum CodingKeys: String, CodingKey { case url, type, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        type = try? c.decodeIfPresent(String.self, forKey: .type)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
    }

    var isPdf: Bool { (type ?? "").lowercased() == "pdf" }

    /// Полный адрес. API.imageURL не подходит: он сам дописывает
    /// «/assets/uploads/», а сервер здесь отдаёт путь уже с ним.
    var fullURL: URL? {
        guard let raw = url?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let s: String
        if raw.hasPrefix("http") {
            s = raw
        } else if raw.hasPrefix("/") {
            s = API.base + raw
        } else {
            s = API.base + "/" + raw
        }
        return URL(string: s) ?? s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
    }

    /// Подпись строки PDF.
    var displayName: String {
        let n = (name ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        return isPdf ? "Документ.pdf" : "Фото"
    }
}

/// Сообщение переписки (как его видит продавец).
struct ShopSupportMessage: Decodable, Identifiable {
    let id: Int
    /// "admin" — поддержка площадки, "seller" — организация.
    let side: String
    let mine: Bool
    let author: String?
    let body: String
    let attachment: ShopSupportAttachment?
    let broadcast: Bool
    let createdAt: String?
    /// Только для своих сообщений: прочитала ли их другая сторона.
    let read: Bool

    enum CodingKeys: String, CodingKey {
        case id, side, mine, author, body, attachment, broadcast, read
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try c.decode(LenientInt.self, forKey: .id)).wrappedValue ?? 0
        let s = (try? c.decodeIfPresent(String.self, forKey: .side)) ?? nil
        side = s ?? ""
        let m = (try c.decode(LenientBool.self, forKey: .mine)).wrappedValue
        // Нет поля mine (старый ответ) — своё то, что написала организация.
        mine = m ?? (side == "seller")
        author = (try? c.decodeIfPresent(String.self, forKey: .author)) ?? nil
        body = ((try? c.decodeIfPresent(String.self, forKey: .body)) ?? nil) ?? ""
        attachment = (try? c.decodeIfPresent(ShopSupportAttachment.self, forKey: .attachment)) ?? nil
        broadcast = (try c.decode(LenientBool.self, forKey: .broadcast)).wrappedValue ?? false
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil
        read = (try c.decode(LenientBool.self, forKey: .read)).wrappedValue ?? false
    }
}

/// Шапка переписки.
struct ShopSupportThread: Decodable {
    let status: String
    let unread: Int
    let lastMessageId: Int
    let sellerReadId: Int
    let adminReadId: Int

    enum CodingKeys: String, CodingKey {
        case status, unread
        case lastMessageId = "last_message_id"
        case sellerReadId = "seller_read_id"
        case adminReadId = "admin_read_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let st = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        status = st ?? "open"
        unread = (try c.decode(LenientInt.self, forKey: .unread)).wrappedValue ?? 0
        lastMessageId = (try c.decode(LenientInt.self, forKey: .lastMessageId)).wrappedValue ?? 0
        sellerReadId = (try c.decode(LenientInt.self, forKey: .sellerReadId)).wrappedValue ?? 0
        adminReadId = (try c.decode(LenientInt.self, forKey: .adminReadId)).wrappedValue ?? 0
    }

    var isClosed: Bool { status == "closed" }
}

/// Страница сообщений (по возрастанию id).
struct ShopSupportPage: Decodable {
    let items: [ShopSupportMessage]
    let hasMore: Bool
    let thread: ShopSupportThread?
    let supportName: String?
    let maxBody: Int?
    let maxFile: Int?
    let maxImage: Int?

    enum CodingKeys: String, CodingKey {
        case items, thread
        case hasMore = "has_more"
        case supportName = "support_name"
        case maxBody = "max_body"
        case maxFile = "max_file"
        case maxImage = "max_image"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = ((try? c.decodeIfPresent([ShopSupportMessage].self, forKey: .items)) ?? nil) ?? []
        hasMore = (try c.decode(LenientBool.self, forKey: .hasMore)).wrappedValue ?? false
        thread = (try? c.decodeIfPresent(ShopSupportThread.self, forKey: .thread)) ?? nil
        supportName = (try? c.decodeIfPresent(String.self, forKey: .supportName)) ?? nil
        maxBody = (try c.decode(LenientInt.self, forKey: .maxBody)).wrappedValue
        maxFile = (try c.decode(LenientInt.self, forKey: .maxFile)).wrappedValue
        maxImage = (try c.decode(LenientInt.self, forKey: .maxImage)).wrappedValue
    }
}

/// Ответ на отправку.
struct ShopSupportSendResult: Decodable {
    let message: ShopSupportMessage?
    let thread: ShopSupportThread?

    enum CodingKeys: String, CodingKey { case message, thread }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? c.decodeIfPresent(ShopSupportMessage.self, forKey: .message)) ?? nil
        thread = (try? c.decodeIfPresent(ShopSupportThread.self, forKey: .thread)) ?? nil
    }
}

/// Бейдж непрочитанного.
struct ShopSupportUnread: Decodable {
    let unread: Int
    let lastMessageId: Int

    enum CodingKeys: String, CodingKey {
        case unread
        case lastMessageId = "last_message_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unread = (try c.decode(LenientInt.self, forKey: .unread)).wrappedValue ?? 0
        lastMessageId = (try c.decode(LenientInt.self, forKey: .lastMessageId)).wrappedValue ?? 0
    }
}
