import Foundation
import Combine
import UIKit
import UserNotifications

/// Регистрация APNs-токена на бэкенде и настройки категорий уведомлений.
/// Сервер: POST /api/v1/push/register → Push::registerToken(user_id, token, 'ios_seller').
/// Платформа именно 'ios_seller': ключ .p8 на сервере общий для всей команды, а
/// apns-topic обязан совпадать с bundle id приложения (ru.marketplace.business).
/// Типы data.type, которые реально шлёт сервер продавцу:
///   new_order (Notify::sellerNewOrder), order_chat (сообщение клиента), campaign, support.
final class PushManager: ObservableObject {
    static let shared = PushManager()

    /// Сырой device-токен APNs в hex (64 символа), его ждёт core/Push.php::apns.
    @Published private(set) var deviceToken: String?

    /// Текст ошибки, из-за которой push не работает. Раньше все три возможные
    /// причины (Apple не выдал токен, сервер не принял токен, отправка не дошла)
    /// молча проглатывались, и снаружи это выглядело одинаково — «не приходит».
    @Published private(set) var lastError: String?

    /// Токен принят сервером (POST /api/v1/push/register вернул success).
    @Published private(set) var serverRegistered = false

    func setDeviceToken(_ token: String) {
        // Колбэк APNs приходит на главном потоке — ставим токен сразу. Раньше
        // через async: следующий за ним registerIfPossible() успевал прочитать
        // nil и не отправлял новый токен (после переустановки — push не шли).
        if Thread.isMainThread {
            deviceToken = token
            lastError = nil
        } else {
            DispatchQueue.main.async {
                self.deviceToken = token
                self.lastError = nil
            }
        }
    }

    /// Apple отказалась выдать токен. Самая частая причина — у идентификатора
    /// приложения не включена возможность Push Notifications либо профиль
    /// подписи выпущен до её включения; тогда в тексте будет aps-environment.
    func reportAPNsFailure(_ error: Error) {
        let text = error.localizedDescription
        DispatchQueue.main.async {
            self.deviceToken = nil
            self.serverRegistered = false
            self.lastError = text.contains("aps-environment")
                ? "Apple не выдала токен: у приложения нет права на push. Включите Push Notifications у идентификатора ru.marketplace.business и перевыпустите профиль App Store."
                : "Apple не выдала токен: " + text
        }
    }

    /// Разрешение на уведомления на уровне iOS. Пока оно .notDetermined,
    /// приложения нет в «Настройки → Уведомления» — система показывает там
    /// только те приложения, которые хотя бы раз запросили разрешение.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    /// Локальные тумблеры категорий (фильтрация показа в foreground).
    enum Category: String, CaseIterable {
        case newOrder = "new_order"
        case chat = "order_chat"
        case other = "other"

        var title: String {
            switch self {
            case .newOrder: return "Новые заказы и записи"
            case .chat: return "Сообщения в чате"
            case .other: return "Прочие уведомления"
            }
        }
    }

    func isEnabled(_ c: Category) -> Bool {
        UserDefaults.standard.object(forKey: "push_" + c.rawValue) as? Bool ?? true
    }

    func setEnabled(_ c: Category, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: "push_" + c.rawValue)
    }

    func category(forType type: String?) -> Category {
        switch type {
        case "new_order": return .newOrder
        case "order_chat": return .chat
        default: return .other
        }
    }

    /// Разрешены ли уведомления системой прямо сейчас.
    var isSystemAllowed: Bool {
        authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral
    }

    /// Спросить разрешение. Окно iOS показывает ОДИН раз за установку:
    /// если пользователь уже ответил, вызов просто ничего не показывает.
    func requestAuthorization() {
        (UIApplication.shared.delegate as? AppDelegate)?.requestPushAuth()
    }

    /// Перечитать реальный статус у системы (после возврата из «Настроек»).
    func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                self.authorizationStatus = status
                // Разрешение есть, а токена нет — просим APNs выдать его заново.
                if self.isSystemAllowed && self.deviceToken == nil {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    /// Открыть страницу приложения в «Настройках» iPhone — единственный путь,
    /// если разрешение однажды отклонили: повторно окно система не покажет.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Отправить токен на бэкенд (только если вошли и токен получен).
    func registerIfPossible() async {
        guard Keychain.get(.accessToken) != nil, let token = deviceToken else { return }
        // А105: сведения об установке; новый id установки — только когда данные телефона
        // открыты (до первой разблокировки файл id не прочитать — InstallInfo.deviceId).
        let canCreate = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        let install = InstallInfo.pushFields(canCreate: canCreate)
        do {
            try await API.shared.registerPushToken(token, install: install)
            await MainActor.run { self.serverRegistered = true; self.lastError = nil }
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await MainActor.run {
                self.serverRegistered = false
                self.lastError = "Сервер не принял токен: " + text
            }
        }
    }

    /// Живая проверка всей цепочки: сервер сам отправляет уведомление на все
    /// токены этого пользователя и возвращает ответ Apple по каждому.
    func runSelfTest() async -> String {
        guard Keychain.get(.accessToken) != nil else { return "Сначала войдите в аккаунт." }
        await registerIfPossible()
        do {
            let d = try await API.shared.sendPushTest()
            var lines: [String] = []
            lines.append(d.apnsConfigured ? "APNs на сервере: настроен"
                                          : "APNs на сервере: НЕ настроен (нет ключа .p8, Key ID или Team ID)")
            lines.append("Топик продавца: " + d.topicSeller)
            if d.tokens.isEmpty {
                lines.append("Токенов в базе: НЕТ — сервер не получил токен этого устройства.")
            } else {
                lines.append("Токены в базе:")
                for t in d.tokens {
                    lines.append(" • " + t.platform + (t.active ? "" : " (отключён)") + " — " + t.token)
                }
            }
            lines.append("Отправлено: \(d.sent)")
            for r in d.report {
                lines.append((r.ok ? "✓ " : "✗ ") + r.platform + " — " + r.detail)
            }
            return lines.joined(separator: "\n")
        } catch {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return "Проверка не выполнена.\n" + text
        }
    }
}
