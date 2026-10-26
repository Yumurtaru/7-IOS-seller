import SwiftUI
import UIKit

// ============================================================================
//  Жильё → «Объекты»: номера, квартиры, дома.
// ----------------------------------------------------------------------------
//  Раньше весь раздел жилья жил только в веб-кабинете: владелец гостиницы
//  получал брони в «Заказы», но ни завести номер, ни поменять цену с телефона
//  не мог.
//
//  Публикация — по чек-листу сервера (Lodging::unitReadiness): без фотографий,
//  цены, времени заезда и правил проживания сервер объект не публикует
//  (требование правил предоставления гостиничных услуг), и экран показывает
//  ровно те же пункты, чтобы было понятно, чего не хватает.
// ============================================================================

@MainActor
final class LodgingUnitsViewModel: ObservableObject {
    @Published var items: [LodgingUnit] = []
    @Published var subtypes: [LodgingSubtype] = []
    @Published var amenities: [LodgingAmenityGroup] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    /// Сообщение сервера, которое не ошибка: например «объект снят с витрины,
    /// потому что по нему есть брони».
    @Published var info: String?
    /// Сколько фото сейчас загружается. Загрузка шла несколько секунд без
    /// единого признака — продавец выбирал снимок ещё раз, и у объекта
    /// появлялись дубли фотографий.
    @Published var uploadingPhotos = 0

