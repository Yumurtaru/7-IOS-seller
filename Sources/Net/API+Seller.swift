import Foundation

// ============================================================================
//  API+Seller.swift — все endpoints кабинета продавца (сверены с routes/*.php).
// ============================================================================

extension API {

    // ── Auth (routes/auth_seller.php) ────────────────────────────────────────
    /// POST /api/seller/login | /api/kafe/login | /api/service/login.
    /// Ответ: {user, token, redirect}; refresh-токен сервер кладёт в cookie
    /// refresh_token (httpOnly) — достаём его из HTTPCookieStorage и сохраняем
    /// в Keychain для молчаливого продления через /api/v1/auth/refresh.
    func login(panel: String, login: String, password: String) async throws -> LoginResponse {
        let path: String
        switch panel {
        case "kafe":    path = "api/kafe/login"
        case "service": path = "api/service/login"
        // «lodging» отдельной ручки входа не имеет и не должен: в
        // users.account_type значения «жильё» нет (на тип завязаны клиентские
        // приложения), у владельца жилья account_type = seller.
        default:        path = "api/seller/login"
        }
        let res = try await post(path, body: ["login": login, "password": password], as: LoginResponse.self)
        Keychain.set(res.token, for: .accessToken)
        if let url = URL(string: API.base),
           let cookie = HTTPCookieStorage.shared.cookies(for: url)?.first(where: { $0.name == "refresh_token" }),
           !cookie.value.isEmpty {
            Keychain.set(cookie.value, for: .refreshToken)
        }
        API.clearCookies()   // refresh уже в Keychain — cookie на диске не оставляем
        return res
    }

    /// Заявка на регистрацию организации (вход уже выполнен, организации ещё нет).
    func registrationStatus() async throws -> ShopRegistrationStatus {
        try await get("api/shop/registration-status", as: ShopRegistrationStatus.self)
    }

    // ── Мульти-магазин (routes/seller.php) ───────────────────────────────────
    func shops() async throws -> ShopsResponse {
        try await get("api/seller/shops", as: ShopsResponse.self)
    }

    func switchShop(id: Int) async throws -> SwitchShopAck {
        try await post("api/seller/switch-shop", body: ["shop_id": id], as: SwitchShopAck.self)
    }

    /// shops.type активного магазина живёт в GET /api/seller/settings (shop.type).
    func settings() async throws -> SettingsResponse {
        try await get("api/seller/settings", as: SettingsResponse.self)
    }

    /// «Кто я и что мне можно»: тип организации для вкладок + права роли.
    ///
    /// Стартовый экран раньше собирался из GET /api/seller/settings, но эта
    /// ручка отдаёт реквизиты и ИНН и сотруднику без права «Настройки»
    /// закрыта (403) — приложение уходило в ошибку сразу после входа.
    func me() async throws -> MeResponse {
        try await get("api/seller/me", as: MeResponse.self)
    }

    func setShopStatus(_ status: String) async throws -> StatusAck {
        try await post("api/seller/settings/status", body: ["status": status], as: StatusAck.self)
    }

    // ── Дашборд ──────────────────────────────────────────────────────────────
    func dashboard(period: String) async throws -> DashboardData {
        try await get("api/seller/dashboard", query: ["period": period], as: DashboardData.self)
    }

    func newOrdersCount() async throws -> NewCountData {
        try await get("api/seller/orders/new-count", as: NewCountData.self)
    }

    // ── Заказы ───────────────────────────────────────────────────────────────
    func orders(status: String?, payment: String?, page: Int) async throws -> OrdersPage {
        var q = ["page": String(page)]
        if let s = status, !s.isEmpty { q["status"] = s }
        if let p = payment, !p.isEmpty { q["payment"] = p }
        return try await get("api/seller/orders", query: q, as: OrdersPage.self)
    }

    func order(id: Int) async throws -> OrderDetail {
        try await get("api/seller/orders/\(id)", as: OrderDetail.self)
    }

    func setOrderStatus(id: Int, status: String) async throws -> StatusAck {
        try await post("api/seller/orders/\(id)/status", body: ["status": status], as: StatusAck.self)
    }

