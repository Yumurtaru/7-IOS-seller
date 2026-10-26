import SwiftUI
import SafariServices

/// Встроенный браузер для платёжных страниц (пополнение кошелька card_online/sbp):
/// страница открывается внутри приложения, по закрытию — обновляем баланс.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let cfg = SFSafariViewController.Configuration()
        cfg.entersReaderIfAvailable = false
        let vc = SFSafariViewController(url: url, configuration: cfg)
        vc.preferredControlTintColor = UIColor(Brand.accent)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// «Готово» в Safari закрывает лист мимо SwiftUI: элемент листа оставался
    /// заданным, onDismiss (обновление баланса) не срабатывал, а повторное
    /// открытие страницы не работало. Сообщаем SwiftUI о закрытии сами.
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let parent: SafariView
        init(_ parent: SafariView) { self.parent = parent }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            let close = parent.dismiss
            Task { @MainActor in close() }
        }
    }
}

/// Обёртка для .sheet(item:) — URL не Identifiable.
struct PayLink: Identifiable {
    let id = UUID()
    let url: URL
}
