import Foundation
import UserNotifications

/// Notification Service Extension (Фаза 2.3 аудита): rich push с картинкой.
/// Сервер шлёт mutable-content=1 + fcm_options.image / data.image (core/Push.php).
/// Расширение скачивает картинку и прикладывает к уведомлению; при любой ошибке
/// уведомление показывается как обычно (текст) — деградация мягкая.
final class NotificationService: UNNotificationServiceExtension {

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    /// Обработчик системы можно вызвать РОВНО один раз: и загрузка картинки,
    /// и истечение времени расширения пытались вызвать его — второй вызов лишний.
    private var delivered = false
    private let lock = NSLock()

    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let first = !delivered
        delivered = true
        lock.unlock()
        if first { contentHandler?(content) }
    }

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttempt = (request.content.mutableCopy() as? UNMutableNotificationContent)
        guard let content = bestAttempt else { deliver(request.content); return }

        // Картинка: fcm_options.image кладётся FCM в userInfo["fcm_options"]["image"],
        // наш data['image'] — прямо в userInfo["image"].
        let urlString = (content.userInfo["image"] as? String)
            ?? ((content.userInfo["fcm_options"] as? [String: Any])?["image"] as? String)
        guard let s = urlString, let url = URL(string: s), s.hasPrefix("http") else {
            deliver(content); return
        }

        URLSession.shared.downloadTask(with: url) { [weak self] tmp, _, _ in
            defer { self?.deliver(content) }
            guard let tmp = tmp else { return }
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + ext)
            do {
                try FileManager.default.moveItem(at: tmp, to: dest)
                let att = try UNNotificationAttachment(identifier: "image", url: dest)
                content.attachments = [att]
            } catch { /* мягкая деградация — текстовое уведомление */ }
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        // Время вышло — показываем лучшее, что есть (текст без картинки).
        if let content = bestAttempt { deliver(content) }
    }
}