    func cancelOrder(id: Int, reason: String) async throws -> BoolAck {
        try await post("api/seller/orders/\(id)/cancel", body: ["reason": reason], as: BoolAck.self)
    }

    /// Правка состава заказа: шлём ТОЛЬКО изменённые строки, суммы считает сервер.
    /// Количество уходит строкой: вес 0.375 кг не должен потерять третий знак.
    /// Строки собираем вручную — makeRequest чистит nil только на верхнем уровне,
    /// а nil внутри вложенного словаря уронил бы JSONSerialization.
    /// rev — ревизия, которую видело приложение: при расхождении сервер отвечает
    /// 409, и мы не перезаписываем чужую правку, а перечитываем заказ.
    func editOrderItems(id: Int, rev: Int, reason: String?, lines: [(id: Int, qty: Decimal)]) async throws -> OrderEditResult {
        var body: [String: Any?] = [
            "rev": rev,
            "items": lines.map { ["id": $0.id, "qty": "\($0.qty)"] as [String: Any] },
        ]
        if let r = reason, !r.isEmpty { body["reason"] = r }
        return try await post("api/seller/orders/\(id)/items", body: body, as: OrderEditResult.self)
    }

    func orderChat(id: Int, afterId: Int?) async throws -> [ChatMessage] {
        var q: [String: String] = [:]
        if let a = afterId, a > 0 { q["after_id"] = String(a) }
        return try await get("api/seller/orders/\(id)/chat", query: q, as: [ChatMessage].self)
    }

    func sendChatMessage(orderId: Int, message: String) async throws -> BoolAck {
        try await post("api/seller/orders/\(orderId)/chat", body: ["message": message], as: BoolAck.self)
    }

    // ── Товары (routes/seller_products.php) ──────────────────────────────────
    func products(category: Int?, status: String?, q: String?, page: Int) async throws -> ProductsPage {
        var query = ["page": String(page)]
        if let c = category { query["category"] = String(c) }
        if let s = status, !s.isEmpty { query["status"] = s }
        if let text = q, !text.isEmpty { query["q"] = text }
        return try await get("api/seller/products", query: query, as: ProductsPage.self)
    }

    func product(id: Int) async throws -> ProductDetail {
        try await get("api/seller/products/\(id)", as: ProductDetail.self)
    }

    /// Поля — точно как принимает saveProduct() в core/seller_products.php.
    func saveProduct(id: Int?, fields: [String: Any?]) async throws {
        if let id = id {
            _ = try await put("api/seller/products/\(id)", body: fields, as: BoolAck.self)
        } else {
            // П-27.14: с ключом повтора — «Сохранить» после обрыва не создаёт второй товар.
            _ = try await postKeyed("api/seller/products", body: fields, as: IdAck.self)
        }
    }

    func deleteProduct(id: Int) async throws {
        _ = try await delete("api/seller/products/\(id)", as: BoolAck.self)
    }

    /// Сервер сам инвертирует is_available и возвращает новое значение.
    func toggleAvailability(productId: Int) async throws -> AvailabilityAck {
        try await post("api/seller/products/\(productId)/availability", body: [:], as: AvailabilityAck.self)
    }

    func setPrice(productId: Int, price: Decimal, priceOld: Decimal?) async throws -> PriceAck {
        var body: [String: Any?] = ["price": "\(price)"]
        if let old = priceOld { body["price_old"] = "\(old)" }
        return try await post("api/seller/products/\(productId)/price", body: body, as: PriceAck.self)
    }

    /// action: status(value active|hidden) | category(value id) | delete
    func bulkProducts(ids: [Int], action: String, value: String?) async throws -> AffectedAck {
        try await post("api/seller/products/bulk",
                       body: ["ids": ids, "action": action, "value": value],
                       as: AffectedAck.self)
    }

    func uploadProductPhoto(productId: Int, jpeg: Data) async throws -> PhotoUploadResult {
        try await upload("api/seller/products/\(productId)/photos",
                         field: "photo", filename: "photo.jpg", mime: "image/jpeg",
                         fileData: jpeg, as: PhotoUploadResult.self)
    }

