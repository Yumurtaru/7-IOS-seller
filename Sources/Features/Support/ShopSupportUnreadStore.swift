import Foundation
import Combine
import UIKit

// ============================================================================
//  Бейдж «Техподдержка» (непрочитанные ответы поддержки площадки) для
//  пункта в «Ещё» и вкладки «Ещё». GET /api/seller/support/unread — не чаще
//  раза в 60 с: при запуске, смене организации, возврате в приложение и
//  открытии «Ещё». Фонового опроса нет.
//  Класс без @MainActor (как PushManager): его берут через
//  @ObservedObject … = .shared в свойствах экранов. Всё состояние меняется
//  только в методах @MainActor.
// ============================================================================

final class ShopSupportUnreadStore: ObservableObject {
    static let shared = ShopSupportUnreadStore()

    @Published private(set) var unread = 0

    /// Организация, к которой относится счётчик. Сменили — счётчик прежней не показываем.
    private var shopId: Int?
    /// Раньше этого момента повторно не спрашиваем.
    private var nextAllowed = Date.distantPast
    private var inFlight = false
    private var bag = Set<AnyCancellable>()
    private var activated = false

    private init() {}

    /// Подписки на смену организации и возврат в приложение — один раз.
    @MainActor
    private func activateIfNeeded() {
        guard !activated else { return }
        activated = true
        // Смена организации (и первый ответ bootstrap) — счётчик новой.
        Session.shared.$activeShopId
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Task { @MainActor in ShopSupportUnreadStore.shared.refreshIfStale() }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { _ in
                Task { @MainActor in ShopSupportUnreadStore.shared.refreshIfStale() }
            }
            .store(in: &bag)
    }

    /// Перечитать счётчик, если прошло больше минуты (или организация другая).
    @MainActor
    func refreshIfStale() {
        activateIfNeeded()
        let s = Session.shared
        guard s.isLoggedIn, let shop = s.activeShopId else {
            unread = 0
            return
        }
        if shop != shopId {
            shopId = shop
            unread = 0
            nextAllowed = .distantPast
        }
        guard !inFlight, Date() >= nextAllowed else { return }
        inFlight = true
        nextAllowed = Date().addingTimeInterval(60)
        Task { @MainActor in
            do {
                let r = try await API.shared.supportUnread()
                // Пока шёл запрос, сменили организацию или вышли — чужой счётчик не пишем.
                if Session.shared.isLoggedIn, Session.shared.activeShopId == shop, self.shopId == shop {
                    self.unread = max(0, r.unread)
                }
            } catch {
                // Ошибка (в т.ч. 403 у сотрудника, если сервер закроет раздел) —
                // не спрашиваем каждую минуту: следующая попытка через 5 минут.
                if self.shopId == shop { self.nextAllowed = Date().addingTimeInterval(300) }
            }
            self.inFlight = false
            // Пока шёл запрос, организацию сменили: запрос новой отбросило
            // «уже идёт», а ответ прежней не записан — спрашиваем за новую.
            if self.shopId != shop || Session.shared.activeShopId != shop { self.refreshIfStale() }
        }
    }

    /// Пришёл push «сообщение поддержки» при открытом приложении — счётчик
    /// перечитываем сразу, без минутной паузы.
    @MainActor
    func forceRefresh() {
        nextAllowed = .distantPast
        refreshIfStale()
    }

    /// Свежие данные из открытого чата (ответ /read или страницы сообщений).
    @MainActor
    func update(unread n: Int, shopId shop: Int?) {
        activateIfNeeded()
        guard let shop, shop == Session.shared.activeShopId else { return }
        shopId = shop
        unread = max(0, n)
        nextAllowed = Date().addingTimeInterval(60)
    }
}
