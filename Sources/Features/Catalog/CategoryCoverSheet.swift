import SwiftUI
import UIKit

// ============================================================================
//  Обложка категории: POST /api/seller/categories/{id}/image (файл в поле
//  «photo», ответ {image}) и DELETE …/image (routes/seller_products.php).
//  Метод загрузки в API был, а экрана для него не было — обложку ставили
//  только в веб-кабинете. Обложку видят клиенты в витрине категорий.
// ============================================================================

@MainActor
final class CategoryCoverModel: ObservableObject {
    let categoryId: Int
    @Published var image: String?
    @Published var busy = false
    @Published var error: String?
    /// Что-то поменяли — список категорий перечитает миниатюры.
    private(set) var changed = false

    init(categoryId: Int, image: String?) {
        self.categoryId = categoryId
        self.image = image
    }

    func upload(_ picked: UIImage) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        // Сжатие — не на главном потоке (большое фото с камеры подвешивало экран).
        guard let data = await Task.detached(operation: { ImageCompressor.jpegForUpload(picked) }).value else {
            error = "Не удалось подготовить фото к отправке — выберите другое или снимите заново"
            return
        }
        do {
            let ack = try await API.shared.uploadCategoryCover(id: categoryId, jpeg: data)
            if let path = ack.image, !path.isEmpty { image = path }
            changed = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove() async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await API.shared.deleteCategoryCover(id: categoryId)
            image = nil
            changed = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CategoryCoverSheet: View {
    let name: String
    /// Закрыли лист после изменений — перечитать список.
    let onChanged: () -> Void
    @StateObject private var model: CategoryCoverModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var confirmRemove = false

    init(category: ProductCategory, onChanged: @escaping () -> Void) {
        self.name = category.name ?? "Категория"
        self.onChanged = onChanged
        _model = StateObject(wrappedValue: CategoryCoverModel(categoryId: category.categoryId, image: category.image))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        ZStack {
                            RemoteImage(path: model.image, size: 180, cornerRadius: 16, placeholderIcon: "photo")
                            if model.busy { ProgressView().controlSize(.large) }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                } footer: {
                    Text(model.image == nil
                         ? "Обложки пока нет. Клиенты увидят её в списке категорий витрины."
                         : "Так категорию видят клиенты в витрине. Новое фото заменит текущее.")
                }
                .listRowBackground(Brand.card)

                Section {
                    Button { showCamera = true } label: { Label("Снять на камеру", systemImage: "camera") }
                        .disabled(model.busy)
                    Button { showLibrary = true } label: { Label("Выбрать из галереи", systemImage: "photo.on.rectangle") }
                        .disabled(model.busy)
                    if model.image != nil {
                        Button(role: .destructive) { confirmRemove = true } label: {
                            Label("Убрать обложку", systemImage: "trash")
                        }
                        .disabled(model.busy)
                    }
                } footer: {
                    if let err = model.error { Text(err).foregroundColor(Brand.red) }
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }.disabled(model.busy)
                }
            }
            .confirmationDialog("Убрать обложку категории?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Убрать", role: .destructive) { Task { await model.remove() } }
                Button("Отмена", role: .cancel) {}
            }
            .sheet(isPresented: $showLibrary) {
                PhotoLibraryPicker(onPick: { img in Task { await model.upload(img) } },
                                   onFail: { model.error = $0 })
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { img in Task { await model.upload(img) } }
                    .ignoresSafeArea()
            }
        }
        // Пока фото уходит на сервер — лист не смахивается.
        .interactiveDismissDisabled(model.busy)
        .onDisappear { if model.changed { onChanged() } }
    }
}