    func deleteProductPhoto(productId: Int, photoId: Int) async throws {
        _ = try await delete("api/seller/products/\(productId)/photos/\(photoId)", as: BoolAck.self)
    }

    func aiDescription(productId: Int) async throws -> AIDescription {
        try await post("api/seller/products/\(productId)/ai-description", body: [:], as: AIDescription.self)
    }

    func categories() async throws -> [SellerCategory] {
        try await get("api/seller/categories", as: [SellerCategory].self)
    }

    func productModifiers(productId: Int) async throws -> [ModifierGroup] {
        try await get("api/seller/products/\(productId)/modifiers", as: [ModifierGroup].self)
    }

    // ── Стоп-лист ────────────────────────────────────────────────────────────
    func stopList() async throws -> [StopListItem] {
        try await get("api/seller/stop-list", as: [StopListItem].self)
    }

    func addToStopList(productId: Int, modifierId: Int?, reason: String?, untilMinutes: Int?) async throws -> IdAck {
        try await post("api/seller/stop-list", body: [
            "product_id": productId,
            "modifier_id": modifierId,
            "reason": reason,
            "until_minutes": untilMinutes,
        ], as: IdAck.self)
    }

    func removeFromStopList(id: Int) async throws {
        _ = try await delete("api/seller/stop-list/\(id)", as: BoolAck.self)
    }

    // ── Услуги / мастера / слоты / записи (routes/seller_services.php) ───────
    func masters() async throws -> [Master] {
        try await get("api/seller/masters", as: [Master].self)
    }

    func createMaster(name: String, bio: String?, specializations: [String]) async throws -> IdAck {
        // П-27.14: ключ повтора — повторное «Создать» после обрыва без дубля мастера.
        try await postKeyed("api/seller/masters",
                            body: ["name": name, "bio": bio, "specializations": specializations],
                            as: IdAck.self)
    }

    func updateMaster(id: Int, name: String, bio: String?, specializations: [String]) async throws {
        _ = try await put("api/seller/masters/\(id)",
                          body: ["name": name, "bio": bio, "specializations": specializations],
                          as: BoolAck.self)
    }

    func uploadMasterPhoto(id: Int, jpeg: Data) async throws -> MasterPhotoAck {
        try await upload("api/seller/masters/\(id)/photo",
                         field: "photo", filename: "photo.jpg", mime: "image/jpeg",
                         fileData: jpeg, as: MasterPhotoAck.self)
    }

    func deleteMaster(id: Int) async throws {
        _ = try await delete("api/seller/masters/\(id)", as: BoolAck.self)
    }

    func services() async throws -> [ServiceItem] {
        try await get("api/seller/services", as: [ServiceItem].self)
    }

    /// categoryId: 0 — «без категории». Именно 0, а не nil: сервер трогает
    /// категорию только если ключ ПРИШЁЛ (иначе старая сборка приложения
    /// выбрасывала бы услугу из категории при каждом сохранении), а nil из тела
    /// запроса может выпасть — и «Без категории» стало бы невыбираемым.
    func createService(name: String, description: String?, durationMin: Int, bufferMin: Int,
                       price: Decimal, masterId: Int?, categoryId: Int = 0, sortOrder: Int = 0) async throws -> IdAck {
        // П-27.14: ключ повтора — повторное «Создать» после обрыва без дубля услуги.
        try await postKeyed("api/seller/services", body: [
            "name": name, "description": description,
            "duration_min": durationMin, "buffer_min": bufferMin,
            "price": "\(price)", "master_id": masterId,
            "category_id": categoryId, "sort_order": sortOrder,
        ], as: IdAck.self)
    }

    func updateService(id: Int, name: String, description: String?, durationMin: Int, bufferMin: Int,
                       price: Decimal, masterId: Int?, isActive: Bool,
                       categoryId: Int = 0, sortOrder: Int = 0) async throws {
        _ = try await put("api/seller/services/\(id)", body: [
            "name": name, "description": description,
            "duration_min": durationMin, "buffer_min": bufferMin,
            // «Не назначен» — явное значение: nil из тела выпадает, и сервер
            // оставлял прежнего мастера. П-20.1: снимает мастера `0` (так в
            // ответе сервера), а не null.
            "price": "\(price)", "master_id": masterId ?? 0, "is_active": isActive ? 1 : 0,
            "category_id": categoryId, "sort_order": sortOrder,
        ], as: BoolAck.self)
    }

