import Foundation

// ============================================================================
//  Техподдержка площадки — сторона продавца (сервер: волна А66,
//  routes/shop_support.php). Организация — та, что выбрана в сессии
//  (как у всех /api/seller/*), авторизация — обычный Bearer.
// ============================================================================

extension API {

    /// Без afterId/beforeId — последние `limit` сообщений; beforeId — более
    /// ранняя страница; afterId — новые (до 200). Всегда по возрастанию id.
    func supportMessages(afterId: Int? = nil, beforeId: Int? = nil, limit: Int = 50) async throws -> ShopSupportPage {
        var q: [String: String] = ["limit": String(limit)]
        if let a = afterId, a > 0 { q["after_id"] = String(a) }
        if let b = beforeId, b > 0 { q["before_id"] = String(b) }
        return try await get("api/seller/support/messages", query: q, as: ShopSupportPage.self)
    }

    /// Текстовое сообщение. seenUpTo — id последнего сообщения, показанного на
    /// экране (двигает отметку прочтения отправителя). Ключ повтора — один на
    /// нажатие «Отправить», при повторе той же отправки — тот же.
    func sendSupportMessage(body: String, seenUpTo: Int?, idempotencyKey: String) async throws -> ShopSupportSendResult {
        var payload: [String: Any?] = ["body": body]
        if let s = seenUpTo, s > 0 { payload["seen_up_to"] = s }
        return try await postIdempotent("api/seller/support/messages", body: payload,
                                        idempotencyKey: idempotencyKey, as: ShopSupportSendResult.self)
    }

    /// Сообщение с одним вложением (фото JPG или PDF) — multipart, поле file.
    func sendSupportFile(body: String, seenUpTo: Int?, filename: String, mime: String,
                         data: Data, idempotencyKey: String) async throws -> ShopSupportSendResult {
        var fields: [String: String] = ["body": body]
        if let s = seenUpTo, s > 0 { fields["seen_up_to"] = String(s) }
        return try await uploadForm("api/seller/support/messages", fields: fields,
                                    fileField: "file", filename: filename, mime: mime, fileData: data,
                                    idempotencyKey: idempotencyKey, as: ShopSupportSendResult.self)
    }

    /// Отметить прочитанным всё до upToId включительно.
    func markSupportRead(upToId: Int) async throws -> ShopSupportThread {
        try await post("api/seller/support/read", body: ["up_to_id": upToId], as: ShopSupportThread.self)
    }

    /// Дешёвый счётчик для бейджа в «Ещё».
    func supportUnread() async throws -> ShopSupportUnread {
        try await get("api/seller/support/unread", as: ShopSupportUnread.self)
    }
}
