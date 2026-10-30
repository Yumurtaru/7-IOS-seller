import Foundation

// ============================================================================
//  API+Seller3.swift — endpoints Фазы 3 (сверены с routes/*.php):
//  склад, поставщики и закупки, доставка (зоны/курьеры), безопасность,
//  тарифы, cafe-просмотр (столы/станции/тех-карты), KYC.
//  Конверт везде обычный {ok,data,error} — включая пути /api/v1/seller/*
//  (couriers, stations): те роуты тоже отвечают через Response::ok.
// ============================================================================

extension API {

    // ── Склад: настройки и склады (routes/seller_warehouse.php) ──────────────
    func warehouseSettings() async throws -> WarehouseSettingsData {
        try await get("api/seller/warehouse/settings", as: WarehouseSettingsData.self)
    }

    func saveWarehouseSettings(autoWriteoff: Bool) async throws {
        _ = try await put("api/seller/warehouse/settings",
                          body: ["auto_writeoff": autoWriteoff ? 1 : 0], as: BoolAck.self)
    }

    func warehouses() async throws -> [WarehouseInfo] {
        try await get("api/seller/warehouses", as: [WarehouseInfo].self)
    }

    /// То же, но отказ — с HTTP-статусом (APIDetailedError): 403 — у сотрудника только
    /// «Документы склада» без права «Склад» (окно документа пишет подсказку, а не ошибку).
    func warehousesDetailed() async throws -> [WarehouseInfo] {
        try await getDetailed("api/seller/warehouses", as: [WarehouseInfo].self)
    }

    func createWarehouse(name: String, address: String?, isDefault: Bool) async throws -> IdAck {
        try await post("api/seller/warehouses", body: [
            "name": name, "address": address, "is_default": isDefault ? 1 : 0,
        ], as: IdAck.self)
    }

    func deleteWarehouse(id: Int) async throws {
        _ = try await delete("api/seller/warehouses/\(id)", as: BoolAck.self)
    }

    // ── Остатки ──────────────────────────────────────────────────────────────
    /// warehouseId = nil/0 — глобальный остаток по всем складам.
    func stock(q: String?, low: Bool, warehouseId: Int?) async throws -> [StockItem] {
        var query: [String: String] = [:]
        if let q = q, !q.isEmpty { query["q"] = q }
        if low { query["low"] = "1" }
        if let w = warehouseId, w > 0 { query["warehouse_id"] = String(w) }
        return try await get("api/seller/stock", query: query, as: [StockItem].self)
    }

    /// warehouseId — склад документа: тогда stock_qty в ответе — остаток именно
    /// этого склада (нужно инвентаризации). nil — как раньше, общий остаток.
    func stockSearch(q: String, warehouseId: Int? = nil) async throws -> [StockSearchItem] {
        var query = ["q": q]
        if let w = warehouseId, w > 0 { query["warehouse_id"] = String(w) }
        return try await get("api/seller/stock/search", query: query, as: [StockSearchItem].self)
    }

    /// kind ∈ product | ingredient.
    func positionBatches(kind: String, id: Int) async throws -> [StockBatch] {
        try await get("api/seller/warehouse/position/\(kind)/\(id)/batches", as: [StockBatch].self)
    }

    func positionBalances(kind: String, id: Int) async throws -> [WarehouseBalance] {
        try await get("api/seller/warehouse/position/\(kind)/\(id)/balances", as: [WarehouseBalance].self)
    }

    // ── Отчёты склада ────────────────────────────────────────────────────────
    /// days 0–365 — окно «скоро истекает» (по умолчанию 14).
    func warehouseExpiry(days: Int) async throws -> ExpiryReport {
        try await get("api/seller/warehouse/expiry", query: ["days": String(days)], as: ExpiryReport.self)
    }

    /// А60/П-23.10: page/limit (1…2000) — постранично, has_more = есть следующая
    /// страница. Без них ответ прежний (урезанный список).
    func warehouseValuation(q: String?, page: Int? = nil, limit: Int? = nil) async throws -> ValuationReport {
        var query: [String: String] = [:]
        if let q = q, !q.isEmpty { query["q"] = q }
        if let p = page, p > 0 { query["page"] = String(p) }
        if let l = limit, l > 0 { query["limit"] = String(l) }
        return try await get("api/seller/warehouse/valuation", query: query, as: ValuationReport.self)
    }