    func load() async {
        if items.isEmpty { state = .loading }
        // Сообщения предыдущего действия не должны висеть над обновлённым
        // списком: иначе «объект снят с витрины» оставалось на экране, пока
        // продавец не тронет что-то ещё.
        error = nil
        info = nil
        do {
            let resp = try await API.shared.lodgingUnits()
            items = resp.items ?? []
            subtypes = resp.subtypes ?? []
            state = .loaded
            // Удобства нужны только форме: их ошибка не должна ломать экран.
            if amenities.isEmpty {
                amenities = (try? await API.shared.lodgingAmenities()) ?? []
            }
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Возвращает id сохранённого объекта (нужен, чтобы сразу дослать фото).
    /// keys — ключи повтора окна создания (живут, пока окно открыто).
    func save(id: Int?, body: [String: Any?], keys: IdempotencyKeys? = nil) async -> Int? {
        error = nil
        do {
            if let id = id {
                try await API.shared.updateLodgingUnit(id: id, body: body)
                await load()
                return id
            }
            let ack = try await API.shared.createLodgingUnit(body, keys: keys)
            await load()
            return ack.id
        } catch {
            // Сервер отвечает 422 и на «объект создан, но публиковать пока
            // нельзя»: текст с перечнем недостающего показываем как есть, а
            // список перезагружаем — объект уже сохранён.
            // Текст ставим ПОСЛЕ перезагрузки: load() начинает с error = nil, и
            // раньше ошибка стиралась — форма закрывалась как после успеха,
            // введённое пропадало, а 403/422/«нет сети» никто не видел.
            let msg = error.localizedDescription
            let before = Set(items.map(\.id))
            await load()
            self.error = msg
            // Создание: если объект всё же появился (422 «создан, но не
            // опубликован»), возвращаем его id — форма закроется, а повторное
            // «Сохранить» не создаст дубль.
            if id == nil {
                let fresh = items.filter { !before.contains($0.id) }
                if fresh.count == 1 { return fresh[0].id }
            }
            return nil
        }
    }

    /// Тумблер публикации шлёт ТОЛЬКО is_active: сервер трогает пришедшие ключи.
    func setActive(_ unit: LodgingUnit, _ active: Bool) async {
        _ = await save(id: unit.id, body: ["is_active": active ? 1 : 0])
    }

    /// Удаление объекта / фото уже в пути. Строка висит до ответа, её удаляли
    /// ещё раз — второй DELETE получал 404, и над удачным удалением
    /// всплывала ошибка «Не найдено». Повтор во время запроса пропускаем.
    private var removingUnitIds: Set<Int> = []
    private var deletingPhotoIds: Set<Int> = []

    func remove(_ unit: LodgingUnit) async {
        guard !removingUnitIds.contains(unit.id) else { return }
        removingUnitIds.insert(unit.id)
        defer { removingUnitIds.remove(unit.id) }
        error = nil
        info = nil
        do {
            // Объект с бронями сервер не удаляет, а снимает с публикации —
            // и говорит почему. Без этого текста продавец видел бы, что объект
            // после «Удалить» остался в списке, и решил бы, что не сработало.
            let ack = try await API.shared.deleteLodgingUnit(id: unit.id)
            await load()
            // Сообщение — ПОСЛЕ перечитывания: load() начинает с info = nil, и
            // «снят с витрины» стиралось, не успев появиться (объект оставался
            // в списке без объяснения, будто «Удалить» не сработало).
            if ack.deleted != true {
                info = ack.message ?? "По объекту есть брони: он снят с витрины, история сохранена"
            }
        } catch {
            // Объект уже удалили (сайт, другой телефон) или связь оборвалась
            // после удаления: перечитываем, иначе в списке висела строка, по
            // которой каждое действие давало ту же ошибку. Текст — после load().
            let msg = error.localizedDescription
            await load()
            self.error = msg
        }
    }

    func uploadPhoto(unitId: Int, image: UIImage) async {
        uploadingPhotos += 1
        defer { uploadingPhotos -= 1 }
        // Сжатие — не на главном потоке: иначе экран подвисал на полсекунды.
        guard let data = await Task.detached(operation: { ImageCompressor.jpegForUpload(image, maxSide: 1600) }).value else {
            // Раньше — молча: индикатор пропадал, фото не появлялось, и продавец
            // не понимал, что снимок не удалось подготовить.
            error = "Не удалось подготовить фото — выберите другой снимок"
            return
        }
        error = nil
        do {
            _ = try await API.shared.uploadLodgingPhoto(unitId: unitId, jpeg: data)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func setCover(unitId: Int, photoId: Int) async {
        error = nil
        do {
            try await API.shared.setLodgingCover(unitId: unitId, photoId: photoId)
            await load()
        } catch {
            // Фото могли удалить с сайта — перечитываем, чтобы лист показал
            // настоящие фотографии. Текст ошибки — после load().
            let msg = error.localizedDescription
            await load()
            self.error = msg
        }
    }

    func deletePhoto(id: Int) async {
        guard !deletingPhotoIds.contains(id) else { return }   // см. removingUnitIds
        deletingPhotoIds.insert(id)
        defer { deletingPhotoIds.remove(id) }
        error = nil
        do {
            try await API.shared.deleteLodgingPhoto(id: id)
            await load()
        } catch {
            // «Не найдено» — фото уже удалено: перечитываем, иначе оно висело в
            // листе, и каждое «Удалить» давало ту же ошибку.
            let msg = error.localizedDescription
            await load()
            self.error = msg
        }
    }
}

/// Все листы экрана — через ОДИН .sheet(item:), как в остальных разделах
/// приложения: несколько .sheet на одном view SwiftUI отрабатывает
/// непредсказуемо (открывается последний навешенный).
enum LodgingUnitsSheet: Identifiable {
    case edit(LodgingUnit?)
    case photos(Int)
    case readiness(LodgingUnit)

    var id: String {
        switch self {
        case .edit(let u):     return "edit-\(u?.id ?? 0)"
        case .photos(let id):  return "photos-\(id)"
        case .readiness(let u): return "ready-\(u.id)"
        }
    }
}

struct LodgingUnitsView: View {
    @StateObject private var vm = LodgingUnitsViewModel()
    @State private var sheet: LodgingUnitsSheet?
    /// Удаление необратимо (уходят фото, тарифы и календарь цен), а кнопка
    /// стоит рядом с «Изменить» — без подтверждения промах пальцем уносил объект.
    @State private var deleteTarget: LodgingUnit?

    var body: some View {
        NavigationStack {
            List {
                if let err = vm.error {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                }
                if let note = vm.info {
                    Section { Text(note).font(.footnote).foregroundColor(Brand.amber) }
                }
                ForEach(vm.items) { unit in
                    Section {
                        row(unit)
                        // Отдельными строками, а не в ряд: в List две ссылки в
                        // одной строке дают одну зону нажатия на всю строку.
                        NavigationLink {
                            LodgingCalendarView(unitId: unit.id, title: unit.unitTitle)
                        } label: {
                            Label("Календарь цен и доступности", systemImage: "calendar")
                        }
                        .font(.footnote)
                        .listRowBackground(Brand.card)
                        NavigationLink {
                            LodgingPlansView(unitId: unit.id)
                        } label: {
                            HStack {
                                Label("Тарифы", systemImage: "tag")
                                Spacer()
                                if (unit.ratePlansCount ?? 0) > 0 {
                                    Text("\(unit.ratePlansCount ?? 0)").foregroundColor(Brand.muted)
                                }
                            }
                        }
                        .font(.footnote)
                        .listRowBackground(Brand.card)
                        HStack(spacing: 18) {
                            // Лист показывает vm.error: ошибка прошлого действия со
                            // списка (удаление, тумблер) выглядела в нём отказом
                            // сохранения или загрузки фото, которых ещё не было.
                            Button { vm.error = nil; sheet = .photos(unit.id) } label: { Label("Фото", systemImage: "photo") }
                            Button { vm.error = nil; sheet = .edit(unit) } label: { Label("Изменить", systemImage: "pencil") }
                            Button(role: .destructive) { deleteTarget = unit } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                        // Три кнопки в одной строке List без стиля срабатывают ВСЕ
                        // от одного касания: «Фото» открывало ещё и правку и
                        // вопрос «Удалить объект?». Borderless — каждая сама по себе.
                        .buttonStyle(.borderless)
                        .font(.footnote)
                        .listRowBackground(Brand.card)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "bed.double", emptyTitle: "Объектов пока нет",
                       emptySubtitle: "Добавьте номер, квартиру или дом — и он появится на витрине после публикации",
                       retry: { Task { await vm.load() } })
            .navigationTitle("Объекты")
            .toolbar {
                ToolbarItem(placement: .principal) { ShopSwitcherMenu() }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { vm.error = nil; sheet = .edit(nil) } label: { Image(systemName: "plus") }
                }
            }
            .confirmationDialog(
                "Удалить объект?",
                isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { unit in
                Button("Удалить «\(unit.unitTitle)»", role: .destructive) {
                    let u = unit
                    deleteTarget = nil
                    Task { await vm.remove(u) }
                }
                Button("Отмена", role: .cancel) { deleteTarget = nil }
            } message: { unit in
                Text((unit.bookingsCount ?? 0) > 0
                     ? "По объекту есть брони, поэтому он будет снят с витрины, а история сохранится."
                     : "Вместе с объектом удалятся его фотографии, тарифы и календарь цен. Отменить это будет нельзя.")
            }
            .sheet(item: $sheet) { route in
                switch route {
                case .edit(let unit):      LodgingUnitEditSheet(vm: vm, unit: unit)
                case .photos(let unitId):  LodgingPhotosSheet(vm: vm, unitId: unitId)
                case .readiness(let unit): LodgingReadinessSheet(unit: unit)
                }
            }
            .task { await vm.load() }
        }
    }

    private func row(_ unit: LodgingUnit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RemoteImage(path: unit.cover, size: 56, cornerRadius: 10, placeholderIcon: "bed.double.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text(unit.unitTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.text)
                    Text([
                        unit.subtypeLabel,
                        "до \(unit.maxGuests ?? 1) гост.",
                        (unit.inventory ?? 1) > 1 ? "\(unit.inventory ?? 1) шт." : nil,
                    ].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                    Text(Self.priceLine(unit))
                        .font(.footnote)
                        .foregroundColor(Brand.text)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { (unit.isActive ?? 0) == 1 },
                    set: { v in Task { await vm.setActive(unit, v) } }
                ))
                .labelsHidden()
            }
            HStack(spacing: 6) {
                LodgingPill(text: (unit.isActive ?? 0) == 1 ? "На витрине" : "Не опубликован",
                           color: (unit.isActive ?? 0) == 1 ? Brand.green : Brand.muted)
                if unit.readiness?.ready == false {
                    Button {
                        sheet = .readiness(unit)
                    } label: {
                        LodgingPill(text: "Готово \(unit.readiness?.done ?? 0)/\(unit.readiness?.total ?? 0)",
                                   color: Brand.amber)
                    }
                    .buttonStyle(.plain)
                }
                if (unit.photosCount ?? 0) > 0 {
                    LodgingPill(text: "\(unit.photosCount ?? 0) фото", color: Brand.muted)
                }
                if (unit.ratePlansCount ?? 0) > 0 {
                    // «3 тариф.» → «3 тарифа».
                    LodgingPill(text: Self.plansText(unit.ratePlansCount ?? 0), color: Brand.muted)
                }
                if (unit.rentLong ?? 0) == 1 {
                    LodgingPill(text: "Долгая аренда", color: Brand.muted)
                }
            }
        }
        .listRowBackground(Brand.card)
    }

    /// Цена в строке объекта. У нового объекта цены ещё нет (в базе 0.00) —
    /// раньше стояло «0 ₽ за ночь», будто ночь бесплатная.
    private static func priceLine(_ unit: LodgingUnit) -> String {
        let daily = (unit.rentDaily ?? 1) == 1
        let price = daily ? unit.priceNight : unit.priceMonth
        guard let p = price, p > 0 else { return "Цена не указана" }
        return Money.rub(p) + (daily ? " за ночь" : " в месяц")
    }

    private static func plansText(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "\(n) тарифов" }
        if m10 == 1 { return "\(n) тариф" }
        if m10 >= 2 && m10 <= 4 { return "\(n) тарифа" }
        return "\(n) тарифов"
    }
}

/// Чек-лист публикации — ровно тот, что считает сервер.
private struct LodgingReadinessSheet: View {
    let unit: LodgingUnit
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(unit.readiness?.items ?? []) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: (item.ok ?? false) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor((item.ok ?? false) ? Brand.green : Brand.amber)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label ?? "").font(.subheadline).foregroundColor(Brand.text)
                                if (item.ok ?? false) == false, let hint = item.hint, !hint.isEmpty {
                                    Text(hint).font(.caption).foregroundColor(Brand.muted)
                                }
                            }
                        }
                        .listRowBackground(Brand.card)
                    }
                } footer: {
                    Text("Пока не выполнены все пункты, сервер не публикует объект: цену, время заезда и правила проживания требуют правила предоставления гостиничных услуг.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Готовность")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Закрыть") { dismiss() } } }
        }
    }
}