    func deleteService(id: Int) async throws {
        _ = try await delete("api/seller/services/\(id)", as: BoolAck.self)
    }

    func slots(serviceId: Int, from: String, to: String) async throws -> [ServiceSlot] {
        try await get("api/seller/slots",
                      query: ["service_id": String(serviceId), "from": from, "to": to],
                      as: [ServiceSlot].self)
    }

    /// weekdays: 1=Пн … 7=Вс (как date('N') на сервере).
    func generateSlots(serviceId: Int, from: String, to: String,
                       timeFrom: String, timeTo: String, weekdays: [Int]) async throws -> CreatedAck {
        try await post("api/seller/slots/generate", body: [
            "service_id": serviceId, "from": from, "to": to,
            "time_from": timeFrom, "time_to": timeTo, "weekdays": weekdays,
        ], as: CreatedAck.self)
    }

    func setSlotAvailability(id: Int, available: Bool) async throws {
        _ = try await put("api/seller/slots/\(id)", body: ["is_available": available ? 1 : 0], as: BoolAck.self)
    }

    func deleteSlot(id: Int) async throws {
        _ = try await delete("api/seller/slots/\(id)", as: BoolAck.self)
    }

    func bookings(status: String?) async throws -> [Booking] {
        var q: [String: String] = [:]
        if let s = status, !s.isEmpty { q["status"] = s }
        return try await get("api/seller/bookings", query: q, as: [Booking].self)
    }

    /// status ∈ accepted | done | cancelled (сервер валидирует).
    /// orderId — какая именно бронь: в окне на несколько мест броней несколько.
    func setBookingStatus(slotId: Int, orderId: Int? = nil, status: String) async throws -> StatusAck {
        var body = ["status": status]
        if let orderId, orderId > 0 { body["order_id"] = String(orderId) }
        return try await post("api/seller/bookings/\(slotId)/status", body: body, as: StatusAck.self)
    }

    // ── Кошелёк (routes/seller_settings.php) ─────────────────────────────────
    func wallet() async throws -> WalletData {
        try await get("api/seller/wallet", as: WalletData.self)
    }

    /// method ∈ card_online | sbp | bank_transfer, минимум 100 ₽ (сервер проверяет).
    func walletTopup(amount: Decimal, method: String) async throws -> TopupResponse {
        try await post("api/seller/wallet/topup",
                       body: ["amount": "\(amount)", "method": method],
                       as: TopupResponse.self)
    }

    func cancelTopup(id: Int) async throws {
        _ = try await post("api/seller/wallet/topup/\(id)/cancel", body: [:], as: BoolAck.self)
    }

    /// Статус пополнения. Опрашивается после возврата со страницы оплаты ЮKassa:
    /// уведомление от провайдера может прийти на секунду позже, и без опроса
    /// человек увидел бы старый баланс и решил, что деньги пропали.
    func walletTopupStatus(id: Int) async throws -> TopupStatusResponse {
        try await get("api/seller/wallet/topup/\(id)", as: TopupStatusResponse.self)
    }

    // ── Возвраты (routes/seller.php) ─────────────────────────────────────────
    func returns(status: String?) async throws -> [ReturnSummary] {
        var q: [String: String] = [:]
        if let s = status, !s.isEmpty { q["status"] = s }
        return try await get("api/seller/returns", query: q, as: [ReturnSummary].self)
    }

    func returnDetail(id: Int) async throws -> ReturnDetail {
        try await get("api/seller/returns/\(id)", as: ReturnDetail.self)
    }

    /// refund_method ∈ bonus | manual; amount опционален (сервер ограничит суммой заявки).
    @discardableResult
    func approveReturn(id: Int, amount: Decimal?, method: String, note: String?) async throws -> ReturnApproveAck {
        var body: [String: Any?] = ["refund_method": method, "note": note]
        if let a = amount { body["amount"] = "\(a)" }
        return try await post("api/seller/returns/\(id)/approve", body: body, as: ReturnApproveAck.self)
    }