    func warehouseAnalytics(days: Int) async throws -> WarehouseAnalytics {
        try await get("api/seller/warehouse/analytics", query: ["days": String(days)], as: WarehouseAnalytics.self)
    }

    func writeoffAnalytics(days: Int) async throws -> WriteoffAnalytics {
        try await get("api/seller/warehouse/writeoff-analytics", query: ["days": String(days)], as: WriteoffAnalytics.self)
    }

    /// lead 1–60 (дней до поставки), days 7–180 (окно спроса).
    func warehouseReorder(lead: Int, days: Int) async throws -> ReorderReport {
        try await get("api/seller/warehouse/reorder",
                      query: ["lead": String(lead), "days": String(days)], as: ReorderReport.self)
    }

    // ── Поставщики (routes/seller_warehouse.php) ─────────────────────────────
    func suppliers() async throws -> [Supplier] {
        try await get("api/seller/suppliers", as: [Supplier].self)
    }

    /// То же с HTTP-статусом отказа (APIDetailedError): 403 — нет права «Поставщики».
    func suppliersDetailed() async throws -> [Supplier] {
        try await getDetailed("api/seller/suppliers", as: [Supplier].self)
    }

    func supplier(id: Int) async throws -> SupplierDetail {
        try await get("api/seller/suppliers/\(id)", as: SupplierDetail.self)
    }

    /// Поля — как принимает POST/PUT: name (обязательно), phone, email, inn,
    /// address, comment (+ is_active только в PUT).
    func createSupplier(fields: [String: Any?]) async throws -> IdAck {
        // П-27.14: ключ повтора — повторное «Создать» после обрыва без дубля поставщика.
        try await postKeyed("api/seller/suppliers", body: fields, as: IdAck.self)
    }

    func updateSupplier(id: Int, fields: [String: Any?]) async throws {
        _ = try await put("api/seller/suppliers/\(id)", body: fields, as: BoolAck.self)
    }

    /// Мягкое удаление: сервер ставит is_active = 0.
    func deleteSupplier(id: Int) async throws {
        _ = try await delete("api/seller/suppliers/\(id)", as: BoolAck.self)
    }

    // ── Прайс-листы поставщиков (routes/seller_purchase.php) ─────────────────
    func supplierPrices(supplierId: Int) async throws -> [SupplierPrice] {
        try await get("api/seller/suppliers/\(supplierId)/prices", as: [SupplierPrice].self)
    }

    /// Upsert по (supplier, позиция): kind ∈ product|ingredient.
    func saveSupplierPrice(supplierId: Int, kind: String, positionId: Int,
                           price: Decimal, supplierSku: String?, packQty: Decimal?) async throws {
        var body: [String: Any?] = [
            "kind": kind, "position_id": positionId,
            "price": "\(price)", "supplier_sku": supplierSku,
        ]
        if let p = packQty { body["pack_qty"] = "\(p)" }
        _ = try await post("api/seller/suppliers/\(supplierId)/prices", body: body, as: BoolAck.self)
    }

    func deleteSupplierPrice(id: Int) async throws {
        _ = try await delete("api/seller/supplier-prices/\(id)", as: BoolAck.self)
    }

    // ── Закупки: заказы поставщику (routes/seller_purchase.php) ──────────────
    func purchaseOrders(status: String?, supplierId: Int?) async throws -> [PurchaseOrderSummary] {
        var q: [String: String] = [:]
        if let s = status, !s.isEmpty { q["status"] = s }
        if let sid = supplierId, sid > 0 { q["supplier_id"] = String(sid) }
        return try await get("api/seller/purchase-orders", query: q, as: [PurchaseOrderSummary].self)
    }

    func purchaseOrder(id: Int) async throws -> PurchaseOrderDetail {
        try await get("api/seller/purchase-orders/\(id)", as: PurchaseOrderDetail.self)
    }

