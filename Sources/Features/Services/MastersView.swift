import SwiftUI
import UIKit

// ============================================================================
//  Мастера — GET/POST/PUT/DELETE /api/seller/masters + фото (multipart).
// ============================================================================

@MainActor
final class MastersViewModel: ObservableObject {
    @Published var items: [Master] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.masters()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// id сохранённого мастера; 0 — создан, но id неизвестен (фото не дослать);
    /// nil — не сохранён (текст в error).
    func save(id: Int?, name: String, bio: String?, specializations: [String]) async -> Int? {
        error = nil
        // Снимок до создания: по нему ищем нового мастера, если ответ не дошёл.
        let before = Set(items.map(\.masterId))
        let listKnown = state == .loaded
        do {
            if let id = id {
                try await API.shared.updateMaster(id: id, name: name, bio: bio, specializations: specializations)
                await load()
                return id
            }
            let ack = try await API.shared.createMaster(name: name, bio: bio, specializations: specializations)
            await load()
            // П-24: id в ответе не гарантирован. Раньше без него лист молча
            // оставался открытым, и повторное «Сохранить» создавало дубль.
            return ack.id ?? freshMasterId(name: name, before: before, listKnown: listKnown) ?? 0
        } catch {
            let msg = error.localizedDescription
            // Обрыв, таймаут или непонятный ответ на создание: мастер мог уже
            // появиться. Перечитываем — нашёлся ровно один новый с этим именем,
            // значит создан, повторять не нужно (иначе — дубль в записи).
            if id == nil, listKnown, Self.maybeSaved(error) {
                await load()
                if let fresh = freshMasterId(name: name, before: before, listKnown: listKnown) { return fresh }
            }
            self.error = msg
            return nil
        }
    }

    private func freshMasterId(name: String, before: Set<Int>, listKnown: Bool) -> Int? {
        guard listKnown else { return nil }
        let wanted = name.trimmingCharacters(in: .whitespaces)
        let fresh = items.filter {
            !before.contains($0.masterId) && ($0.name ?? "").trimmingCharacters(in: .whitespaces) == wanted
        }
        return fresh.count == 1 ? fresh[0].masterId : nil
    }

    private static func maybeSaved(_ error: Error) -> Bool {
        guard let e = error as? APIError else { return false }
        switch e {
        case .network, .timeout, .decoding: return true
        default: return false
        }
    }

