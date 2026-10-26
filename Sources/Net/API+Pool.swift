import Foundation

// ============================================================================
//  «Курьеры Yumurta» — ручки заведения /api/v1/seller/pool/* (волны А77–А78,
//  routes/courier_pool.php). Право сотрудника «Заказы»; загрузка и удаление
//  QR СБП — ещё и «Настройки». Создание вызова и расчёты — с ключом повтора
//  idempotency_key в теле (без него сервер отвечает 422).
// ============================================================================

extension API {
    private static let poolBase = "api/v1/seller/pool"

    /// Подсказки окна вызова: по заказу (orderId) или для вызова вручную
    /// (goodsAmount — сумма товаров, для цены доставки по тарифу).
    /// extra (А80) — машина и маршрут: trip, vehicle_class, loaders, cargo_kg,
    /// dest_city_id; для водителей межгорода — payment_mode=prepaid или
    /// collect_amount + fee_payer (вызов вручную). Старый сервер их не читает.
    func poolQuote(orderId: Int? = nil, goodsAmount: String? = nil,
                   extra: [String: String] = [:]) async throws -> PoolQuote {
        var q: [String: String] = extra
        if let o = orderId, o > 0 { q["order_id"] = String(o) }
        if let g = goodsAmount, !g.isEmpty { q["goods_amount"] = g }
        return try await get(Self.poolBase + "/quote", query: q, as: PoolQuote.self)
    }

    /// Вызвать курьера: по заказу {order_id, …} или вручную {drop_address, client_phone, …}.
    /// Отказ — APIDetailedError: 422 с ошибками полей, 409 price_changed (новая цена в fields.fee).
    func poolCreateCall(body: [String: Any?], idempotencyKey: String) async throws -> PoolCall {
        try await postBodyKeyed(Self.poolBase + "/calls", body: body, idempotencyKey: idempotencyKey,
                                detailedErrors: true, as: PoolCall.self)
    }

