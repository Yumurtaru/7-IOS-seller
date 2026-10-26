import UIKit
import UserNotifications

/// Push продавца идёт ПРЯМЫМ APNs — ровно так же, как в приложении покупателя.
///
/// Почему не Firebase. Раньше здесь был FCM, и приложение брало токен у Firebase.
/// Но Firebase стартовал только при наличии GoogleService-Info.plist, а этого файла
/// в проекте нет — он клался из переменной окружения Codemagic, которой не было.
/// Значит токен не появлялся никогда и на сервер не уходил ничего.
/// Вдобавок сервер (core/Push.php) для iOS шлёт напрямую в APNs и ждёт СЫРОЙ
/// device-токен, а не токен FCM — с токеном FCM доставка не сработала бы в любом случае.
///
/// Теперь: device-токен APNs → hex-строка → POST /api/v1/push/register,
/// platform = "ios_seller" (у приложения продавца свой apns-topic на сервере).
/// Ключ .p8 на сервере общий для всей команды разработчика — заводить ничего не нужно.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Кэш картинок (AsyncImage → общий URLCache, по умолчанию ~0,5 МБ / 10 МБ):
        // фото товаров качались заново при каждой прокрутке. API его не трогает.
        URLCache.shared = URLCache(memoryCapacity: 30 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024)

        // Разрешение спрашиваем ЗДЕСЬ и безусловно — как в приложении покупателя.
        // Раньше запрос висел в .task экрана и срабатывал только если пользователь
        // УЖЕ вошёл на момент запуска. При обычном сценарии «установил → открыл →
        // ввёл логин» условие не выполнялось никогда: окно iOS не показывалось, а
        // приложение не появлялось даже в «Настройки → Уведомления» — система
        // показывает там только те приложения, которые хоть раз спросили разрешение.
        requestPushAuth()

        // Холодный старт по тапу на уведомление: разбираем payload сразу.
        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task { @MainActor in DeepLinkRouter.shared.handlePush(userInfo: remote) }
        }
        return true
    }

    func requestPushAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                PushManager.shared.refreshAuthorizationStatus()
                guard granted else { return }
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Возврат в приложение: перечитываем разрешение (могли включить в «Настройках»).
    func applicationDidBecomeActive(_ application: UIApplication) {
        PushManager.shared.refreshAuthorizationStatus()
    }

    /// APNs-токен → hex-строка → на бэкенд.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.setDeviceToken(deviceToken.map { String(format: "%02x", $0) }.joined())
        Task { await PushManager.shared.registerIfPossible() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Раньше ошибка глушилась, и отказ Apple выдать токен выглядел снаружи
        // так же, как «уведомления просто не приходят». Теперь текст видно
        // в «Ещё → Уведомления»: без токена push невозможен в принципе.
        PushManager.shared.reportAPNsFailure(error)
    }

    /// Показ уведомления, когда приложение открыто: уважаем локальные тумблеры категорий,
    /// новый заказ дополнительно озвучиваем «кассовым» сигналом.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let info = notification.request.content.userInfo
        // А66: ответ поддержки площадки при открытом приложении — сразу
        // обновляем бейдж «Техподдержка», а открытый чат забирает новое.
        // Показ самого уведомления ниже — как раньше.
        if (info["type"] as? String) == "support_message" {
            Task { @MainActor in
                ShopSupportUnreadStore.shared.forceRefresh()
                ShopSupportViewModel.liveOnScreen?.pollNow()
            }
        }
        // А78 «Курьеры Yumurta»: открытые карточка заказа и вызова перечитываются
        // сразу (курьер принял, на месте, доставил…), не дожидаясь опроса.
        if (info["type"] as? String) == "pool_call" {
            var payload: [AnyHashable: Any] = [:]
            for k in ["call_id", "order_id", "event", "shop_id"] { if let v = info[k] { payload[k] = v } }
            Task { @MainActor in
                NotificationCenter.default.post(name: .poolCallPush, object: nil, userInfo: payload)
            }
        }
        let category = PushManager.shared.category(forType: info["type"] as? String)
        guard PushManager.shared.isEnabled(category) else { completionHandler([]); return }
        // Паритет с Android: push покупателю (владелец заказывает с того же номера) —
        // не наш, он есть в приложении покупателя; здесь он звенел плашкой поверх работы.
        guard !DeepLinkRouter.isBuyerPush(info) else { completionHandler([]); return }
        Task { @MainActor in
            // Push адресован другому пользователю (data.user_id, токен остался
            // от прежнего аккаунта на этом телефоне) — не показываем его плашку.
            if DeepLinkRouter.shared.isForeign(info) { completionHandler([]); return }
            if category == .newOrder {
                // Новый заказ звенит поллер (свой «кассовый» сигнал) — звук
                // из push повторял бы его. Звонок теперь по самому push, а не
                // только по росту счётчика активного магазина (см. announcePushedOrder).
                completionHandler([.banner, .list])
                let rawShop = info["shop_id"]
                let shopId = (rawShop as? String).flatMap { Int($0) } ?? rawShop as? Int
                await NewOrderPoller.shared.announcePushedOrder(shopId: shopId)
                return
            }
            completionHandler([.banner, .sound, .badge])
        }
    }

    /// Тап по уведомлению → deep link на экран.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in DeepLinkRouter.shared.handlePush(userInfo: info) }
        completionHandler()
    }

    /// Тихий/фоновый data-push — подтверждаем и обновляем счётчик заказов.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            await NewOrderPoller.shared.tick()
            completionHandler(.newData)
        }
    }
}
