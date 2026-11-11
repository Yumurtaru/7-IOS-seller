import SwiftUI
import UIKit

// ============================================================================
//  Карточка товара: create / edit / delete.
//  Поля — точно как принимает saveProduct() (core/seller_products.php):
//  name, description, category_id, type, price, price_old, unit, weight,
//  article, barcode, tags[], allergens[], calories/proteins/fats/carbs,
//  status, is_available. Фото — multipart до 5 шт со сжатием.
//  AI-описание: POST .../ai-description (лимит 20/день, остаток показываем).
// ============================================================================

@MainActor
final class ProductEditViewModel: ObservableObject {
    /// Номер товара. У нового — nil до ответа сервера на создание: после него
    /// карточка остаётся открытой с номером (паритет с Android), и фото можно
    /// добавить сразу, не переоткрывая товар из списка.
    @Published private(set) var productId: Int?
    /// Карточка открыта как «Новый товар» (даже после того, как он создан).
    let isNew: Bool

    @Published var name = ""
    @Published var descriptionText = ""
    @Published var categoryId: Int?
    @Published var type = "product"
    @Published var price = ""
    @Published var priceOld = ""
    @Published var unit = ""
    @Published var weight = ""
    @Published var article = ""
    @Published var barcode = ""
    /// Скан штрихкода: подпись «взят из кода маркировки» и предупреждение о дубле (не блокирует сохранение).
    @Published var barcodeNote: String?
    @Published var barcodeWarning: String?
    /// Значение, подставленное сканером: ручная правка поля (значение другое) убирает подписи.
    private var scannedValue: String?
    private var dupGen = 0
    @Published var tags: [String] = []
    @Published var allergens: [String] = []
    @Published var calories = ""
    @Published var proteins = ""
    @Published var fats = ""
    @Published var carbs = ""
    @Published var status = "active"
    /// ВВ (сайт А819): товар скрыт модератором площадки — переключатель видимости заблокирован,
    /// статус в запрос не уходит (сервер оставит hidden). Ключей нет (старый сервер) — false.
    @Published private(set) var moderationHidden = false
    @Published private(set) var moderationReason = ""
    @Published var isAvailable = true
    /// Маркированный товар (Честный ЗНАК) — признак для кассы.
    @Published var isMarked = false
    @Published var photos: [ProductPhoto] = []
    @Published var modifierGroups: [ModifierGroup] = []

    // ── O1: оптовые цены ────────────────────────────────────────────────────
    /// Ступени в редакторе. Правка продавцом помечает блок «тронутым».
    @Published var tierRows: [Wholesale.Row] = [] {
        didSet { if tierRows != oldValue { tiersTouched = true; tiersError = nil } }
    }
    /// Текст ошибки под блоком (локальная проверка).
    @Published var tiersError: String?
    /// Продавец менял блок: ключ price_tiers уходит, даже если сервер его не присылал.
    private var tiersTouched = false
    /// Сервер прислал price_tiers у товара (новый сервер) — ключ уходит всегда.
    private var serverSentTiers = false
    /// qty_fractional товара: true — дробный, false — штучный, nil — не задан (решает категория, затем единица).
    private var qtyFractional: Bool?
    /// qty_fractional категорий по id (заполняет экран; только заданные значения).
    var categoryFractional: [Int: Bool] = [:]

    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var isSaving = false
    @Published var isUploading = false
    @Published var aiInfo: String?
    @Published var isGenerating = false
    /// short | normal | detailed — стиль AI-описания (по умолчанию «Обычно»).
    @Published var aiStyle = "normal"
    /// Ручки описания нового товара нет (404/405) — кнопка спрятана до перезапуска экрана.
    @Published var aiNewMissing = false
    /// Ответ ИИ ждёт подтверждения «Заменить описание?», если поле уже заполнено.
    @Published var pendingAiText: String?

    static let knownAllergens = ["Глютен", "Молоко", "Яйца", "Орехи", "Арахис", "Соя", "Рыба", "Морепродукты", "Кунжут", "Горчица"]
    static let knownTags = ["Новинка", "Хит", "Острое", "Веган", "Халяль", "Без сахара", "Детское"]

    // ── Создание: ключ повтора окна и неизвестный исход ─────────────────────
    /// Ключ повтора живёт, пока живёт окно: «Повторить» после обрыва уходит с
    /// тем же ключом и тем же телом — второй товар сервер не заведёт.
    let idem = IdempotencyKeys.form()
    /// Создание ушло, а ответа нет (обрыв, таймаут, 5xx): товар мог уже
    /// создаться. Поля формы заблокированы, «Сохранить» становится «Повторить».
    @Published private(set) var unknownOutcome = false
    /// Тело запроса, исход которого неизвестен, — повтор уходит байт-в-байт тем же.
    private var pendingBody: [String: Any?]?
    /// Товар только что создан — подсказка «добавьте фото».
    @Published var createdNotice: String?
    /// Форма восстановлена из черновика (приложение выгружали).
    @Published var restoredDraft = false
    /// В черновике отмечено: прошлое создание могло дойти до сервера.
    @Published var draftMaybeSent = false
    /// Ключ черновика — аккаунт и организация на момент открытия карточки
    /// (см. ProductDraftStore.currentKey). Смена магазина его не меняет.
    private let draftKey: String?