    func uploadPhoto(masterId: Int, image: UIImage) async {
        // Сжатие — не на главном потоке: иначе экран подвисал на полсекунды.
        guard let data = await Task.detached(operation: { ImageCompressor.jpegForUpload(image, maxSide: 1200) }).value else {
            // Раньше — молча: лист закрывался, а фото у мастера так и не появлялось.
            error = "Мастер сохранён, но фото не удалось подготовить — выберите другой снимок"
            return
        }
        error = nil
        do {
            _ = try await API.shared.uploadMasterPhoto(id: masterId, jpeg: data)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Удаление мастера в пути: строка висит до ответа, второе «Удалить»
    /// получало 404 — ошибка «Не найдено» поверх удачного удаления.
    private var removingIds: Set<Int> = []

    func remove(_ master: Master) async {
        guard !removingIds.contains(master.masterId) else { return }
        removingIds.insert(master.masterId)
        defer { removingIds.remove(master.masterId) }
        error = nil
        do {
            try await API.shared.deleteMaster(id: master.masterId)
            items.removeAll { $0.masterId == master.masterId }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct MastersView: View {
    @StateObject private var vm = MastersViewModel()
    @State private var editTarget: Master?
    @State private var showCreate = false
    /// Паритет с Android: удаление мастера — с подтверждением.
    @State private var deleteTarget: Master?

    var body: some View {
        List {
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
            }
            ForEach(vm.items) { master in
                Button { editTarget = master } label: {
                    HStack(spacing: 12) {
                        RemoteImage(path: master.photoWebp, size: 52, cornerRadius: 26,
                                    placeholderIcon: "person.fill")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(master.name ?? "Мастер")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.text)
                            if !master.specializations.isEmpty {
                                Text(master.specializations.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundColor(Brand.muted)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if let rating = master.rating, rating > 0 {
                            // «4,8», а не «4.8»: без локали String(format:) ставил точку.
                            Label(String(format: "%.1f", locale: Locale(identifier: "ru_RU"),
                                         NSDecimalNumber(decimal: rating).doubleValue),
                                  systemImage: "star.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Brand.amber)
                        }
                    }
                }
                .listRowBackground(Brand.card)
                // Без полного свайпа: длинный жест удалял мастера без вопроса —
                // только нажатием кнопки.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = master
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Удалить мастера?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { master in
            Button("Удалить «\(master.name ?? "мастера")»", role: .destructive) {
                let m = master
                deleteTarget = nil
                Task { await vm.remove(m) }
            }
            Button("Отмена", role: .cancel) { deleteTarget = nil }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "person.2", emptyTitle: "Мастеров пока нет",
                   emptySubtitle: "Добавьте мастеров, чтобы привязывать их к услугам",
                   retry: { Task { await vm.load() } })
        .safeAreaInset(edge: .bottom) {
            Button { showCreate = true } label: {
                Label("Новый мастер", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .background(Brand.accent)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
        .sheet(item: $editTarget) { master in
            MasterEditSheet(vm: vm, master: master)
                .errorAlert($vm.error)
        }
        .sheet(isPresented: $showCreate) {
            MasterEditSheet(vm: vm, master: nil)
                .errorAlert($vm.error)
        }
        .task { await vm.load() }
    }
}

struct MasterEditSheet: View {
    @ObservedObject var vm: MastersViewModel
    let master: Master?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var bio = ""
    @State private var specs: [String] = []
    @State private var newSpec = ""
    @State private var isSaving = false
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var pendingPhoto: UIImage?
    /// Поля заполняем один раз: onAppear срабатывает снова после закрытия
    /// камеры, и правки имени и специализаций откатывались.
    @State private var didInit = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Мастер") {
                    TextField("Имя", text: $name)
                    TextField("О мастере", text: $bio, axis: .vertical).lineLimit(2...5)
                }
                Section("Специализации") {
                    // По порядку, а не по тексту: Android сохраняет «маникюр,
                    // маникюр» как есть — одинаковый id в списке формы путал
                    // строки и мог уронить её обновление при удалении.
                    ForEach(Array(specs.enumerated()), id: \.offset) { _, s in
                        HStack {
                            Text(s)
                            Spacer()
                            Button {
                                specs.removeAll { $0 == s }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(Brand.muted)
                            }
                        }
                    }
                    HStack {
                        TextField("Например: маникюр", text: $newSpec)
                        Button("Добавить") {
                            let v = newSpec.trimmingCharacters(in: .whitespaces)
                            guard !v.isEmpty, !specs.contains(v) else { return }
                            specs.append(v)
                            newSpec = ""
                        }
                        .disabled(newSpec.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Фото") {
                    HStack(spacing: 12) {
                        if let img = pendingPhoto {
                            Image(uiImage: img)
                                .resizable().scaledToFill()
                                .frame(width: 72, height: 72)
                                .clipShape(Circle())
                        } else {
                            RemoteImage(path: master?.photoWebp, size: 72, cornerRadius: 36,
                                        placeholderIcon: "person.fill")
                        }
                        Menu {
                            Button { showCamera = true } label: { Label("Камера", systemImage: "camera") }
                            Button { showLibrary = true } label: { Label("Галерея", systemImage: "photo.on.rectangle") }
                        } label: {
                            Text("Выбрать фото")
                        }
                    }
                }
                Section {
                    Button {
                        guard !isSaving else { return }
                        isSaving = true
                        Task { await save() }
                    } label: {
                        HStack { Spacer(); if isSaving { ProgressView() } else { Text("Сохранить").bold() }; Spacer() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(master == nil ? "Новый мастер" : "Мастер")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
            .sheet(isPresented: $showLibrary) {
                PhotoLibraryPicker { image in pendingPhoto = image }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in pendingPhoto = image }.ignoresSafeArea()
            }
            .onAppear {
                guard !didInit else { return }
                didInit = true
                if let m = master {
                    name = m.name ?? ""
                    bio = m.bio ?? ""
                    specs = m.specializations
                }
            }
        }
        // Смахивание листа вниз стирало имя, описание, специализации и
        // выбранное фото без вопроса. С правками закрыть — только кнопкой «Отмена».
        .interactiveDismissDisabled(isSaving || hasChanges)
    }

    /// Что-то изменено относительно открытого мастера (или нового).
    private var hasChanges: Bool {
        if pendingPhoto != nil { return true }
        let n0: String = master?.name ?? ""
        let b0: String = master?.bio ?? ""
        let s0: [String] = master?.specializations ?? []
        return name != n0 || bio != b0 || specs != s0
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        guard let id = await vm.save(id: master?.masterId,
                                     name: name.trimmingCharacters(in: .whitespaces),
                                     // Правка: пустую строку отправляем как есть — nil из тела
                                     // выпадает, и стёртое «О мастере» оставалось на сервере.
                                     bio: (bio.isEmpty && master == nil) ? nil : bio,
                                     specializations: specs) else { return }
        if let photo = pendingPhoto {
            if id > 0 {
                await vm.uploadPhoto(masterId: id, image: photo)
            } else {
                // Мастер создан, но сервер не вернул id — фото дослать некуда.
                vm.error = "Мастер создан, но фото не отправлено — откройте его и выберите фото ещё раз"
            }
        }
        dismiss()
    }
}