    /// items: [{kind, id, name, unit, article, qty, price}] — как poSaveItems().
    func createPurchaseOrder(supplierId: Int?, warehouseId: Int?, comment: String?,
                             items: [[String: Any]]) async throws -> IdAck {
        // П-27.14: ключ повтора — повторное «Создать» после обрыва без дубля заказа поставщику.
        try await postKeyed("api/seller/purchase-orders", body: [
            "supplier_id": supplierId, "warehouse_id": warehouseId,
            "comment": comment, "items": items,
        ], as: IdAck.self)
    }

    /// Только черновик. Передавай ключи выборочно — сервер меняет лишь присланные.
    func updatePurchaseOrder(id: Int, fields: [String: Any?]) async throws {
        _ = try await put("api/seller/purchase-orders/\(id)", body: fields, as: BoolAck.self)
    }

    func sendPurchaseOrder(id: Int) async throws {
        _ = try await post("api/seller/purchase-orders/\(id)/send", body: [:], as: BoolAck.self)
    }

    func cancelPurchaseOrder(id: Int) async throws {
        _ = try await post("api/seller/purchase-orders/\(id)/cancel", body: [:], as: BoolAck.self)
    }

    /// Удалить можно только черновик (сервер проверяет).
    func deletePurchaseOrder(id: Int) async throws {
        _ = try await delete("api/seller/purchase-orders/\(id)", as: BoolAck.self)
    }

    /// Приёмка: body {warehouse_id?, items?: [{poi_id, qty, price?, expires_at?}]}.
    /// items = nil → принять всё оставшееся (qty_ordered − qty_received).
    /// Ответ: {income_document_id, fully_received} — приход проведён тем же движком.
    /// А60/П-23.11: postOnly — только провести черновик прихода уже принятого заказа.
    func receivePurchaseOrder(id: Int, warehouseId: Int?, items: [[String: Any]]?,
                              postOnly: Bool = false, keys: IdempotencyKeys? = nil) async throws -> ReceiveAck {
        var body: [String: Any?] = [:]
        if let w = warehouseId, w > 0 { body["warehouse_id"] = w }
        if let items = items { body["items"] = items }
        if postOnly { body["post_only"] = true }
        // Приёмка — с ключом повтора (сервер: purchase_orders.receive), как документы склада:
        // повтор «Принять» после обрыва получает прежний ответ, а не второй приход.
        if !postOnly {
            // detailed (А317): 422 qty_over_remaining приходит с poi_id и remaining —
            // экран показывает текст у этой строки. Текст ошибки — тот же.
            return try await postKeyed("api/seller/purchase-orders/\(id)/receive", body: body, as: ReceiveAck.self,
                                       detailed: true, keys: keys)
        }
        return try await post("api/seller/purchase-orders/\(id)/receive", body: body, as: ReceiveAck.self)
    }

    // ── Доставка: способы и зоны (routes/seller_settings.php) ────────────────
    func deliverySettings() async throws -> DeliverySettings {
        try await get("api/seller/settings/delivery", as: DeliverySettings.self)
    }

    /// methods: [{type, is_enabled, pickup_address, pickup_lat, pickup_lng,
    /// pickup_comment, dine_in_table_required}] — сервер обновляет присланные типы.
    func saveDeliveryMethods(_ methods: [[String: Any]]) async throws {
        _ = try await post("api/seller/settings/delivery", body: ["methods": methods], as: BoolAck.self)
    }

    /// Факт контракта: POST зоны берёт polygon (нет — []), PUT меняет только
    /// присланные ключи (dzZoneData(…, true)) — полигон при правке не шлём.
    func createZone(fields: [String: Any?]) async throws -> IdAck {
        try await post("api/seller/zones", body: fields, as: IdAck.self)
    }

    func updateZone(id: Int, fields: [String: Any?]) async throws {
        _ = try await put("api/seller/zones/\(id)", body: fields, as: BoolAck.self)
    }

    func deleteZone(id: Int) async throws {
        _ = try await delete("api/seller/zones/\(id)", as: BoolAck.self)
    }

    // ── Курьеры (routes/seller_couriers.php, конверт обычный) ────────────────
    func couriers() async throws -> [Courier] {
        try await get("api/v1/seller/couriers", as: [Courier].self)
    }