/// Фотографии объекта: первая — обложка, для публикации нужно минимум три.
private struct LodgingPhotosSheet: View {
    @ObservedObject var vm: LodgingUnitsViewModel
    let unitId: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showLibrary = false
    @State private var showCamera = false
    /// Файлы удаляются с диска безвозвратно, а кнопка стоит в плотном ряду.
    @State private var photoToDelete: LodgingPhoto?

    private var unit: LodgingUnit? { vm.items.first { $0.id == unitId } }

    var body: some View {
        NavigationStack {
            List {
                // Ошибка загрузки/удаления фото — здесь, а не под листом.
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red).listRowBackground(Brand.card)
                }
                Section {
                    if let photos = unit?.photos, !photos.isEmpty {
                        ForEach(photos) { ph in
                            HStack(spacing: 12) {
                                RemoteImage(path: ph.path, size: 64, cornerRadius: 8, placeholderIcon: "photo")
                                if ph.isCover == true {
                                    LodgingPill(text: "Обложка", color: Brand.green)
                                } else {
                                    Button("Сделать обложкой") {
                                        Task { await vm.setCover(unitId: unitId, photoId: ph.id) }
                                    }
                                    .font(.caption)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    photoToDelete = ph
                                } label: { Image(systemName: "trash") }
                            }
                            // Две кнопки в строке List без стиля срабатывают вместе:
                            // «Сделать обложкой» тут же спрашивало «Удалить фотографию?».
                            .buttonStyle(.borderless)
                            .listRowBackground(Brand.card)
                        }
                    } else {
                        Text("Пока ни одной фотографии").foregroundColor(Brand.muted).listRowBackground(Brand.card)
                    }
                } footer: {
                    Text("Обложку можно поменять кнопкой рядом с фотографией. Для публикации нужно минимум три: без фото жильё не бронируют.")
                }
                Section {
                    if vm.uploadingPhotos > 0 {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Загружаем фотографию…").font(.footnote).foregroundColor(Brand.muted)
                        }
                        .listRowBackground(Brand.card)
                    }
                    Button { showCamera = true } label: { Label("Снять на камеру", systemImage: "camera") }
                        .listRowBackground(Brand.card)
                        .disabled(vm.uploadingPhotos > 0)
                    Button { showLibrary = true } label: { Label("Выбрать из галереи", systemImage: "photo.on.rectangle") }
                        .listRowBackground(Brand.card)
                        .disabled(vm.uploadingPhotos > 0)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Фотографии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } } }
            .confirmationDialog(
                "Удалить фотографию?",
                isPresented: Binding(get: { photoToDelete != nil }, set: { if !$0 { photoToDelete = nil } }),
                titleVisibility: .visible,
                presenting: photoToDelete
            ) { photo in
                // presenting:, а не чтение @State внутри действия: биндинг
                // сбрасывается тем же сеттером, и id мог оказаться nil.
                Button("Удалить", role: .destructive) {
                    let id = photo.id
                    photoToDelete = nil
                    Task { await vm.deletePhoto(id: id) }
                }
                Button("Отмена", role: .cancel) { photoToDelete = nil }
            } message: { _ in
                Text("Файл удалится безвозвратно. Если фотографий станет меньше трёх, объект перестанет проходить чек-лист публикации.")
            }
            .sheet(isPresented: $showLibrary) {
                PhotoLibraryPicker { image in Task { await vm.uploadPhoto(unitId: unitId, image: image) } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in Task { await vm.uploadPhoto(unitId: unitId, image: image) } }
                    .ignoresSafeArea()
            }
        }
    }
}

