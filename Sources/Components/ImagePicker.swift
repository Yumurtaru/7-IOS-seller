import SwiftUI
import PhotosUI
import UIKit

/// Сжатие фото перед аплоадом: длинная сторона ≤ 1600 px, JPEG 0.8 —
/// разумный размер для reg.ru shared-хостинга и мобильной сети.
enum ImageCompressor {
    static func jpegForUpload(_ image: UIImage, maxSide: CGFloat = 1600, quality: CGFloat = 0.8) -> Data? {
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        // По умолчанию рендерер берёт масштаб экрана (@3x) — «1600» превращалось
        // в 4800 px и многомегабайтный JPEG. Нам нужны реальные пиксели.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        return resized.jpegData(compressionQuality: quality)
    }
}

/// Выбор фото из галереи (PhotosPicker недоступен для UIImage напрямую в iOS 16 без Transferable-обвязки).
struct PhotoLibraryPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    /// Фото выбрано, но не открылось (лежит в iCloud без сети, битый файл).
    /// Раньше лист закрывался и ничего не происходило — непонятно, почему фото нет.
    var onFail: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = 1
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoLibraryPicker
        init(_ parent: PhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            defer { parent.dismiss() }
            guard let provider = results.first?.itemProvider else { return }   // «Отмена»
            let fail = parent.onFail
            let failText = "Не удалось открыть фото. Если оно в iCloud — дождитесь загрузки на телефон и выберите снова."
            guard provider.canLoadObject(ofClass: UIImage.self) else { fail?(failText); return }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let image = object as? UIImage else {
                    DispatchQueue.main.async { fail?(failText) }
                    return
                }
                DispatchQueue.main.async { self?.parent.onPick(image) }
            }
        }
    }
}

/// Съёмка с камеры.
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // .camera на устройстве без камеры (или с камерой, запрещённой
        // «Экранным временем») — NSInvalidArgumentException и вылет.
        // В этом случае открываем галерею: фото всё равно можно добавить.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