    /// Пароль обязателен для нового телефона (мин. 4 символа); permissions —
    /// из CourierPerms.all (сервер отсекает лишнее).
    func createCourier(name: String, phone: String, password: String,
                       permissions: [String]) async throws -> CourierCreateAck {
        try await post("api/v1/seller/couriers", body: [
            "name": name, "phone": phone, "password": password, "permissions": permissions,
        ], as: CourierCreateAck.self)
    }

    /// Возвращает true, если сервер НЕ сменил имя (name_skipped): курьер входит
    /// своим аккаунтом Yumurta, и имя меняет только он сам (seller_couriers.php).
    @discardableResult
    func updateCourier(id: Int, name: String?, password: String?, permissions: [String]?) async throws -> Bool {
        var body: [String: Any?] = [:]
        if let n = name, !n.isEmpty { body["name"] = n }
        if let p = password, !p.isEmpty { body["password"] = p }
        if let perms = permissions { body["permissions"] = perms }
        let ack = try await put("api/v1/seller/couriers/\(id)", body: body, as: CourierUpdateAck.self)
        return ack.nameSkipped == true
    }

    /// unblock = true снимает блокировку. Ответ: {status}.
    func setCourierBlocked(id: Int, unblock: Bool) async throws -> StatusAck {
        try await post("api/v1/seller/couriers/\(id)/block",
                       body: unblock ? ["unblock": 1] : [:], as: StatusAck.self)
    }

    func deleteCourier(id: Int) async throws {
        _ = try await delete("api/v1/seller/couriers/\(id)", as: BoolAck.self)
    }

    // ── Безопасность (routes/seller_security.php) ────────────────────────────
    /// days 1–180, action — код из labels (иначе все). Сервер отдаёт до 300 строк;
    /// beforeId (А320) — следующая страница: записи с id меньше этого.
    func securityFeed(days: Int, action: String?, beforeId: Int? = nil) async throws -> SecurityFeed {
        var q = ["days": String(days)]
        if let a = action, !a.isEmpty { q["action"] = a }
        if let b = beforeId, b > 0 { q["before_id"] = String(b) }
        return try await get("api/seller/security/feed", query: q, as: SecurityFeed.self)
    }

    func securityStats(days: Int) async throws -> SecurityStats {
        try await get("api/seller/security/stats", query: ["days": String(days)], as: SecurityStats.self)
    }

    func securityByCashier(days: Int) async throws -> CashierRiskReport {
        try await get("api/seller/security/by_cashier", query: ["days": String(days)], as: CashierRiskReport.self)
    }

    func securityAlerts() async throws -> SecurityAlerts {
        try await get("api/seller/security/alerts", as: SecurityAlerts.self)
    }

    // Методы тарифов (api/seller/plans) удалены из iOS-сборки: подписок
    // продавцов в приложении нет, покупать нечего. На сайте и в Android
    // endpoint остаётся без изменений.

    // ── Cafe-просмотр: столы, станции, тех-карты ─────────────────────────────
    func tables() async throws -> [RestaurantTable] {
        try await get("api/seller/tables", as: [RestaurantTable].self)
    }

    /// Только mode=restaurant (сервер отвечает 403 для остальных).
    func stations() async throws -> [StationAccount] {
        try await get("api/v1/seller/stations", as: [StationAccount].self)
    }

    func stationsHealth() async throws -> [StationHealth] {
        try await get("api/v1/seller/stations/health", as: [StationHealth].self)
    }

    /// type ∈ product | modifier.
    func techCard(type: String, entityId: Int) async throws -> TechCardResponse {
        try await get("api/seller/tech-cards/\(type)/\(entityId)", as: TechCardResponse.self)
    }

    func tcModifiers() async throws -> [TCModifier] {
        try await get("api/seller/tc-modifiers", as: [TCModifier].self)
    }

    // ── KYC (routes/seller_settings.php) ─────────────────────────────────────
    func kyc() async throws -> KycResponse {
        try await get("api/seller/kyc", as: KycResponse.self)
    }
}