/// Форма объекта. Отправляем только то, что есть в форме: сервер меняет
/// пришедшие ключи, и «не заполнено» не должно затирать настройки с сайта.
struct LodgingUnitEditSheet: View {
    @ObservedObject var vm: LodgingUnitsViewModel
    let unit: LodgingUnit?
    @Environment(\.dismiss) private var dismiss
    /// Ключ повтора создания — на это окно (закрыли — пропал).
    @State private var idem = IdempotencyKeys.form()

    @State private var title = ""
    @State private var descriptionText = ""
    @State private var subtype = "apartment"
    @State private var isRoom = false
    @State private var baseGuests = "2"
    @State private var maxGuests = "2"
    @State private var maxChildren = "0"
    @State private var roomsCount = "1"
    @State private var areaM2 = ""
    @State private var inventory = "1"
    @State private var rentDaily = true
    @State private var rentLong = false
    @State private var priceNight = ""
    @State private var priceWeekend = ""
    @State private var cleaningFee = ""
    @State private var deposit = ""
    @State private var extraGuest = ""
    @State private var minNights = "1"
    @State private var maxNights = "0"
    @State private var checkIn = LodgingFormat.timeDate("14:00", fallbackHour: 14)
    @State private var checkOut = LodgingFormat.timeDate("12:00", fallbackHour: 12)
    @State private var prepayPct = ""
    @State private var cancelFreeDays = "1"
    @State private var cancelPenalty = "first_night"
    @State private var instant = false
    @State private var pets = false
    @State private var smoking = false
    @State private var party = false
    @State private var kids = true
    @State private var rulesText = ""
    @State private var address = ""
    @State private var registryNo = ""
    @State private var registryUrl = ""
    @State private var priceMonth = ""
    @State private var minMonths = "1"
    @State private var depositMonth = ""
    @State private var utilitiesIncluded = false
    @State private var longNote = ""
    @State private var picked: Set<String> = []
    @State private var isSaving = false

