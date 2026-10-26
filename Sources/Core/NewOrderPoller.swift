import Foundation
import Combine
import AudioToolbox
import UserNotifications
import UIKit

/// Поллинг новых заказов: GET /api/seller/orders/new-count каждые 30 с в foreground.
/// Рост счётчика → звуковой сигнал (как на кассе) + бейдж приложения.
/// Бейдж не сбрасывается сам — только когда новых заказов реально нет.
@MainActor
final class NewOrderPoller: ObservableObject {
    static let shared = NewOrderPoller()

    @Published private(set) var newCount = 0
    private var timer: Timer?
    private var lastAnnounced = 0
    /// Номер «эпохи»: ответ, пришедший после выхода или смены магазина, не применяем.
    private var epoch = 0
    /// Первый ответ после смены магазина — точка отсчёта, а не «рост» (без звонка).
    private var baselineNext = false
    /// Когда последний раз звенели (поллер или push «новый заказ»): один заказ —
    /// один звонок, даже если его заметили и push, и опрос счётчика.
    private var lastRingAt = Date.distantPast
    /// Сколько push «новый заказ» пришло на открытом приложении. Список заказов
    /// перечитывается по нему: число новых могло не измениться (прежний новый
    /// приняли на кассе/станции), и нового заказа в ленте не было.
    @Published private(set) var pushArrivals = 0
    /// Эпоха, для которой сейчас идёт запрос счётчика (nil — запроса нет).
    private var tickInFlightEpoch: Int?

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.start() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            // Запрос, оборванный уходом в фон, не должен глушить опрос при возврате.
            Task { @MainActor in self?.stop(); self?.tickInFlightEpoch = nil }
        }
    }

    func start() {
        // П-28.5: сервер может ставить бейдж (число новых заказов) в push для
        // ios_seller. При каждом возврате в приложение бейдж сверяется с живым
        // счётчиком (tick ниже). Не вошли (сессия истекла) — счётчика нет:
        // бейдж из push иначе висел бы на иконке, пока не войдут.
        guard Session.shared.isLoggedIn else { Self.setAppBadge(0); return }
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in await NewOrderPoller.shared.tick() }
        }
        // При запуске start() зовут почти разом didBecomeActive и MainTabView
        // (а при смене магазина — shopChanged и пересозданные вкладки): уходило
        // 2–3 одинаковых GET new-count. Запрос этой эпохи уже идёт — второй не шлём.
        if tickInFlightEpoch != epoch {
            tickInFlightEpoch = epoch   // сразу: второй start() может прийти до запуска Task
            Task { await tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() async {
        let my = epoch
        tickInFlightEpoch = my
        defer { if tickInFlightEpoch == my { tickInFlightEpoch = nil } }
        guard Session.shared.isLoggedIn else { return }
        // Сотрудник без права «Заказы»: счётчик закрыт (403) — раньше запрос
        // уходил каждые 30 с впустую, а бейдж иконки оставался от прежних прав.
        guard Session.shared.can("orders") else {
            newCount = 0; lastAnnounced = 0; Self.setAppBadge(0)
            return
        }
        guard let data = try? await API.shared.newOrdersCount() else { return }
        guard my == epoch, Session.shared.isLoggedIn else { return }
        let n = data.new ?? 0
        let grew = !baselineNext && n > lastAnnounced
        baselineNext = false
        newCount = n
        lastAnnounced = n
        Self.setAppBadge(n)
        if grew && PushManager.shared.isEnabled(.newOrder) {
            playNewOrderSound()
        }
    }

    /// Push «новый заказ» пришёл, когда приложение открыто. Раньше звонил только
    /// tick() и только при росте счётчика АКТИВНОГО магазина: заказ в другой
    /// точке владельца, или новый сразу после принятого на кассе (счётчик 1→0→1
    /// между опросами), приходил тихой плашкой. Push сам говорит, что заказ
    /// новый: сначала tick(); не прозвенел он — звоним сами, если заказ в другой
    /// точке или за последнюю минуту звонка не было (push сотрудникам идёт через
    /// очередь с опозданием до 60 с — поллер мог уже прозвенеть этот заказ).
    func announcePushedOrder(shopId: Int?) async {
        guard Session.shared.isLoggedIn else { return }
        pushArrivals += 1
        let before = lastRingAt
        await tick()
        guard lastRingAt == before, Session.shared.isLoggedIn else { return }   // tick уже прозвенел
        let otherShop = shopId != nil && shopId != Session.shared.activeShopId
        guard otherShop || Session.shared.can("orders") else { return }
        guard otherShop || Date().timeIntervalSince(lastRingAt) > 60 else { return }
        if PushManager.shared.isEnabled(.newOrder) { playNewOrderSound() }
    }

    /// Выход из аккаунта: таймер стоп, счётчик и бейдж иконки в ноль. Раньше
    /// бейдж с числом заказов прежнего магазина оставался после выхода.
    func resetAfterLogout() {
        epoch += 1
        stop()
        newCount = 0
        lastAnnounced = 0
        Self.setAppBadge(0)
    }

    /// Бейдж иконки. setBadgeCount есть только с iOS 17, а цель сборки — iOS 16:
    /// без проверки версии сборка не проходит; на iOS 16 — старым свойством.
    private static func setAppBadge(_ n: Int) {
        if #available(iOS 17.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(n) { _ in }
        } else {
            UIApplication.shared.applicationIconBadgeNumber = n
        }
    }

    /// Сообщить поллеру, что заказы просмотрены (после захода в список) — звук не повторяется,
    /// но бейдж остаётся, пока сервер отдаёт новые заказы.
    func acknowledge() { lastAnnounced = newCount }

    /// Смена магазина: счётчик прежнего не держим на вкладке, заказы нового не «звенят».
    func shopChanged() {
        epoch += 1; newCount = 0; lastAnnounced = 0; baselineNext = true
        Task { await tick() }
    }

    func playNewOrderSound() {
        lastRingAt = Date()
        AudioServicesPlaySystemSound(1007)   // системный «трезвон» + вибрация ниже
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}
