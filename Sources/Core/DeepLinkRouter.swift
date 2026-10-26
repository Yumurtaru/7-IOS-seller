import Foundation
import Combine

/// Маршрутизация тапа по push-уведомлению: data.type + data.order_id → экран.
@MainActor
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()

    /// Запрошенная вкладка: "dashboard" | "orders" | "products" | "bookings" | "wallet" | "more"
    @Published var requestedTab: String?
    /// Открыть деталь заказа (после переключения вкладки).
    @Published var openOrderId: Int?
    /// Открыть чат внутри детали заказа.
    @Published var openChatForOrderId: Int?
    /// Открыть деталь возврата.
    @Published var openReturnId: Int?
    /// Раздел «Ещё», открываемый из push: "security" (audit) | "reservations" (бронь стола)
    /// | "support" (сообщение поддержки площадки, support_message).
    @Published var openSection: String?
    /// А78 «Курьеры Yumurta»: push pool_call без заказа — id вызова для карточки
    /// в разделе (0 — расчёты с курьерами, event settlement). Забирает PoolView.
    @Published var openPoolCallId: Int?

    private init() {}

    /// Последний обработанный push и когда. На холодном старте один и тот же
    /// тап приходит дважды (launchOptions и didReceive): с shop_id это давало
    /// два переключения магазина и две перестройки вкладок поверх заказа.
    private var lastPushKey: String?
    private var lastPushAt = Date.distantPast

    /// Смена магазина или выход: id заказа прежнего магазина не должен открыться потом.
    func reset() {
        requestedTab = nil; openOrderId = nil; openChatForOrderId = nil; openReturnId = nil; openSection = nil
        openPoolCallId = nil
    }

    /// Push чужого аккаунта: сервер кладёт в data.user_id получателя (строкой).
    /// Токен мог остаться за прежним аккаунтом на этом телефоне (повтор из очереди,
    /// вход другого сотрудника) — его заказ и чат не показываем и не открываем.
    /// Нет user_id (старый сервер) или не знаем, кто вошёл, — как раньше.
    func isForeign(_ userInfo: [AnyHashable: Any]) -> Bool {
        let raw = userInfo["user_id"]
        let uid = (raw as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? raw as? Int
        guard let uid, uid > 0, Session.shared.isLoggedIn else { return false }
        guard let me = Session.shared.user?.id, me > 0 else { return false }
        return me != uid
    }

    /// Push ПОКУПАТЕЛЮ (паритет с Android Push.isBuyerPush). Сервер (Push::toUser)
    /// шлёт по всем токенам пользователя, и владелец, который сам заказывает с того
    /// же номера, получал здесь «Заказ готов», статус своего возврата, чат с
    /// заведением — а тап вёл в «Возвраты»/«Заказы» своего магазина («не найден»).
    /// Типы — по ответу сайта на П-21 (ОТВЕТЫ-САЙТА.md): у push продавцу с
    /// заказом/бронью/чатом есть shop_id, у покупательских — нет.
    nonisolated static func isBuyerPush(_ info: [AnyHashable: Any]) -> Bool {
        func str(_ key: String) -> String? {
            if let s = info[key] as? String {
                let t = s.trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : t
            }
            if let n = info[key] as? Int { return String(n) }
            return nil
        }
        let hasShop = str("shop_id") != nil
        switch str("type") ?? "" {
        case "order_status", "order_changed", "booking_reminder", "return", "support",
             "new_shop", "shop_reopened", "abandoned_cart", "bonus_expiring", "campaign":
            return true
        case "order_chat", "reservation":
            return !hasShop
        case "":
            // Без type: у продавца это kind=approval и screen=lodging_bookings — их не трогаем.
            guard str("kind") == nil else { return false }
            let screen = str("screen")
            if screen == "trips" || screen == "wallet" { return true }
            if str("ad_id") != nil || str("product_id") != nil { return true }
            return str("order_id") != nil && !hasShop && screen == nil
        default:
            return false
        }
    }

    /// Обработка userInfo push-уведомления (данные из Push::toUser/fcmV1).
    func handlePush(userInfo: [AnyHashable: Any]) {
        // Не вошли — переход не запоминаем: иначе после входа (в том числе
        // в другой аккаунт) открывался заказ из старого уведомления.
        guard Session.shared.isLoggedIn else { return }
        // Чужой push (прежний аккаунт) — просто открытое приложение, без перехода.
        if isForeign(userInfo) { return }
        // Push покупателю (тот же аккаунт заказывает как клиент) — просто открываем приложение.
        if Self.isBuyerPush(userInfo) { return }
        let type = userInfo["type"] as? String
        let orderId = (userInfo["order_id"] as? String).flatMap(Int.init)
            ?? userInfo["order_id"] as? Int
        let returnId = (userInfo["return_id"] as? String).flatMap(Int.init)
            ?? userInfo["return_id"] as? Int
        let shopId = (userInfo["shop_id"] as? String).flatMap(Int.init)
            ?? userInfo["shop_id"] as? Int

        // П-21.1: push без type — переход по ключу screen (бронь жилья).
        let screen = userInfo["screen"] as? String
        // А78: pool_call — вызов курьера Yumurta (call_id, event).
        let callId = (userInfo["call_id"] as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? userInfo["call_id"] as? Int

        // П-28.1/2: у push жилья и отзывов свой id (booking_id, review_id) — два
        // разных уведомления подряд не должны считаться одним повтором.
        let extraId = "\(userInfo["booking_id"] ?? "")|\(userInfo["review_id"] ?? "")|\(userInfo["call_id"] ?? "")|\(userInfo["event"] ?? "")"
        let key = "\(type ?? "")|\(screen ?? "")|\(orderId ?? 0)|\(returnId ?? 0)|\(shopId ?? 0)|\(extraId)"
        if key == lastPushKey, Date().timeIntervalSince(lastPushAt) < 5 { return }
        lastPushKey = key
        lastPushAt = Date()

        guard let sid = shopId else {
            route(type: type, orderId: orderId, returnId: returnId, screen: screen, callId: callId); return
        }
        // Push другого магазина (ответ на заявку №17): сначала переключаем
        // магазин — иначе заказ открывался в чужом и был «не найден».
        // На холодном старте ждём, пока bootstrap узнает активный магазин.
        Task { @MainActor in
            let s = Session.shared
            // До 20 с, а не 5: на медленной сети список магазинов приходил позже,
            // сверка пропускалась, и заказ открывался в чужом магазине («не найден»).
            // Ошибка загрузки (bootError) — ждать нечего, идём как раньше.
            var waited = 0
            while s.activeShopId == nil && s.isLoggedIn && s.bootError == nil && waited < 200 {
                try? await Task.sleep(nanoseconds: 100_000_000); waited += 1
            }
            // Вышли из аккаунта, пока ждали, — переход не оставляем следующему входу.
            guard s.isLoggedIn else { return }
            // Идёт переключение, начатое из меню, — ждём его конца: иначе второе
            // переключение отбрасывалось, и переход по push терялся.
            var waitedSwitch = 0
            while s.switching && waitedSwitch < 150 {
                try? await Task.sleep(nanoseconds: 100_000_000); waitedSwitch += 1
            }
            if let active = s.activeShopId, active != sid {
                // Магазина нет в списке этого аккаунта (доступ сняли, push от
                // прежнего входа) — заказ чужого магазина в текущем не открываем:
                // раньше экран показывал «не найден» или 403.
                // Магазин мог появиться уже после запуска (создали, дали доступ) —
                // один раз перечитываем список, прежде чем отказаться от перехода.
                if !s.shops.contains(where: { $0.shopId == sid }) { await s.refreshShops() }
                guard s.shops.contains(where: { $0.shopId == sid }) else { return }
                await s.switchShop(to: sid)
                guard s.activeShopId == sid else { return }   // не переключилось — ошибку покажет bootError
            }
            route(type: type, orderId: orderId, returnId: returnId, screen: screen, callId: callId)
        }
    }

    /// Сначала «полезная нагрузка», вкладка — последней: подписчики видят её целиком.
    /// Неизвестный type (и push без перехода: approval, пустой data) — просто
    /// открытое приложение.
    private func route(type: String?, orderId: Int?, returnId: Int?, screen: String? = nil, callId: Int? = nil) {
        switch type {
        // А58/П-21.1: «курьер не смог доставить» (order_returned), отмена заказа
        // и сбой передачи на кассу — тоже про конкретный заказ: открываем его.
        // Раньше такие push просто открывали приложение.
        case "new_order", "order_returned", "order_cancelled", "pos_failed", "pos_rejected":
            openOrderId = orderId
            requestedTab = "orders"
        case "order_chat":
            openChatForOrderId = orderId
            openOrderId = orderId
            requestedTab = "orders"
        case "new_return", "return":
            openReturnId = returnId
            requestedTab = "more"
        // Тревога безопасности и новая бронь стола раньше только открывали
        // приложение: ведём в «Ещё» → «Безопасность» / «Брони столов».
        case "audit":
            openSection = "security"
            requestedTab = "more"
        case "reservation":
            openSection = "reservations"
            requestedTab = "more"
        // А66: ответ поддержки площадки организации — «Ещё» → «Техподдержка».
        // Push другой организации сюда приходит уже после переключения (shop_id
        // выше). Прежний тип "support" (обращение покупателя) не трогаем.
        case "support_message":
            openSection = "support"
            requestedTab = "more"
        // П-28.1: push жилья продавцу (новая бронь, отмена) — вкладка «Брони»
        // (у жилья это вкладка заказов). Открыть конкретную бронь экран пока
        // не умеет — открываем список. Другой магазин уже переключён выше (shop_id).
        case "lodging_booking_new", "lodging_booking_cancelled":
            if Session.shared.shopType == "lodging" { requestedTab = "orders" }
        // Заявка на длительную аренду — «Ещё» → «Длительная аренда».
        case "lodging_long_request":
            if Session.shared.shopType == "lodging" {
                openSection = "lodging_long"
                requestedTab = "more"
            }
        // А78 «Курьеры Yumurta»: pool_call + event (accepted, arrived, released,
        // delivered, failed, expired, settlement). По заказу — карточка заказа
        // (там блок вызова); вызов без заказа — его карточка в разделе;
        // settlement (call_id 0) — «Расчёты» раздела.
        case "pool_call":
            if let o = orderId, o > 0 {
                openOrderId = o
                requestedTab = "orders"
            } else if Session.shared.can("orders") {
                openPoolCallId = max(0, callId ?? 0)
                openSection = "pool"
                requestedTab = "more"
            }
        // П-28.2: новый отзыв (одобрен модератором) — «Ещё» → «Отзывы».
        case "new_review":
            openSection = "reviews"
            requestedTab = "more"
        case nil:
            // П-21.1: screen "lodging_bookings" + booking_id — вкладка «Брони»
            // (у жилья это вкладка заказов). У другого типа организации такой
            // вкладки нет — тогда просто открываем приложение.
            if screen == "lodging_bookings" && Session.shared.shopType == "lodging" {
                requestedTab = "orders"
            }
        default:
            break
        }
    }

    /// Custom scheme: yumurta-business://orders/123, yumurta-business://returns/5
    func handle(url: URL) {
        guard Session.shared.isLoggedIn else { return }   // как и push: без входа не копим переход
        let parts = url.pathComponents.filter { $0 != "/" }
        let host = url.host ?? parts.first ?? ""
        let idPart = host == url.host ? parts.first : (parts.count > 1 ? parts[1] : nil)
        switch host {
        case "orders":
            requestedTab = "orders"
            openOrderId = idPart.flatMap(Int.init)
        case "returns":
            requestedTab = "more"
            openReturnId = idPart.flatMap(Int.init)
        case "wallet":
            requestedTab = "wallet"
        default:
            break
        }
    }
}