    /// «Деньги выплачены» — конечная точка возврата ДЕНЬГАМИ (refund_method=manual).
    /// Возврат бонусами сервер закрывает сам, для него ручка вернёт 422.
    func markReturnPaid(id: Int, note: String?) async throws {
        _ = try await post("api/seller/returns/\(id)/paid", body: ["note": note], as: BoolAck.self)
    }

    func rejectReturn(id: Int, reason: String) async throws {
        _ = try await post("api/seller/returns/\(id)/reject", body: ["reason": reason], as: BoolAck.self)
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ФАЗА 2 — отзывы, клиенты, акции, лояльность, сотрудники, аналитика,
    //  настройки магазина, экспорты. Роуты: seller_analytics.php,
    //  seller_promotions.php, seller_settings.php, seller_staff.php.
    //  Additive; деньги — Decimal (строки "0.00" толерантно через @LenientDecimal
    //  в моделях). Числа-строки не объявляем Int. Типы — из Models+Phase2.swift.
    // ═════════════════════════════════════════════════════════════════════════

    // ── Отзывы (routes/seller_analytics.php) ─────────────────────────────────
    func reviews(status: String?) async throws -> [SellerReview] {
        var q: [String: String] = [:]
        if let s = status, !s.isEmpty { q["status"] = s }
        return try await get("api/seller/reviews", query: q, as: [SellerReview].self)
    }

    func replyToReview(id: Int, text: String) async throws {
        _ = try await post("api/seller/reviews/\(id)/reply", body: ["text": text], as: Phase2BoolAck.self)
    }

    // ── Клиенты / RFM (routes/seller_analytics.php) ──────────────────────────
    func clients(search: String, segment: String?) async throws -> [ClientSummary] {
        var q: [String: String] = [:]
        if !search.isEmpty { q["search"] = search }
        if let seg = segment, !seg.isEmpty { q["segment"] = seg }
        return try await get("api/seller/clients", query: q, as: [ClientSummary].self)
    }

    func client(id: Int) async throws -> ClientDetail {
        try await get("api/seller/clients/\(id)", as: ClientDetail.self)
    }

    /// amount > 0 — начисление, < 0 — списание бонусов. Возвращает новый баланс.
    /// keys — ключи окна начисления (IdempotencyKeys.form()): повтор после обрыва
    /// уходит с тем же Idempotency-Key, и сервер не начисляет второй раз
    /// (seller_analytics.php, POST clients/{id}/bonus: apiIdemReplay/apiIdemClaim).
    /// detailed: отказ приходит APIDetailedError со статусом и кодом (текст тот же):
    /// 5xx с JSON-телом и idempotency_in_progress иначе становились APIError.server,
    /// а postKeyed на них ключ не забывает только в detailed-виде (status ≥ 500).
    /// Неизвестный исход экран распознаёт через API.keyedOutcomeUnknown.
    func grantClientBonus(id: Int, amount: Decimal, note: String?, keys: IdempotencyKeys) async throws -> BalanceAck {
        try await postKeyed("api/seller/clients/\(id)/bonus",
                            body: ["amount": "\(amount)", "note": note],
                            as: BalanceAck.self, detailed: true, keys: keys)
    }

    /// remove == true — убрать из чёрного списка; иначе добавить. Возвращает итоговый статус.
    func setClientBlacklist(id: Int, remove: Bool) async throws -> BlacklistAck {
        try await post("api/seller/clients/\(id)/blacklist",
                       body: ["remove": remove],
                       as: BlacklistAck.self)
    }

    func saveClientNote(id: Int, note: String) async throws {
        _ = try await put("api/seller/clients/\(id)/note", body: ["note": note], as: Phase2BoolAck.self)
    }

    // ── Акции (routes/seller_promotions.php) ─────────────────────────────────
    func promotions() async throws -> [Promotion] {
        try await get("api/seller/promotions", as: [Promotion].self)
    }

    func promotion(id: Int) async throws -> Promotion {
        try await get("api/seller/promotions/\(id)", as: Promotion.self)
    }

    func promotionsCatalog() async throws -> PromoCatalog {
        try await get("api/seller/promotions/catalog", as: PromoCatalog.self)
    }

    /// id == nil — создание (POST), иначе обновление (PUT). fields — уже готовый JSON-объект акции.
    func savePromotion(id: Int?, fields: [String: Any?]) async throws {
        if let id = id {
            _ = try await put("api/seller/promotions/\(id)", body: fields, as: Phase2BoolAck.self)
        } else {
            // П-27.14: ключ повтора — повторное «Создать» после обрыва без дубля акции.
            _ = try await postKeyed("api/seller/promotions", body: fields, as: IdAck.self)
        }
    }

    func togglePromotion(id: Int) async throws {
        _ = try await post("api/seller/promotions/\(id)/toggle", body: [:], as: ToggleActiveAck.self)
    }

    func archivePromotion(id: Int) async throws {
        _ = try await post("api/seller/promotions/\(id)/archive", body: [:], as: Phase2BoolAck.self)
    }

    func restorePromotion(id: Int) async throws {
        _ = try await post("api/seller/promotions/\(id)/restore", body: [:], as: Phase2BoolAck.self)
    }

    // ── Промокоды (routes/seller_settings.php: /api/seller/promos) ───────────
    func promoCodes() async throws -> [PromoCode] {
        try await get("api/seller/promos", as: [PromoCode].self)
    }

    /// type ∈ percent | fixed | free_delivery. expiresAt — уже отформатированная строка "yyyy-MM-dd HH:mm:ss" или nil.
    func createPromoCode(code: String, type: String, value: Decimal, minOrder: Decimal,
                         maxUses: Int?, expiresAt: String?) async throws -> IdAck {
        // П-27.14: ключ повтора — повторное «Создать» после обрыва без дубля промокода.
        try await postKeyed("api/seller/promos",
                            body: ["code": code, "type": type,
                                   "value": "\(value)", "min_order": "\(minOrder)",
                                   "max_uses": maxUses, "expires_at": expiresAt],
                            as: IdAck.self)
    }

    func deletePromoCode(id: Int) async throws {
        _ = try await delete("api/seller/promos/\(id)", as: Phase2BoolAck.self)
    }

    // ── Продвижение / boost (routes/seller_promotions.php) ───────────────────
    func boostInfo() async throws -> BoostInfo {
        try await get("api/seller/boost", as: BoostInfo.self)
    }

    /// productId == 0 (или nil) — буст магазина, иначе конкретного товара. days ∈ 1…30.
    /// keys — ключи экрана продвижения (IdempotencyKeys.form()): повтор после обрыва
    /// уходит с тем же Idempotency-Key, и сервер не списывает второй раз
    /// (seller_promotions.php, POST boost: apiIdemReplay/apiIdemClaim).
    /// detailed — как у grantClientBonus: 5xx в любом виде и «первый запрос ещё идёт»
    /// оставляют ключ, экран видит их через API.keyedOutcomeUnknown.
    func buyBoost(days: Int, productId: Int?, keys: IdempotencyKeys) async throws -> BoostAck {
        try await postKeyed("api/seller/boost",
                            body: ["days": days, "product_id": productId ?? 0],
                            as: BoostAck.self, detailed: true, keys: keys)
    }

    /// Исход POST с ключом повтора (postKeyed, detailed: true) неизвестен: обрыв,
    /// таймаут, 5xx (с JSON-телом или без) или idempotency_in_progress после
    /// встроенного повтора. Во всех этих случаях postKeyed ключ НЕ забыл — повтор
    /// тем же телом уйдёт с тем же ключом, и сервер второй раз не выполнит.
    /// Остальное (4xx с текстом, unknown_outcome, key_reused, кривой ответ) —
    /// ответ получен, ключ забыт.
    static func keyedOutcomeUnknown(_ error: Error) -> Bool {
        if let e = error as? APIDetailedError {
            return e.status >= 500 || e.code == "idempotency_in_progress"
        }
        if let e = error as? APIError {
            switch e {
            case .network, .timeout: return true
            case .http(let c): return c >= 500
            default: return false
            }
        }
        return false
    }

    // ── Программа лояльности (routes/seller_settings.php) ────────────────────
    func loyalty() async throws -> LoyaltyProgram {
        try await get("api/seller/loyalty", as: LoyaltyProgram.self)
    }

    func saveLoyalty(cashbackPercent: Decimal, minOrder: Decimal, expireDays: Int?, isActive: Bool) async throws {
        _ = try await post("api/seller/loyalty",
                           body: ["cashback_percent": "\(cashbackPercent)",
                                  "min_order_for_cashback": "\(minOrder)",
                                  // Пусто («бессрочно») — явный null: nil из тела выпадает,
                                  // и сервер оставлял прежний срок.
                                  "points_expire_days": expireDays.map { $0 as Any } ?? NSNull(),
                                  "is_active": isActive],
                           as: Phase2BoolAck.self)
    }

    // ── Сотрудники / роли / смены (routes/seller_staff.php) ──────────────────
    func staffPermissions() async throws -> StaffPermissionsInfo {
        try await get("api/seller/staff/permissions", as: StaffPermissionsInfo.self)
    }

    func staffRoles() async throws -> [StaffRole] {
        try await get("api/seller/staff/roles", as: [StaffRole].self)
    }

    /// preset — код системного пресета (или nil). permissions — карта прав (nil ⇒ из пресета).
    func createStaffRole(name: String, preset: String?, permissions: [String: Bool]?, color: String?) async throws -> IdAck {
        var body: [String: Any?] = ["name": name, "preset": preset, "color": color]
        if let p = permissions { body["permissions"] = p }
        return try await post("api/seller/staff/roles", body: body, as: IdAck.self)
    }

    /// Все поля опциональны — отправляются только заданные (nil игнорирует сервер).
    func updateStaffRole(id: Int, name: String?, color: String?, permissions: [String: Bool]?) async throws {
        var body: [String: Any?] = ["name": name, "color": color]
        if let p = permissions { body["permissions"] = p }
        _ = try await put("api/seller/staff/roles/\(id)", body: body, as: Phase2BoolAck.self)
    }

    func deleteStaffRole(id: Int) async throws {
        _ = try await delete("api/seller/staff/roles/\(id)", as: Phase2BoolAck.self)
    }

    func employees(status: String?) async throws -> [Employee] {
        var q: [String: String] = [:]
        if let s = status, !s.isEmpty { q["status"] = s }
        return try await get("api/seller/staff/employees", query: q, as: [Employee].self)
    }

    /// id == nil — создание (POST → {id}), иначе обновление (PUT). fields — готовый JSON-объект сотрудника.
    func saveEmployee(id: Int?, fields: [String: Any?]) async throws {
        if let id = id {
            _ = try await put("api/seller/staff/employees/\(id)", body: fields, as: Phase2BoolAck.self)
        } else {
            _ = try await post("api/seller/staff/employees", body: fields, as: IdAck.self)
        }
    }

    func deleteEmployee(id: Int) async throws {
        _ = try await delete("api/seller/staff/employees/\(id)", as: Phase2BoolAck.self)
    }

    func staffShifts() async throws -> [StaffShift] {
        try await get("api/seller/staff/shifts", as: [StaffShift].self)
    }

    /// employeeId — кто открывает (или nil), cashOpen — наличные на старте, note — комментарий.
    func openShift(employeeId: Int?, cashOpen: Decimal, note: String?) async throws -> IdAck {
        try await post("api/seller/staff/shifts/open",
                       body: ["employee_id": employeeId, "cash_open": "\(cashOpen)", "note": note],
                       as: IdAck.self)
    }

    /// cashCounted — пересчитанные наличные (nil ⇒ сервер не считает расхождение).
    func closeShift(id: Int, cashCounted: Decimal?) async throws -> ShiftCloseResult {
        var body: [String: Any?] = [:]
        if let c = cashCounted { body["cash_counted"] = "\(c)" }
        return try await post("api/seller/staff/shifts/\(id)/close", body: body, as: ShiftCloseResult.self)
    }

    // ── Аналитика / отчёты (routes/seller_analytics.php) ─────────────────────
    /// period ∈ 7days | 30days | quarter | year.
    func analytics(period: String) async throws -> AnalyticsData {
        try await get("api/seller/analytics", query: ["period": period], as: AnalyticsData.self)
    }

    func topProducts(period: String) async throws -> [TopProductRow] {
        try await get("api/seller/analytics/top-products", query: ["period": period], as: [TopProductRow].self)
    }

    func analyticsForecast() async throws -> [ForecastRow] {
        try await get("api/seller/analytics/forecast", as: [ForecastRow].self)
    }

    func reports(period: String) async throws -> ReportsData {
        try await get("api/seller/reports", query: ["period": period], as: ReportsData.self)
    }

    // ── Настройки магазина (routes/seller_settings.php) ──────────────────────
    /// fields — плоский JSON-объект основных полей (name/address/phone/…).
    /// П-27.6: fields["clear"] — список полей для очистки. Ответ нового сервера —
    /// {saved, cleared:[…]}: что реально очищено. nil — старый сервер (cleared не
    /// прислал), он пустые поля не очищает.
    @discardableResult
    func saveSettingsMain(fields: [String: Any?]) async throws -> [String]? {
        try await post("api/seller/settings/main", body: fields, as: SettingsMainAck.self).cleared
    }

    /// Загрузка логотипа (banner == false) или баннера (banner == true). JPEG-данные.
    func uploadShopImage(jpeg: Data, banner: Bool) async throws -> LogoUploadAck {
        try await upload("api/seller/settings/logo",
                         field: banner ? "banner" : "logo",
                         filename: banner ? "banner.jpg" : "logo.jpg",
                         mime: "image/jpeg", fileData: jpeg, as: LogoUploadAck.self)
    }

    func paymentMethods() async throws -> [PaymentMethodSetting] {
        try await get("api/seller/settings/payment", as: [PaymentMethodSetting].self)
    }

    /// methods — массив словарей {type, is_enabled, comment, available_for:[…]}.
    func savePaymentMethods(_ methods: [[String: Any]]) async throws {
        _ = try await post("api/seller/settings/payment", body: ["methods": methods], as: Phase2BoolAck.self)
    }

    func shopHours() async throws -> [ShopHour] {
        try await get("api/seller/settings/hours", as: [ShopHour].self)
    }

    /// hours — массив словарей {day_of_week, open_time, close_time, is_closed}.
    func saveShopHours(_ hours: [[String: Any]]) async throws {
        _ = try await post("api/seller/settings/hours", body: ["hours": hours], as: Phase2BoolAck.self)
    }

    /// hours — окно возвратов в часах (сервер ограничивает 1…72).
    func saveReturnWindow(hours: Int) async throws {
        _ = try await post("api/seller/settings/returns", body: ["return_window_hours": hours], as: Phase2BoolAck.self)
    }

    func saveNotificationSettings(telegramChatId: String, events: [String]) async throws {
        _ = try await post("api/seller/settings/notifications",
                           body: ["telegram_chat_id": telegramChatId, "events": events],
                           as: Phase2BoolAck.self)
    }

    // ── Экспорты (routes/seller_settings.php) — бинарь во временный файл ──────
    /// from/to — строки "YYYY-MM-DD". Возвращает URL скачанного XLSX.
    func exportOrdersXlsx(from: String, to: String) async throws -> URL {
        try await downloadFile("api/seller/orders/export-xlsx",
                               query: ["from": from, "to": to],
                               fallbackName: "orders.xlsx")
    }

    /// xlsx == true — XLSX-отчёт, иначе CSV. Возвращает URL скачанного файла.
    func exportWallet(xlsx: Bool) async throws -> URL {
        let path = xlsx ? "api/seller/wallet/export-xlsx" : "api/seller/wallet/export"
        return try await downloadFile(path, fallbackName: xlsx ? "wallet.xlsx" : "wallet.csv")
    }
}