    /// Города для «Межгород — куда»: GET /api/v1/cities (все активные, без
    /// авторизации, конверт v1 {success, data}). Отдельным запросом: общий
    /// разбор ждёт конверт кабинета {ok, data}.
    func poolCities() async throws -> [PoolCity] {
        guard let url = URL(string: API.base + "/api/v1/cities") else { throw APIError.network }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw e.code == .timedOut ? APIError.timeout : APIError.network
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.network
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status >= 500 ? APIError.http(status) : APIError.server(API.statusText(status)) }
        struct Env: Decodable { let data: [PoolLossy<PoolCity>]? }
        guard let env = try? JSONDecoder().decode(Env.self, from: data) else { throw APIError.decoding }
        return (env.data ?? []).compactMap { $0.value }.filter { $0.id > 0 && !($0.name ?? "").isEmpty }
    }

    /// Список вызовов: status = active | closed | all; страница по 30.
    func poolCalls(status: String, page: Int) async throws -> [PoolCall] {
        try await get(Self.poolBase + "/calls", query: ["status": status, "page": String(page)], as: [PoolCall].self)
    }

    func poolCall(id: Int) async throws -> PoolCall {
        try await get(Self.poolBase + "/calls/\(id)", as: PoolCall.self)
    }

    func poolCancel(id: Int, reason: String) async throws -> PoolCall {
        try await post(Self.poolBase + "/calls/\(id)/cancel", body: ["reason": reason], as: PoolCall.self)
    }

    func poolUnassign(id: Int, reason: String) async throws -> PoolCall {
        try await post(Self.poolBase + "/calls/\(id)/unassign", body: ["reason": reason], as: PoolCall.self)
    }

    /// Поднять цену, пока ищем; по «Никто не взял» — повторить поиск (fee можно не слать).
    func poolChangeFee(id: Int, fee: String?) async throws -> PoolCall {
        try await post(Self.poolBase + "/calls/\(id)/fee", body: ["fee": fee], as: PoolCall.self)
    }

    func poolRate(id: Int, rating: Int, comment: String) async throws -> PoolCall {
        try await post(Self.poolBase + "/calls/\(id)/rate",
                       body: ["rating": rating, "comment": comment.isEmpty ? nil : comment], as: PoolCall.self)
    }

    /// «Проблема с доставкой»: без фото — JSON, с фото — multipart (поле photo).
    func poolProblem(id: Int, reason: String, comment: String, amount: String, photoJPEG: Data?) async throws -> PoolCall {
        let path = Self.poolBase + "/calls/\(id)/problem"
        if let jpeg = photoJPEG {
            return try await uploadForm(path, fields: ["reason": reason, "comment": comment, "amount": amount],
                                        fileField: "photo", filename: "problem.jpg", mime: "image/jpeg",
                                        fileData: jpeg, idempotencyKey: nil, as: PoolCall.self)
        }
        return try await post(path, body: ["reason": reason, "comment": comment, "amount": amount], as: PoolCall.self)
    }

    /// Оплата клиента по QR заведения пришла (true) / не пришла (false).
    func poolConfirmQr(id: Int, received: Bool) async throws -> PoolCall {
        try await post(Self.poolBase + "/calls/\(id)/qr", body: ["received": received], as: PoolCall.self)
    }

    /// А81: «Пожаловаться на курьера» {reason, comment?} — без денег (деньги — «Проблема
    /// с доставкой»). Ответ — карточка вызова (+ complaint_id, его не читаем). Отказ —
    /// APIDetailedError: 409 complaint_exists / no_courier / too_old, 422 reason|comment,
    /// 503 unavailable. Ключа повтора у сервера для жалоб нет: дубль отсекает «одна
    /// жалоба от заведения на вызов» (повтор — 409 complaint_exists).
    func poolComplaint(id: Int, reason: String, comment: String) async throws -> PoolCall {
        try await postDetailed(Self.poolBase + "/calls/\(id)/complaint",
                               body: ["reason": reason, "comment": comment.isEmpty ? nil : comment], as: PoolCall.self)
    }

    /// А81: правило сервиса и причины жалоб — GET /api/v1/pool/rules (без входа, конверт
    /// v1 {success, data}). Кэш на время работы приложения; ошибку не кэшируем.
    func poolRules() async throws -> PoolRules {
        if let r = PoolRulesCache.shared.get() { return r }
        guard let url = URL(string: API.base + "/api/v1/pool/rules") else { throw APIError.network }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw e.code == .timedOut ? APIError.timeout : APIError.network
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.network
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status >= 500 ? APIError.http(status) : APIError.server(API.statusText(status)) }
        struct Env: Decodable { let data: PoolRules? }
        guard let env = try? JSONDecoder().decode(Env.self, from: data), let rules = env.data else { throw APIError.decoding }
        // Без причин окно жалобы бесполезно — как ошибка («Повторить»), в кэш не кладём.
        guard !rules.courierReasons.isEmpty else { throw APIError.server("Не удалось загрузить причины жалобы") }
        PoolRulesCache.shared.set(rules)
        return rules
    }

    /// Фото курьера (картинка, не JSON) — с Bearer, во временный файл.
    func poolCourierPhoto(callId: Int) async throws -> Data {
        try await poolImage(Self.poolBase + "/calls/\(callId)/courier-photo")
    }

    /// QR СБП заведения (картинка). Нет QR — сервер отвечает 404 JSON → ошибка.
    func poolQrImage() async throws -> Data {
        try await poolImage(Self.poolBase + "/qr")
    }

    private func poolImage(_ path: String) async throws -> Data {
        let url = try await downloadFile(path, fallbackName: "pool-" + UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { throw APIError.decoding }
        return data
    }

    func poolUploadQr(jpeg: Data) async throws -> PoolQrAck {
        try await upload(Self.poolBase + "/qr", field: "qr", filename: "qr.jpg", mime: "image/jpeg",
                         fileData: jpeg, as: PoolQrAck.self)
    }

    func poolDeleteQr() async throws -> PoolQrAck {
        try await delete(Self.poolBase + "/qr", as: PoolQrAck.self)
    }

    /// Курьеры с расчётами (сальдо, ждущие подтверждения, оплаты по QR).
    func poolCouriers() async throws -> [PoolCourierBalance] {
        try await get(Self.poolBase + "/couriers", as: [PoolCourierBalance].self)
    }

    /// История расчётов с курьером, страница по 50.
    func poolLedger(courierId: Int, page: Int) async throws -> [PoolLedgerEntry] {
        try await get(Self.poolBase + "/ledger", query: ["courier_id": String(courierId), "page": String(page)],
                      as: [PoolLedgerEntry].self)
    }

    /// kind: cash_received («Получили от курьера», сразу) | fee_paid («Отдали за доставку», подтверждает курьер).
    /// А91: «Отдали за доставку» больше fee_max — 422 с объяснением в error («Вы ничего не должны
    /// курьеру за доставку: …»): показываем только его, без errors.amount («не больше 0.00»).
    /// Остальные отказы — APIError.server с прежним текстом, как раньше.
    func poolSettle(courierId: Int, kind: String, amount: String, note: String,
                    idempotencyKey: String) async throws -> PoolSettleResult {
        let feePaid = kind == "fee_paid"
        do {
            return try await postBodyKeyed(Self.poolBase + "/settlements",
                                           body: ["courier_id": courierId, "kind": kind, "amount": amount,
                                                  "note": note.isEmpty ? nil : note],
                                           idempotencyKey: idempotencyKey, detailedErrors: feePaid,
                                           as: PoolSettleResult.self)
        } catch let e as APIDetailedError {
            if e.status == 422, let t = e.serverError?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                throw APIError.server(t)
            }
            throw APIError.server(e.message)
        }
    }

    /// Ответ на «курьер сдал деньги»: подтвердить или отклонить.
    func poolDecide(entryId: Int, approve: Bool) async throws -> PoolSettleResult {
        try await post(Self.poolBase + "/settlements/\(entryId)/" + (approve ? "confirm" : "reject"),
                       as: PoolSettleResult.self)
    }
}

/// А81: правило и причины жалоб меняются редко — держим до перезапуска приложения.
final class PoolRulesCache: @unchecked Sendable {
    static let shared = PoolRulesCache()
    private let lock = NSLock()
    private var rules: PoolRules?

    func get() -> PoolRules? {
        lock.lock(); defer { lock.unlock() }
        return rules
    }

    func set(_ r: PoolRules) {
        lock.lock(); defer { lock.unlock() }
        rules = r
    }

    /// Сервер не принял причину — список устарел: при следующем открытии перечитаем.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        rules = nil
    }
}