    init(productId: Int?, initialBarcode: String? = nil) {
        self.productId = productId
        self.isNew = productId == nil
        self.draftKey = productId == nil ? ProductDraftStore.currentKey() : nil
        // паритет с Android: новая позиция кафе — блюдо, у услуг — услуга. Раньше
        // всегда «Товар», и блюдо, заведённое с iPhone, на кухне было «товаром».
        if productId == nil {
            switch OrderStatuses.shopType {
            case "cafe": type = "dish"
            case "service": type = "service"
            default: type = "product"
            }
            // Черновик, который пережил выгрузку приложения (паритет с Android).
            if let d = ProductDraftStore.load(key: draftKey) {
                apply(d)
                restoredDraft = true
                draftMaybeSent = d.maybeSent
            }
            // Со списка товаров: ничего не нашли по отсканированному коду и создаём товар с ним.
            if let code = initialBarcode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
                barcode = code
            }
        }
    }

    // ── Черновик нового товара ───────────────────────────────────────────────
    private func apply(_ d: ProductDraft) {
        name = d.name; descriptionText = d.descriptionText; categoryId = d.categoryId
        type = d.type; price = d.price; priceOld = d.priceOld; unit = d.unit; weight = d.weight
        article = d.article; barcode = d.barcode; tags = d.tags; allergens = d.allergens
        calories = d.calories; proteins = d.proteins; fats = d.fats; carbs = d.carbs
        status = d.status; isAvailable = d.isAvailable; isMarked = d.isMarked
        tierRows = (d.tiers ?? []).map { Wholesale.Row(qty: $0.qty, price: $0.price) }
        tiersTouched = !tierRows.isEmpty
    }

    private func draft(maybeSent: Bool) -> ProductDraft {
        ProductDraft(name: name, descriptionText: descriptionText, categoryId: categoryId, type: type,
                     price: price, priceOld: priceOld, unit: unit, weight: weight,
                     article: article, barcode: barcode, tags: tags, allergens: allergens,
                     calories: calories, proteins: proteins, fats: fats, carbs: carbs,
                     status: status, isAvailable: isAvailable, isMarked: isMarked,
                     tiers: tierRows.isEmpty ? nil : tierRows.map { DraftTier(qty: $0.qty, price: $0.price) },
                     maybeSent: maybeSent)
    }

    /// Черновик закрыт кнопкой «Закрыть» — больше не пишем.
    private var draftDiscarded = false

    /// Запомнить форму нового товара (уход в фон, закрытие экрана без «Закрыть»).
    /// Товар уже создан — черновик не нужен.
    func persistDraftIfNeeded() {
        guard isNew, productId == nil, !draftDiscarded else { return }
        // Запрос в пути — исход тоже неизвестен (выгрузили посреди создания).
        ProductDraftStore.save(draft(maybeSent: isSaving || unknownOutcome || draftMaybeSent), key: draftKey)
    }

    /// «Закрыть»: продавец сам отказался от формы — черновик стираем.
    func discardDraft() {
        guard isNew else { return }
        draftDiscarded = true
        ProductDraftStore.clear(key: draftKey)
    }

    /// «Очистить форму» у восстановленного черновика.
    func resetDraft() {
        guard isNew, productId == nil, !isSaving, !unknownOutcome else { return }
        ProductDraftStore.clear(key: draftKey)
        let fresh = ProductEditViewModel(productId: nil)
        // Новый экземпляр уже не найдёт черновика — берём его умолчания.
        apply(fresh.draft(maybeSent: false))
        tierRows = []
        tiersTouched = false
        tiersError = nil
        restoredDraft = false
        draftMaybeSent = false
        error = nil
    }

    /// Есть ли что терять при закрытии нового товара.
    var hasUnsavedNew: Bool { isNew && productId == nil && draft(maybeSent: false).hasContent }

    /// Карточка загружена целиком (или это новый товар). Нужна экрану, чтобы
    /// повторить загрузку, которую прервали уходом на другую вкладку.
    private(set) var loadedOnce = false
    /// Номер последнего запуска load(): ответ прерванного (устаревшего) запуска
    /// не должен перетирать форму или сбрасывать state в .idle поверх нового.
    private var loadGen = 0

    func load() async {
        guard let id = productId else { state = .loaded; loadedOnce = true; return }
        loadGen += 1
        let gen = loadGen
        state = .loading
        do {
            let p = try await API.shared.product(id: id)
            guard gen == loadGen else { return }
            name = p.name ?? ""
            descriptionText = p.description ?? ""
            categoryId = p.categoryId
            type = p.type ?? "product"
            price = p.price.map { "\($0)" } ?? ""
            priceOld = p.priceOld.map { "\($0)" } ?? ""
            unit = p.unit ?? ""
            weight = p.weight.map { "\($0)" } ?? ""
            article = p.article ?? ""
            barcode = p.barcode ?? ""
            tags = p.tags ?? []
            allergens = p.allergens ?? []
            calories = p.calories.map { "\($0)" } ?? ""
            proteins = p.proteins.map { "\($0)" } ?? ""
            fats = p.fats.map { "\($0)" } ?? ""
            carbs = p.carbs.map { "\($0)" } ?? ""
            moderationHidden = p.moderationHidden == true
            moderationReason = (p.moderationReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            status = moderationHidden ? "hidden" : (p.status ?? "active")
            isAvailable = p.isAvailable ?? true
            isMarked = p.isMarked ?? false
            photos = p.photos ?? []
            serverSentTiers = p.priceTiers != nil
            qtyFractional = p.qtyFractional
            tierRows = Wholesale.rows(from: p.priceTiers)
            tiersTouched = false
            tiersError = nil
            let mods = (try? await API.shared.productModifiers(productId: id)) ?? []
            guard gen == loadGen else { return }
            modifierGroups = mods
            state = .loaded
            loadedOnce = true
        } catch is CancellationError {
            // Прервали (ушли на другую вкладку) — при возврате загрузим снова,
            // а не оставим вечный спиннер над пустой формой.
            if gen == loadGen { state = .idle }
        } catch {
            if gen == loadGen { state = .failed(error.localizedDescription) }
        }
    }

    // ── Сканер штрихкода ─────────────────────────────────────────────────────
    /// Скан: значение заменяет поле, затем тихая проверка дубля по списку товаров.
    func applyScanned(_ result: BarcodeScanResult) {
        scannedValue = result.value
        barcodeNote = result.fromMarking ? BarcodeLogic.markingNote : nil
        barcodeWarning = nil
        barcode = result.value
        dupGen += 1
        let gen = dupGen
        let code = result.value
        Task { await checkDuplicate(code: code, gen: gen) }
    }

    /// Поле правили руками — подписи и идущая проверка отменяются.
    func barcodeEdited(_ newValue: String) {
        if newValue == scannedValue { return }
        scannedValue = nil
        barcodeNote = nil
        barcodeWarning = nil
        dupGen += 1
    }

    /// GET /api/seller/products?q=<код>, первая страница. Ошибка сети — молча.
    private func checkDuplicate(code: String, gen: Int) async {
        guard let page = try? await API.shared.products(category: nil, status: nil, q: code, page: 1) else { return }
        guard gen == dupGen, barcode == code else { return }
        let me = productId
        let other = page.items.first { item in
            (item.barcode ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == code && (me == nil || item.id != me)
        }
        if let other = other {
            let title = (other.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            barcodeWarning = "Этот штрихкод уже есть у товара «\(title.isEmpty ? "—" : title)»"
        }
    }

    /// Число для сервера после строгой проверки (save() уже отсеял мусор).
    private func num(_ s: String) -> String? {
        guard let t = dec(s) else { return nil }
        return Money.strict(t, maxFraction: 3).map { "\($0)" } ?? t
    }

    private func dec(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return t.isEmpty ? nil : t
    }

    /// 422 с errors.price_tiers: первый текст сервера — под блоком «Оптовые цены».
    private static func tiersText(_ error: Error) -> String? {
        guard let d = error as? APIDetailedError,
              let t = d.fields["price_tiers"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty else { return nil }
        return t
    }

    func save() async -> Bool {
        // Двойной тап «Сохранить» у нового товара создавал два одинаковых товара.
        guard !isSaving else { return false }
        error = nil
        // Повтор создания после неизвестного исхода: то же тело, тот же ключ окна.
        if productId == nil, unknownOutcome, let body = pendingBody {
            return await create(body)
        }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n.count >= 2 else { error = "Название — минимум 2 символа"; return false }
        // паритет с Android: сервер (seller_products.php, name max:190) длиннее не примет.
        guard n.count <= 190 else { error = "Название — не длиннее 190 символов"; return false }
        // Строгий разбор: «1 500» раньше проходило (Decimal читал «1») и
        // уходило на сервер, где превращалось в 1 ₽.
        guard let priceRaw = dec(price), let priceNum = Money.strict(priceRaw) else {
            error = "Укажите корректную цену"; return false
        }
        let priceValue = "\(priceNum)"
        // O1: оптовые ступени. Право «Цены» — как у поля цены: без него ключ не шлём.
        var tiersBody: [[String: Any]]?
        if Session.shared.can("products.price") && (serverSentTiers || tiersTouched) {
            var catFrac: Bool?
            if let cid = categoryId { catFrac = categoryFractional[cid] }
            let pieceItem = Wholesale.isPiece(unit: unit, fractional: qtyFractional ?? catFrac)
            if let msg = Wholesale.validate(rows: tierRows, retail: priceNum, piece: pieceItem) {
                tiersError = msg
                return false
            }
            tiersBody = Wholesale.payload(rows: tierRows)   // все строки удалены — []
        }
        tiersError = nil
        // Старая цена — деньги: копейки, не тысячные (иначе сервер округлял молча).
        if let t = dec(priceOld), Money.strict(t) == nil {
            error = "Старая цена — сумма, например 1500 или 99,90"; return false
        }
        for (raw, label) in [(priceOld, "Старая цена"), (weight, "Вес"), (calories, "Калории"),
                             (proteins, "Белки"), (fats, "Жиры"), (carbs, "Углеводы")] {
            if let t = dec(raw), Money.strict(t, maxFraction: 3) == nil {
                error = "\(label) — число, например 1500 или 0,5"; return false
            }
        }
        isSaving = true
        defer { isSaving = false }
        let art = article.trimmingCharacters(in: .whitespacesAndNewlines)
        let bc = barcode.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: Any?] = [
            "name": n,
            "description": descriptionText.isEmpty ? nil : descriptionText,
            "category_id": categoryId,
            "type": type,
            "price": priceValue,
            "price_old": num(priceOld),
            "unit": unit.isEmpty ? nil : unit,
            "weight": num(weight),
            // паритет с Android: пробелы по краям срезаем — «A-15 » не находился поиском и кассой.
            "article": art.isEmpty ? nil : art,
            "barcode": bc.isEmpty ? nil : bc,
            "tags": tags,
            "allergens": allergens,
            "calories": num(calories),
            "proteins": num(proteins),
            "fats": num(fats),
            "carbs": num(carbs),
            "status": status,
            "is_available": isAvailable ? 1 : 0,
            "is_marked": isMarked ? 1 : 0,
        ]
        // Ключ — только если сервер прислал поле или продавец трогал блок (иначе его нет совсем).
        if let tiersBody = tiersBody { fields["price_tiers"] = tiersBody }
        // ВВ (А819): скрыт модератором — ключ статуса не шлём совсем (не null): сервер оставит hidden,
        // а остальные поля сохранит.
        if Bb.statusForSave(hidden: status == "hidden", moderationHidden: moderationHidden) == nil {
            fields.removeValue(forKey: "status")
        }
        do {
            // nil → явный null: makeRequest выкидывает nil-ключи (compactMapValues),
            // и сервер (saveProduct: «нет ключа — не трогаем») оставлял старое
            // значение — очищенные «Старая цена», артикул, КБЖУ не очищались.
            let body = fields.mapValues { v -> Any? in v ?? NSNull() }
            guard let id = productId else { return await create(body) }
            try await API.shared.saveProduct(id: id, fields: body)
            return true
        } catch {
            if let t = Self.tiersText(error) { tiersError = t } else { self.error = error.localizedDescription }
            return false
        }
    }

    /// Создание нового товара с ключом повтора окна. true — создан: карточка
    /// получает номер и остаётся открытой (фото можно добавить сразу).
    private func create(_ body: [String: Any?]) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        let wasUnknown = unknownOutcome
        pendingBody = body
        // Перед отправкой: выгрузят приложение посреди запроса — черновик
        // вернётся с пометкой «могло дойти».
        if !draftDiscarded { ProductDraftStore.save(draft(maybeSent: true), key: draftKey) }
        do {
            let newId = try await API.shared.createProduct(fields: body, keys: idem)
            pendingBody = nil
            unknownOutcome = false
            draftMaybeSent = false
            restoredDraft = false
            ProductDraftStore.clear(key: draftKey)
            if let newId, newId > 0 {
                productId = newId
                loadedOnce = true
                state = .loaded
                createdNotice = "Товар создан (№\(newId)). Добавьте фото ниже — до 5 снимков — или нажмите «Готово»."
            }
            return true
        } catch {
            let raw = error.localizedDescription
            let msg = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
            if API.keyedOutcomeUnknown(error) {
                // Ключ окна сохранён: повтор не создаст второй товар.
                unknownOutcome = true
                self.error = msg + ". Товар мог уже создаться — нажмите «Повторить»: второй раз он не заведётся."
            } else {
                // Ответ сервера получен (проверка полей, 401, 429…) — форма снова открыта.
                unknownOutcome = false
                pendingBody = nil
                if wasUnknown {
                    draftMaybeSent = true
                    self.error = msg + ". Прошлая попытка могла создать товар — проверьте список товаров, прежде чем сохранять снова."
                } else {
                    if let t = Self.tiersText(error) { tiersError = t } else { self.error = raw }
                }
                // 401 на первой попытке — запрос не выполнен: черновик без пометки
                // «могло дойти» (ключ черновика взят при открытии и пережил выход).
                if !draftDiscarded { ProductDraftStore.save(draft(maybeSent: draftMaybeSent), key: draftKey) }
            }
            return false
        }
    }

    func deleteProduct() async -> Bool {
        guard let id = productId else { return false }
        do {
            try await API.shared.deleteProduct(id: id)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func uploadPhoto(_ image: UIImage) async {
        guard let id = productId else {
            error = "Сначала сохраните товар, потом добавьте фото"
            return
        }
        guard photos.count < 5 else { error = "Максимум 5 фото"; return }
        isUploading = true
        error = nil
        defer { isUploading = false }
        // Сжатие фото с камеры на главном потоке подвешивало экран на полсекунды.
        guard let data = await Task.detached(operation: { ImageCompressor.jpegForUpload(image) }).value else {
            // Раньше — молча ничего: крутилка гасла, фото не появлялось, причины не видно.
            error = "Не удалось подготовить фото к отправке — выберите другое или снимите заново"
            return
        }
        do {
            let res = try await API.shared.uploadProductPhoto(productId: id, jpeg: data)
            photos.append(ProductPhoto(id: res.id, pathWebp: res.pathWebp, sortOrder: photos.count))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Фото, удаление которых уже в пути: второй тап по крестику слал второй
    /// DELETE, и он возвращался ошибкой «не найдено» поверх успешного удаления.
    @Published private(set) var deletingPhotoIds: Set<Int> = []

    func deletePhoto(_ photo: ProductPhoto) async {
        guard let id = productId, !deletingPhotoIds.contains(photo.photoId) else { return }
        deletingPhotoIds.insert(photo.photoId)
        defer { deletingPhotoIds.remove(photo.photoId) }
        do {
            try await API.shared.deleteProductPhoto(productId: id, photoId: photo.photoId)
            photos.removeAll { $0.photoId == photo.photoId }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// АY (сайт А616): порядок фото уже уходит — второй сдвиг ждёт ответа.
    @Published private(set) var reorderingPhotos = false

    /// Переставить фото (первое — главное на витрине): POST photos/reorder.
    /// Порядок на экране меняем только после ответа сервера.
    func movePhoto(_ photo: ProductPhoto, to index: Int) async {
        guard let id = productId, !reorderingPhotos,
              let from = photos.firstIndex(where: { $0.photoId == photo.photoId }),
              index >= 0, index < photos.count, index != from else { return }
        var next = photos
        let moved = next.remove(at: from)
        next.insert(moved, at: index)
        reorderingPhotos = true
        defer { reorderingPhotos = false }
        error = nil
        do {
            try await API.shared.reorderProductPhotos(productId: id, ids: next.map(\.photoId))
            photos = next
        } catch let e as APIDetailedError where e.status == 409
                    && (e.code == "photos_changed" || e.extras["code"] == "photos_changed") {
            // Фото добавили или удалили в другом месте — перечитываем список.
            if let fresh = try? await API.shared.product(id: id) { photos = fresh.photos ?? photos }
            error = "Фото изменились — список обновлён"
        } catch where API.keyedOutcomeUnknown(error) {
            // Связь оборвалась — порядок мог сохраниться: показываем то, что на сервере.
            let raw = error.localizedDescription
            let msg = raw.hasSuffix(".") ? String(raw.dropLast()) : raw
            if let fresh = try? await API.shared.product(id: id) { photos = fresh.photos ?? photos }
            self.error = msg + ". Порядок фото мог сохраниться — список обновлён, проверьте его"
        } catch {
            self.error = API.isNoRoute(error) ? AnalyticsExtraText.unavailable : error.localizedDescription
        }
    }

    /// AI-описание — ЧЕРНОВИК (сервер в БД не пишет), продавец правит и сохраняет сам.
    func generateDescription() async {
        let id = productId
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == nil && nm.isEmpty {
            error = "Сначала укажите название"
            return
        }
        isGenerating = true
        error = nil
        aiInfo = nil
        defer { isGenerating = false }
        let desc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let un = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let wt = weight.trimmingCharacters(in: .whitespacesAndNewlines)
        var body: [String: Any?] = ["style": aiStyle]
        if !nm.isEmpty { body["name"] = nm }
        if let c = categoryId, c > 0 { body["category_id"] = c }
        if !un.isEmpty { body["unit"] = un }
        if !wt.isEmpty { body["weight"] = wt }
        if !tags.isEmpty { body["tags"] = tags }
        if !allergens.isEmpty { body["allergens"] = allergens }
        if !desc.isEmpty { body["description"] = desc }
        do {
            let res = try await API.shared.aiDescription(productId: id, body: body)
            var parts: [String] = []
            if res.photoUsed == true { parts.append("Учтено фото товара") }
            if let used = res.usedToday, let limit = res.limit { parts.append("Сегодня: \(used) из \(limit)") }
            aiInfo = parts.isEmpty ? nil : parts.joined(separator: ". ")
            if let text = res.description, !text.isEmpty {
                // Поле не пустое — спрашиваем «Заменить описание?» (экран показывает алерт).
                if descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { descriptionText = text }
                else { pendingAiText = text }
            }
        } catch {
            // Новой ручки на сервере нет (404/405): кнопку для нового товара прячем до перезапуска экрана.
            if id == nil, ProductEditViewModel.isMissingAiRoute(error) {
                aiNewMissing = true
                return
            }
            self.error = error.localizedDescription   // в т.ч. «Дневной лимит…» (429)
        }
    }

    private static func isMissingAiRoute(_ error: Error) -> Bool {
        if let e = error as? APIDetailedError { return e.status == 404 || e.status == 405 }
        if case APIError.http(let c) = error { return c == 404 || c == 405 }
        return false
    }
}

struct ProductEditView: View {
    @StateObject private var vm: ProductEditViewModel
    let categories: [SellerCategory]
    @Environment(\.dismiss) private var dismiss
    @State private var showLibrary = false
    @State private var showCamera = false
    /// Категории, догруженные самой карточкой (если список их не передал).
    @State private var fetchedCategories: [SellerCategory] = []
    @State private var showDeleteConfirm = false
    /// Товар удалён — список убирает его строку (иначе удалённый висел до обновления).
    private let onDeleted: (() -> Void)?
    /// Карточка открыта листом «Новый товар»: своя кнопка «Закрыть» (её гасим,
    /// пока создание в пути, и спрашиваем, если форма заполнена).
    private let onClose: (() -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmClose = false

    init(productId: Int?, categories: [SellerCategory], onDeleted: (() -> Void)? = nil,
         onClose: (() -> Void)? = nil, initialBarcode: String? = nil) {
        _vm = StateObject(wrappedValue: ProductEditViewModel(productId: productId, initialBarcode: initialBarcode))
        self.categories = categories
        self.onDeleted = onDeleted
        self.onClose = onClose
    }

    var body: some View {
        content
            .navigationTitle(vm.productId == nil ? "Новый товар" : "Товар")
            .navigationBarTitleDisplayMode(.inline)
            // Пока сохранение в пути — «Назад» не уводит с экрана.
            .navigationBarBackButtonHidden(vm.isSaving)
            .toolbar {
                if onClose != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(vm.isNew && vm.productId != nil ? "Готово" : "Закрыть") { requestClose() }
                            .disabled(vm.isSaving)
                    }
                }
            }
            .confirmationDialog(closeTitle, isPresented: $confirmClose, titleVisibility: .visible) {
                Button(vm.unknownOutcome ? "Закрыть и проверить список" : "Закрыть без сохранения",
                       role: .destructive) { close() }
                Button("Остаться", role: .cancel) {}
            } message: {
                Text(vm.unknownOutcome
                     ? "Связь прервалась во время создания — товар мог сохраниться. После закрытия список товаров перечитается: проверьте его, прежде чем заводить товар снова."
                     : "Заполненная карточка не сохранена и пропадёт.")
            }
            // Приложение ушло в фон — запоминаем форму нового товара: телефон может
            // выгрузить приложение, и раньше набранное пропадало.
            .onChange(of: scenePhase) { phase in
                if phase != .active { vm.persistDraftIfNeeded() }
            }
            .onDisappear { vm.persistDraftIfNeeded() }
    }

    private var closeTitle: String {
        vm.unknownOutcome ? "Товар мог уже сохраниться" : "Закрыть новый товар?"
    }

    private func requestClose() {
        guard !vm.isSaving else { return }
        if vm.unknownOutcome || vm.hasUnsavedNew { confirmClose = true } else { close() }
    }

    private func close() {
        vm.discardDraft()
        if let onClose { onClose() } else { dismiss() }
    }

    /// Сохранили правку (или старый сервер не вернул номер нового товара) — закрываем.
    private func finishAfterSave() {
        if vm.isNew { close() } else { dismiss() }
    }

    @ViewBuilder
    private var content: some View {
        Form {
            if let err = vm.error {
                Section { Text(err).foregroundColor(Brand.red).font(.footnote) }
            }
            if let note = vm.createdNotice {
                Section { Label(note, systemImage: "checkmark.circle.fill").foregroundColor(Brand.green).font(.footnote) }
            }
            if vm.restoredDraft && vm.productId == nil {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Восстановлен несохранённый черновик — проверьте поля и сохраните.")
                            .font(.footnote).foregroundColor(Brand.amber)
                        if vm.draftMaybeSent {
                            Text("Прошлое сохранение могло дойти до сервера. Проверьте список товаров, чтобы не завести такой же товар второй раз.")
                                .font(.footnote.weight(.semibold)).foregroundColor(Brand.red)
                        }
                        Button("Очистить форму") { vm.resetDraft() }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderless)
                            .disabled(vm.isSaving || vm.unknownOutcome)
                    }
                }
            }

            // Пока создание в пути или его исход неизвестен — поля заблокированы:
            // «Повторить» уходит тем же телом с тем же ключом повтора.
            Group {
                // ВВ (сайт А819): бейдж «Скрыт модератором», причина и выход — поддержка.
                if vm.moderationHidden {
                    Section {
                        Text(Bb.moderationBadge).font(.headline).foregroundColor(Brand.red)
                        if let line = Bb.moderationReasonLine(vm.moderationReason) {
                            Text(line).font(.subheadline)
                        }
                        Text(Bb.moderationNote).font(.footnote).foregroundColor(Brand.muted)
                        NavigationLink(Bb.supportButton) { ShopSupportView() }
                    }
                }
                Section("Основное") {
                    TextField("Название", text: $vm.name)
                    Picker("Тип", selection: $vm.type) {
                        Text("Товар").tag("product")
                        Text("Блюдо").tag("dish")
                        Text("Услуга").tag("service")
                    }
                    Picker("Категория", selection: $vm.categoryId) {
                        Text("Без категории").tag(Int?.none)
                        ForEach(categories.isEmpty ? fetchedCategories : categories) { c in
                            Text(c.name ?? "—").tag(Int?.some(c.categoryId))
                        }
                    }
                    Toggle("В наличии", isOn: $vm.isAvailable)
                    Picker("Видимость", selection: $vm.status) {
                        Text("Активен").tag("active")
                        Text("Скрыт").tag("hidden")
                    }
                    .disabled(vm.moderationHidden)
                    Toggle(isOn: $vm.isMarked) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Маркированный товар")
                            Text("Касса потребует скан DataMatrix и передаст код в ОФД: табак, обувь, одежда, молочное, вода, пиво.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Описание") {
                    TextEditor(text: $vm.descriptionText)
                        .frame(minHeight: 90)
                    if vm.productId != nil || !vm.aiNewMissing {
                        Picker("Стиль", selection: $vm.aiStyle) {
                            Text("Коротко").tag("short")
                            Text("Обычно").tag("normal")
                            Text("Подробно").tag("detailed")
                        }
                        .pickerStyle(.segmented)
                        Button {
                            Task { await vm.generateDescription() }
                        } label: {
                            HStack {
                                if vm.isGenerating { ProgressView() } else { Image(systemName: "sparkles") }
                                Text(vm.productId == nil ? "Придумать описание" : "Сгенерировать описание (AI)")
                            }
                        }
                        .disabled(vm.isGenerating)
                    } else {
                        // Сайт ещё без ручки для нового товара — как раньше.
                        Text("AI-описание доступно после сохранения товара")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                    if let info = vm.aiInfo {
                        Text(info).font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .alert("Заменить описание?", isPresented: Binding(
                    get: { vm.pendingAiText != nil },
                    set: { if !$0 { vm.pendingAiText = nil } }
                )) {
                    Button("Заменить") {
                        if let t = vm.pendingAiText { vm.descriptionText = t }
                        vm.pendingAiText = nil
                    }
                    Button("Отмена", role: .cancel) { vm.pendingAiText = nil }
                } message: {
                    Text("Текущее описание будет заменено предложенным.")
                }

                // П-22.1: без права «Цены» сервер отклоняет (403) ВСЁ сохранение, если
                // цена изменилась. Раньше поле было открыто: сотрудник правил цену и
                // терял остальные правки карточки. Тот же текст цены уходит без отказа.
                Section {
                    TextField("Цена, ₽", text: $vm.price).keyboardType(.decimalPad)
                        .disabled(!canEditPrice)
                    TextField("Старая цена (зачёркнутая), ₽", text: $vm.priceOld).keyboardType(.decimalPad)
                        .disabled(!canEditPrice)
                } header: {
                    Text("Цена")
                } footer: {
                    if createLocked {
                        Text("Новый товар с ценой заводит владелец или сотрудник с правом «Менять цены» — сохранить его нельзя.")
                    } else if !canEditPrice {
                        Text("Цену меняет сотрудник с правом «Менять цены» или владелец.")
                    }
                }

                wholesaleSection

                Section("Учёт") {
                    TextField("Артикул", text: $vm.article)
                    HStack(spacing: 6) {
                        TextField("Штрихкод", text: $vm.barcode).keyboardType(.numberPad)
                            .onChange(of: vm.barcode) { newValue in vm.barcodeEdited(newValue) }
                        BarcodeScanButton { result in vm.applyScanned(result) }
                    }
                    if let note = vm.barcodeNote {
                        Text(note).font(.footnote).foregroundColor(Brand.muted)
                    }
                    if let warn = vm.barcodeWarning {
                        Text(warn).font(.footnote).foregroundColor(Brand.amber)
                    }
                    TextField("Единица (шт, кг, л…)", text: $vm.unit)
                    TextField("Вес/объём", text: $vm.weight).keyboardType(.decimalPad)
                }

                Section("Пищевая ценность (на 100 г)") {
                    TextField("Калории", text: $vm.calories).keyboardType(.decimalPad)
                    TextField("Белки", text: $vm.proteins).keyboardType(.decimalPad)
                    TextField("Жиры", text: $vm.fats).keyboardType(.decimalPad)
                    TextField("Углеводы", text: $vm.carbs).keyboardType(.decimalPad)
                }

                Section("Теги") {
                    ChipsEditor(all: ProductEditViewModel.knownTags, selected: $vm.tags)
                }

                Section("Аллергены") {
                    ChipsEditor(all: ProductEditViewModel.knownAllergens, selected: $vm.allergens)
                }
            }
            .disabled(vm.isSaving || vm.unknownOutcome)

            if vm.productId != nil {
                photosSection
                modifiersSection
            } else {
                // У нового товара раздела «Фото» не было вовсе — первый товар
                // заводили без снимка, не зная, что фото добавляется позже.
                // Паритет с Android: после «Сохранить» карточка остаётся открытой.
                Section("Фото") {
                    Text("Фото (до 5) и модификаторы добавляются сразу после сохранения — карточка останется открытой.")
                        .font(.caption).foregroundColor(Brand.muted)
                }
            }

            Section {
                // Ошибка сохранения и у самой кнопки: форма длинная, «Сохранить»
                // внизу, а текст ошибки был только в самом верху — нажатие
                // выглядело так, будто ничего не произошло.
                if let err = vm.error {
                    Text(err).foregroundColor(Brand.red).font(.footnote)
                }
                Button {
                    // Новый товар после создания не закрываем (паритет с Android):
                    // сразу добавляются фото. Правка существующего — как раньше.
                    let creating = vm.productId == nil
                    Task {
                        if await vm.save() {
                            if !(creating && vm.productId != nil) { finishAfterSave() }
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        if vm.isSaving { ProgressView() } else { Text(vm.unknownOutcome ? "Повторить" : "Сохранить").bold() }
                        Spacer()
                    }
                }
                .disabled(vm.isSaving || createLocked)

                if vm.isNew && vm.productId != nil {
                    Button { close() } label: {
                        HStack { Spacer(); Text("Готово"); Spacer() }
                    }
                    .disabled(vm.isSaving)
                }

                // Удаление товара — отдельное право внутри «Товаров».
                if vm.productId != nil && Session.shared.can("products.delete") {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack { Spacer(); Text("Удалить товар"); Spacer() }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .confirmationDialog("Удалить товар безвозвратно?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                Task { if await vm.deleteProduct() { onDeleted?(); dismiss() } }
            }
        }
        .sheet(isPresented: $showLibrary) {
            PhotoLibraryPicker(onPick: { image in Task { await vm.uploadPhoto(image) } },
                               onFail: { vm.error = $0 })
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in Task { await vm.uploadPhoto(image) } }
                .ignoresSafeArea()
        }
        .overlay {
            if case .failed(let msg) = vm.state {
                ErrorBanner(message: msg) { Task { await vm.load() } }
                    .background(Brand.bg)
            } else if vm.state == .loading {
                ProgressView().controlSize(.large)
            }
        }
        // Только при первом появлении. Камера — fullScreenCover: после снимка
        // экран «появляется» снова, и .task перечитывал товар с сервера поверх
        // несохранённых правок (цена, название), а «Сохранить» потом сохраняло
        // старые данные.
        // Загрузку, прерванную уходом на другую вкладку, повторяем при возврате:
        // раньше оставался вечный спиннер над пустой формой.
        .task {
            // Без проверки state != .loading: прерванная загрузка могла ещё не
            // вернуть CancellationError — тогда новую пропускали, и форма оставалась пустой.
            vm.categoryFractional = Self.fractionalMap(categories)
            if !vm.loadedOnce { await vm.load() }
            // Список категорий не загрузился на экране товаров — грузим сами:
            // иначе у нового товара в выборе было только «Без категории».
            if categories.isEmpty && fetchedCategories.isEmpty {
                fetchedCategories = (try? await API.shared.categories()) ?? []
                vm.categoryFractional = Self.fractionalMap(fetchedCategories)
            }
        }
    }

    /// id категории → qty_fractional (только где задан).
    private static func fractionalMap(_ cs: [SellerCategory]) -> [Int: Bool] {
        var m: [Int: Bool] = [:]
        for c in cs {
            if let f = c.qtyFractional { m[c.categoryId] = f }
        }
        return m
    }

    /// Цену правит только тот, у кого есть право «Цены». У нового товара цена
    /// обязательна, и без права сервер не создаёт его вовсе (403, А116).
    private var canEditPrice: Bool {
        Session.shared.can("products.price")
    }

    /// Новый товар без права «Цены» — сохранить нельзя (сервер ответит 403).
    private var createLocked: Bool { vm.productId == nil && !canEditPrice }

    /// O1: «Оптовые цены». Право «Цены» — как у поля цены.
    private var wholesaleSection: some View {
        let unitText = Wholesale.unitLabel(vm.unit)
        return Section {
            ForEach($vm.tierRows) { $row in
                HStack(spacing: 6) {
                    Text("от")
                    TextField("0", text: $row.qty).keyboardType(.decimalPad)
                        .multilineTextAlignment(.center).frame(width: 64)
                    Text(unitText)
                    Text("—")
                    TextField("0", text: $row.price).keyboardType(.decimalPad)
                        .multilineTextAlignment(.center).frame(width: 72)
                    Text("₽ за \(unitText)").lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        let id = row.id
                        vm.tierRows.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "trash").foregroundColor(Brand.red)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Удалить ступень")
                }
                .font(.subheadline)
                .disabled(!canEditPrice)
            }
            if vm.tierRows.count < Wholesale.maxTiers {
                Button("+ Добавить ступень") { vm.tierRows.append(Wholesale.Row()) }
                    .disabled(!canEditPrice)
            }
            if let err = vm.tiersError {
                Text(err).foregroundColor(Brand.red).font(.footnote)
            }
        } header: {
            Text("Оптовые цены")
        } footer: {
            Text(Wholesale.hint)
        }
    }

    private var photosSection: some View {
        Section("Фото (\(vm.photos.count)/5)") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(vm.photos) { photo in
                        ZStack(alignment: .topTrailing) {
                            RemoteImage(path: photo.pathWebp, size: 84, cornerRadius: 12, fit: true)
                            Button {
                                Task { await vm.deletePhoto(photo) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white, Brand.red)
                            }
                            // Кнопки строки Form без стиля срабатывают от тапа по
                            // строке все разом — касание по фото удаляло все фото.
                            .buttonStyle(.borderless)
                            .offset(x: 6, y: -6)
                            .disabled(vm.deletingPhotoIds.contains(photo.photoId))
                        }
                        // АY (сайт А616): порядок фото — долгим нажатием; первое — главное.
                        .contextMenu {
                            if vm.photos.count > 1, let i = vm.photos.firstIndex(where: { $0.photoId == photo.photoId }) {
                                if i > 0 {
                                    Button { Task { await vm.movePhoto(photo, to: 0) } } label: {
                                        Label("Сделать главным", systemImage: "star")
                                    }
                                    Button { Task { await vm.movePhoto(photo, to: i - 1) } } label: {
                                        Label("Левее", systemImage: "arrow.left")
                                    }
                                }
                                if i < vm.photos.count - 1 {
                                    Button { Task { await vm.movePhoto(photo, to: i + 1) } } label: {
                                        Label("Правее", systemImage: "arrow.right")
                                    }
                                }
                            }
                        }
                        .opacity(vm.reorderingPhotos ? 0.6 : 1)
                    }
                    if vm.photos.count < 5 {
                        Menu {
                            Button { showCamera = true } label: { Label("Камера", systemImage: "camera") }
                            Button { showLibrary = true } label: { Label("Галерея", systemImage: "photo.on.rectangle") }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12).fill(Brand.chip)
                                if vm.isUploading { ProgressView() } else {
                                    Image(systemName: "plus").font(.title2).foregroundColor(Brand.muted)
                                }
                            }
                            .frame(width: 84, height: 84)
                        }
                        .disabled(vm.isUploading)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var modifiersSection: some View {
        Section("Модификаторы") {
            if vm.modifierGroups.isEmpty {
                // Раздел «Модификаторы» в приложении уже есть — не отправляем на сайт.
                Text("Нет групп модификаторов. Добавить группу можно в разделе «Ещё» → «Модификаторы».")
                    .font(.caption).foregroundColor(Brand.muted)
            } else {
                ForEach(vm.modifierGroups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(group.name ?? "Группа").font(.subheadline.weight(.semibold))
                            if group.isRequired == true {
                                StatusBadge(text: "Обязательная", color: Brand.amber)
                            }
                        }
                        ForEach(group.options ?? []) { opt in
                            HStack {
                                Text(opt.name ?? "—").font(.caption)
                                Spacer()
                                if let p = opt.price, p > 0 {
                                    Text("+" + Money.rub(p)).font(.caption).foregroundColor(Brand.muted)
                                }
                                if opt.isAvailable != true {
                                    StatusBadge(text: "Стоп", color: Brand.red)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

/// Редактор чипов: известные варианты + свои значения.
struct ChipsEditor: View {
    let all: [String]
    @Binding var selected: [String]
    @State private var custom = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowChips(items: Array(Set(all + selected)).sorted(), selected: selected) { item in
                if let idx = selected.firstIndex(of: item) { selected.remove(at: idx) }
                else { selected.append(item) }
            }
            HStack {
                TextField("Свой вариант", text: $custom)
                Button("Добавить") {
                    let v = custom.trimmingCharacters(in: .whitespaces)
                    guard !v.isEmpty, !selected.contains(v) else { return }
                    selected.append(v)
                    custom = ""
                }
                .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                // Кнопка строки Form без стиля срабатывает от касания по всей строке:
                // тап по чипу или по полю добавлял недописанный «свой вариант».
                .buttonStyle(.borderless)
            }
        }
    }
}

struct FlowChips: View {
    let items: [String]
    let selected: [String]
    let toggle: (String) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 92), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button { toggle(item) } label: {
                    Text(item)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(selected.contains(item) ? Brand.accent : Brand.chip)
                        .foregroundColor(selected.contains(item) ? .white : Brand.text)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
