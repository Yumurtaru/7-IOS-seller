import SwiftUI
import UIKit

/// Системный share sheet (UIActivityViewController) — для XLSX/CSV-экспортов.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Окно «Поделиться» закрывается само (после «Скопировать», «Сохранить»,
        // «Отмена») мимо SwiftUI: флаг листа оставался поднятым, и повторное
        // нажатие (QR стола, экспорт) больше ничего не открывало. Сбрасываем его.
        let close = dismiss
        vc.completionWithItemsHandler = { type, completed, _, _ in
            // Отмена вложенного действия (вышли из «Почты») окно не закрывает —
            // тогда и лист не трогаем.
            guard completed || type == nil else { return }
            Task { @MainActor in close() }
        }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Обёртка URL для .sheet(item:) — файл, готовый к шарингу.
struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