    private var registryRequired: Bool {
        vm.subtypes.first { $0.key == subtype }?.registryRequired == true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Название", text: $title)
                    TextField("Описание", text: $descriptionText, axis: .vertical).lineLimit(2...6)
                    Picker("Тип жилья", selection: $subtype) {
                        ForEach(vm.subtypes) { st in Text(st.label ?? st.key).tag(st.key) }
                    }
                    Toggle("Это номер в объекте, а не жильё целиком", isOn: $isRoom)
                } header: {
                    Text("Объект")
                } footer: {
                    // Пороги чек-листа публикации — те же, что считает сервер.
                    Text("Для публикации: название от 3 символов, описание от 40, правила проживания от 20 и минимум 3 фотографии.")
                }
                Section("Вместимость") {
                    numRow("Гостей в цене", $baseGuests)
                    numRow("Максимум гостей", $maxGuests)
                    numRow("Детей", $maxChildren)
                    numRow("Комнат", $roomsCount)
                    numRow("Площадь, м²", $areaM2)
                    numRow("Таких номеров", $inventory)
                }
                Section("Как сдаётся") {
                    Toggle("Посуточно", isOn: $rentDaily)
                    Toggle("Длительная аренда", isOn: $rentLong)
                }
                if rentDaily {
                    // Денежные поля — под правом «Цены» (сервер отвечает 403 на
                    // любое из них), сроки — под обычным правом «Товары».
                    if Session.shared.can("products.price") {
                        Section {
                            numRow("За ночь, ₽", $priceNight, decimal: true)
                            numRow("Выходные, ₽", $priceWeekend, decimal: true)
                            numRow("Уборка, ₽", $cleaningFee, decimal: true)
                            numRow("Залог, ₽", $deposit, decimal: true)
                            numRow("Доп. гость, ₽", $extraGuest, decimal: true)
                        } header: {
                            Text("Цены за сутки")
                        } footer: {
                            Text("Пустое поле — это ноль: уборка, залог и доплата за гостя перестанут начисляться.")
                        }
                    }
                    Section("Сроки проживания") {
                        numRow("Минимум ночей", $minNights)
                        numRow("Максимум ночей (0 — без предела)", $maxNights)
                    }
                }
                if rentLong {
                    Section("Длительная аренда") {
                        if Session.shared.can("products.price") {
                            numRow("В месяц, ₽", $priceMonth, decimal: true)
                            numRow("Залог, ₽", $depositMonth, decimal: true)
                        }
                        numRow("Минимум месяцев", $minMonths)
                        Toggle("Коммунальные включены", isOn: $utilitiesIncluded)
                        TextField("Примечание для арендатора", text: $longNote, axis: .vertical).lineLimit(2...4)
                    }
                }
                Section("Заезд, выезд и отмена") {
                    // Колесо, а не текст: свободный ввод вида «9:00» сервер
                    // молча заменял на 14:00 (Lodging::time требует «ЧЧ:ММ»),
                    // и гость приезжал к одному времени, а в карточке стояло
                    // другое — расхождение находилось только по жалобе.
                    DatePicker("Заезд с", selection: $checkIn, displayedComponents: .hourAndMinute)
                    DatePicker("Выезд до", selection: $checkOut, displayedComponents: .hourAndMinute)
                    numRow("Предоплата, %", $prepayPct, decimal: true)
                    numRow("Отмена без штрафа, дней", $cancelFreeDays)
                    Picker("Удержание при поздней отмене", selection: $cancelPenalty) {
                        Text("Без удержания").tag("none")
                        Text("Первая ночь").tag("first_night")
                        Text("Полная стоимость").tag("full")
                    }
                    Toggle("Мгновенное бронирование", isOn: $instant)
                }
                Section("Правила") {
                    Toggle("С животными", isOn: $pets)
                    Toggle("Курение", isOn: $smoking)
                    Toggle("Вечеринки", isOn: $party)
                    Toggle("С детьми", isOn: $kids)
                    TextField("Правила проживания", text: $rulesText, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    TextField("Адрес", text: $address)
                    TextField("Номер в реестре", text: $registryNo)
                    TextField("Ссылка на запись в реестре", text: $registryUrl)
                } header: {
                    Text("Адрес и реестр")
                } footer: {
                    Text(registryRequired
                         ? "Для этого типа жилья номер в реестре средств размещения обязателен."
                         : "Для квартир, студий, домов и комнат номер в реестре не требуется.")
                }
                if !vm.amenities.isEmpty {
                    ForEach(vm.amenities) { group in
                        Section(group.group ?? "Удобства") {
                            ForEach(group.items ?? []) { a in
                                Button {
                                    if picked.contains(a.slug) { picked.remove(a.slug) } else { picked.insert(a.slug) }
                                } label: {
                                    HStack {
                                        Text(a.name ?? a.slug).foregroundColor(Brand.text)
                                        Spacer()
                                        if picked.contains(a.slug) {
                                            Image(systemName: "checkmark").foregroundColor(Brand.green)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Section {
                    // Ошибку показываем ЗДЕСЬ: баннер родительского экрана
                    // находится под листом, и отказ сервера («Недостаточно
                    // прав», «Не хватает: …») выглядел как сломанная кнопка.
                    if let err = vm.error {
                        Text(err).font(.footnote).foregroundColor(Brand.red)
                    }
                    Button {
                        Task { await save() }
                    } label: {
                        HStack { Spacer(); if isSaving { ProgressView() } else { Text("Сохранить").bold() }; Spacer() }
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).count < 3)
                } footer: {
                    // Название — в самом верху длинной формы: серая «Сохранить»
                    // внизу без объяснения выглядела сломанной.
                    if title.trimmingCharacters(in: .whitespaces).count < 3 {
                        Text("Укажите название объекта (от 3 символов) — в самом начале формы.")
                            .foregroundColor(Brand.amber)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(unit == nil ? "Новый объект" : "Объект")
            .navigationBarTitleDisplayMode(.inline)
            // Пока объект сохраняется — не закрываем (ключ повтора живёт с окном).
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() }.disabled(isSaving) } }
            .onAppear { fill() }
        }
        // Форма на 40 полей: смахивание вниз у верхнего края закрывало лист и
        // стирало всё введённое без вопроса. Закрыть — кнопкой «Отмена».
        .interactiveDismissDisabled(isSaving || !title.isEmpty)
    }

    @ViewBuilder
    private func numRow(_ label: String, _ value: Binding<String>, decimal: Bool = false) -> some View {
        HStack {
            Text(label).foregroundColor(Brand.text)
            Spacer()
            TextField("", text: value)
                .keyboardType(decimal ? .decimalPad : .numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 110)
        }
    }

    private func fill() {
        guard let u = unit else { return }
        title = u.title ?? ""
        descriptionText = u.description ?? ""
        subtype = u.subtype ?? "apartment"
        isRoom = u.kind == "room"
        baseGuests = String(u.baseGuests ?? 2)
        maxGuests = String(u.maxGuests ?? 2)
        maxChildren = String(u.maxChildren ?? 0)
        roomsCount = String(u.roomsCount ?? 1)
        areaM2 = u.areaM2.map(String.init) ?? ""
        inventory = String(u.inventory ?? 1)
        rentDaily = (u.rentDaily ?? 1) == 1
        rentLong = (u.rentLong ?? 0) == 1
        priceNight = decText(u.priceNight)
        priceWeekend = decText(u.priceWeekend)
        cleaningFee = decText(u.cleaningFee)
        deposit = decText(u.deposit)
        extraGuest = decText(u.extraGuestPrice)
        minNights = String(u.minNights ?? 1)
        maxNights = String(u.maxNights ?? 0)
        checkIn = LodgingFormat.timeDate(u.rules?.checkInFrom, fallbackHour: 14)
        checkOut = LodgingFormat.timeDate(u.rules?.checkOutUntil, fallbackHour: 12)
        prepayPct = (u.rules?.prepayPct ?? 0) == 0 ? "" : LodgingFormat.pct(u.rules?.prepayPct)
        cancelFreeDays = String(u.rules?.cancelFreeDays ?? 1)
        cancelPenalty = u.rules?.cancelPenalty ?? "first_night"
        instant = (u.instantBooking ?? 0) == 1
        pets = (u.rules?.petsAllowed ?? 0) == 1
        smoking = (u.rules?.smokingAllowed ?? 0) == 1
        party = (u.rules?.partyAllowed ?? 0) == 1
        kids = (u.rules?.kidsAllowed ?? 1) == 1
        rulesText = u.rules?.text ?? ""
        address = u.address ?? ""
        registryNo = u.registry?.no ?? ""
        registryUrl = u.registry?.url ?? ""
        priceMonth = decText(u.priceMonth)
        minMonths = String(u.minMonths ?? 1)
        depositMonth = decText(u.longTerm?.depositMonth)
        utilitiesIncluded = (u.longTerm?.utilitiesIncluded ?? 0) == 1
        longNote = u.longTerm?.note ?? ""
        picked = Set(u.amenities ?? [])
    }

    private func decText(_ v: Decimal?) -> String {
        guard let v = v, v != 0 else { return "" }
        return NSDecimalNumber(decimal: v).stringValue
    }

    private func num(_ s: String) -> Int? { Int(s.filter { !$0.isWhitespace }) }

    /// Паритет с Android: то же правило, что у сервера для registry_url
    /// (Lodging::unitFromInput): адрес без схемы дополняется https://, иначе
    /// принимается только http(s)-ссылка. Пусто — можно.
    private func registryUrlLooksValid(_ raw: String) -> Bool {
        let u = raw.trimmingCharacters(in: .whitespaces)
        if u.isEmpty { return true }
        let opts: String.CompareOptions = [.regularExpression, .caseInsensitive]
        var full = u
        let hasScheme = u.range(of: "^[a-z][a-z0-9+.-]*:", options: opts) != nil
        if !hasScheme && u.range(of: "^[a-z0-9.-]+\\.[a-z]{2,}(/|$)", options: opts) != nil {
            full = "https://" + u
        }
        return full.range(of: "^https?://\\S+$", options: opts) != nil
    }

    /// Деньги отправляем строкой — как и остальные экраны приложения.
    /// Строгим разбором, как на остальных экранах; nil — пусто. Раньше «1.500»
    /// уходило как есть (сервер читал 1,5 ₽), а «1500р» — текстом.
    private func money(_ s: String) -> String? {
        Money.strict(s.trimmingCharacters(in: .whitespaces)).map { "\($0)" }
    }

    @MainActor private func save() async {
        guard !isSaving else { return }   // двойной тап создавал два объекта
        for (raw, label) in [(priceNight, "За ночь"), (priceWeekend, "Выходные"), (cleaningFee, "Уборка"),
                             (deposit, "Залог"), (extraGuest, "Доп. гость"), (priceMonth, "В месяц"),
                             (depositMonth, "Залог (аренда)"), (prepayPct, "Предоплата")] {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && Money.strict(t) == nil { vm.error = "\(label) — число, например 1500 или 1500,50"; return }
        }
        // «45,5» в площади раньше давало 0 и стирало сохранённую площадь.
        for (raw, label) in [(baseGuests, "Гостей в цене"), (maxGuests, "Максимум гостей"), (maxChildren, "Детей"),
                             (roomsCount, "Комнат"), (areaM2, "Площадь"), (inventory, "Таких номеров"),
                             (minNights, "Минимум ночей"), (maxNights, "Максимум ночей"),
                             (cancelFreeDays, "Отмена без штрафа"), (minMonths, "Минимум месяцев")] {
            let t = raw.filter { !$0.isWhitespace }
            if !t.isEmpty && (Int(t) ?? -1) < 0 { vm.error = "\(label) — целое число"; return }
        }
        // Паритет с Android: вместимость, предоплата и ссылка на реестр — по правилам
        // сервера (Lodging::unitFromInput), который иначе молча правит значения:
        // поднимает гостей до 1 и максимум до «в цене», режет предоплату до 100 %,
        // стирает ссылку, не похожую на адрес сайта, — а форма показывала «сохранено».
        let bg = num(baseGuests)
        let mg = num(maxGuests)
        if let b = bg, b < 1 { vm.error = "Гостей в цене — не меньше 1"; return }
        if let m = mg, m < 1 { vm.error = "Максимум гостей — не меньше 1"; return }
        if let b = bg, let m = mg, m < b { vm.error = "Максимум гостей — не меньше, чем гостей в цене"; return }
        if let pp = Money.strict(prepayPct.trimmingCharacters(in: .whitespaces)), pp > 100 {
            vm.error = "Предоплата — от 0 до 100 %"; return
        }
        if !registryUrlLooksValid(registryUrl) {
            vm.error = "Ссылка на реестр — адрес сайта, например https://…"; return
        }
        isSaving = true
        defer { isSaving = false }
        var body: [String: Any?] = [
            "title": title.trimmingCharacters(in: .whitespaces),
            "description": descriptionText,
            "kind": isRoom ? "room" : "whole",
            "subtype": subtype,
            "rent_daily": rentDaily ? 1 : 0,
            "rent_long": rentLong ? 1 : 0,
            "check_in_from": LodgingFormat.timeString(checkIn),
            "check_out_until": LodgingFormat.timeString(checkOut),
            "cancel_penalty": cancelPenalty,
            "cancel_free_days": num(cancelFreeDays),
            "instant_booking": instant ? 1 : 0,
            "pets_allowed": pets ? 1 : 0,
            "smoking_allowed": smoking ? 1 : 0,
            "party_allowed": party ? 1 : 0,
            "kids_allowed": kids ? 1 : 0,
            "rules_text": rulesText,
            "address": address,
            "registry_no": registryNo,
            "amenities": Array(picked),
        ]
        // Ссылку на реестр отправляем, только если она заполнена или уже была:
        // сервер отдаёт блок registry лишь при непустом номере, и пустое поле
        // формы затирало бы ссылку, заданную в веб-кабинете.
        if !registryUrl.isEmpty || unit?.registry?.url != nil {
            body["registry_url"] = registryUrl
        }
        // Числа и деньги кладём только если поле заполнено: пустая строка не
        // должна превращаться в ноль и обнулять цену, заданную на сайте.
        if let v = num(baseGuests) { body["base_guests"] = v }
        if let v = num(maxGuests) { body["max_guests"] = v }
        if let v = num(maxChildren) { body["max_children"] = v }
        if let v = num(roomsCount) { body["rooms_count"] = v }
        if let v = num(inventory) { body["inventory"] = v }
        if let v = num(minNights) { body["min_nights"] = v }
        if let v = num(maxNights) { body["max_nights"] = v }
        // ОЧИЩЕННОЕ поле = «ноль», а не «не менять». Сервер трогает только
        // пришедшие ключи, поэтому пропуск ключа оставлял старое значение: было
        // 500 ₽ за уборку, продавец стёр поле, увидел «сохранено» — и гостям
        // по-прежнему начислялись 500 ₽. Ноль сервер сам превращает в NULL там,
        // где это «не задано» (площадь, цена выходного дня).
        body["area_m2"] = num(areaM2) ?? 0
        body["price_weekend"] = money(priceWeekend) ?? "0"
        body["cleaning_fee"] = money(cleaningFee) ?? "0"
        body["deposit"] = money(deposit) ?? "0"
        body["extra_guest_price"] = money(extraGuest) ?? "0"
        body["prepay_pct"] = money(prepayPct) ?? "0"
        // Цена за ночь — единственное поле, где пустота не «ноль», а «не
        // заполнено»: с нулём объект всё равно не публикуется, и затирать
        // заданную цену молча нельзя.
        if let v = money(priceNight) { body["price_night"] = v }
        if rentLong {
            if let v = money(priceMonth) { body["price_month"] = v }
            if let v = num(minMonths) { body["min_months"] = v }
            // Блок long_term сервер отдаёт ТОЛЬКО при rent_long = 1. Поэтому у
            // объекта с выключенной длительной арендой форма не знает, что
            // лежит в базе, и «ноль как очистка» тут стёр бы залог и
            // «коммунальные включены», заданные в веб-кабинете. Отправляем эти
            // поля, только если форма действительно ими владела: новый объект,
            // либо сервер прислал long_term, либо продавец сам что-то ввёл.
            let ownsLong = unit == nil || unit?.longTerm != nil
            if ownsLong || !depositMonth.isEmpty {
                body["deposit_month"] = money(depositMonth) ?? "0"
            }
            if ownsLong { body["utilities_included"] = utilitiesIncluded ? 1 : 0 }
            if ownsLong || !longNote.isEmpty { body["long_note"] = longNote }
        }
        // Денежные поля закрыты правом «Цены» (сервер отвечает 403 на любое из
        // них): без права просто не отправляем их — остальную форму сотрудник
        // сохранить может.
        if !Session.shared.can("products.price") {
            // Список — ровно тот, что проверяет сервер (routes/seller_lodging.php).
            // prepay_pct он правом «Цены» НЕ закрывает, поэтому его не вырезаем.
            for k in ["price_night", "price_weekend", "cleaning_fee", "deposit", "extra_guest_price",
                      "price_month", "deposit_month"] {
                body.removeValue(forKey: k)
            }
        }
        let id = await vm.save(id: unit?.id, body: body, keys: idem)
        if id != nil || vm.error == nil { dismiss() }
    }
}
