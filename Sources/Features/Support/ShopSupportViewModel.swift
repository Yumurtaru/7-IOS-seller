// ObservableObject и @Published объявлены в Combine: без этого импорта Xcode не соберёт файл
// (Foundation и UIKit их не дают).
import Combine
import Foundation
import UIKit

// ============================================================================
//  «Техподдержка»: переписка организации с поддержкой площадки (волна А66).
//  Одна переписка на организацию — ту, что выбрана сейчас. Новые сообщения —
//  опрос after_id каждые 15 с, ТОЛЬКО пока экран виден и приложение активно.
//  Отправка с ключом повтора (Idempotency-Key): повтор той же отправки после
//  сбоя сети идёт с тем же ключом, и сервер не задваивает сообщение.
// ============================================================================

/// Вложение, выбранное, но ещё не отправленное.
struct ShopSupportDraftAttachment: Identifiable {
    let id = UUID()
    let isPdf: Bool
    let filename: String
    let mime: String
    let data: Data
    /// Миниатюра выбранного фото (у PDF — nil).
    let preview: UIImage?
}

/// PDF больше max_file — отказ до чтения файла в память.
struct ShopSupportFileTooLarge: Error {}

@MainActor
final class ShopSupportViewModel: ObservableObject {
    @Published private(set) var messages: [ShopSupportMessage] = []
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var hasMore = false
    @Published private(set) var loadingOlder = false
    @Published private(set) var olderError: String?
    @Published private(set) var thread: ShopSupportThread?
    @Published private(set) var supportName = "Поддержка Yumurta"
    @Published private(set) var maxBody = 4000
    @Published private(set) var maxFile = 0
    @Published private(set) var maxImage = 0

    @Published var draft = ""
    @Published var attachment: ShopSupportDraftAttachment?
    @Published private(set) var preparingAttachment = false
    @Published private(set) var isSending = false
    @Published var sendError: String?
    /// Ошибка выбора/открытия файла — показывается окном.
    @Published var fileError: String?

    /// Скачанный PDF для просмотра (QuickLook).
    @Published var previewFileURL: URL?
    /// id сообщения, вложение которого сейчас скачивается.
    @Published private(set) var openingMessageId: Int?

    /// Меняется, когда нужно прокрутить вниз (первая загрузка, новые сообщения).
    @Published private(set) var scrollToBottomTick = 0
    /// После подгрузки ранних — держим на месте прежнее первое сообщение.
    @Published private(set) var keepVisibleId: Int?

    /// Организация, чья переписка на экране.
    private var boundShop: Int?
    private var pollTask: Task<Void, Never>?
    private var visible = false
    /// Отправка, которую повторяем тем же ключом, пока текст и вложение те же.
    private var pendingKey: String?
    private var pendingFingerprint: String?
    /// До какого id уже отправили /read.
    private var readSentUpTo = 0
    /// До какого id лента ТОЧНО сверена с сервером (первая загрузка и опросы).
    /// Ответ отправки сюда не входит: иначе ответ поддержки, пришедший между
    /// опросом и отправкой (id меньше моего), опрос after_id пропустил бы,
    /// а /read отметил бы прочитанным, хотя его никто не видел.
    private var syncedUpTo = 0

    /// Чат, открытый сейчас на экране. Push «сообщение поддержки» при открытом
    /// чате не открывает второй такой же экран поверх, а сразу забирает новое.
    static weak var liveOnScreen: ShopSupportViewModel?

    // ── Жизненный цикл ───────────────────────────────────────────────────────

    /// .task экрана: первая загрузка (или повтор после ошибки).
    func start() async {
        _ = ensureShop()
        if state == .loaded { return }
        await loadInitial()
    }

    /// Экран виден и приложение активно — опрашиваем; иначе опрос остановлен.
    func setVisible(_ v: Bool) {
        let wasVisible = visible
        visible = v
        guard v else { stopPolling(); return }
        guard !wasVisible else { return }
        // Вернулись на экран (из фона, после просмотра файла) — сразу забираем
        // новое; при самом первом показе это делает start().
        startPolling(immediate: state == .loaded)
    }

    private func startPolling(immediate: Bool) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var first = immediate
            while !Task.isCancelled {
                if !first {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                }
                first = false
                if Task.isCancelled { return }
                guard let self else { return }
                await self.poll()
            }
        }
    }

    /// Забрать новое сейчас (push пришёл при открытом чате). В фоне не опрашиваем:
    /// при возврате в приложение опрос и так идёт сразу.
    func pollNow() {
        guard visible else { return }
        startPolling(immediate: true)
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Сменили организацию — переписка, черновик и ключ повтора прежней не
    /// должны остаться на экране (и уйти в поддержку от имени новой).
    @discardableResult
    private func ensureShop() -> Int? {
        let current = Session.shared.activeShopId
        if current != boundShop {
            let hadShop = boundShop != nil
            boundShop = current
            if hadShop {
                messages = []
                hasMore = false
                thread = nil
                olderError = nil
                draft = ""
                attachment = nil
                sendError = nil
                pendingKey = nil
                pendingFingerprint = nil
                readSentUpTo = 0
                syncedUpTo = 0
                state = .idle
            }
        }
        return current
    }

    /// Ответ пришёл для той же организации, что сейчас выбрана.
    private func isCurrent(_ shop: Int?) -> Bool {
        shop != nil && shop == Session.shared.activeShopId && shop == boundShop
    }

    /// Смена организации из меню, пока экран открыт.
    func shopChanged() {
        stopPolling()
        ensureShop()
        Task { [weak self] in
            guard let self else { return }
            await self.loadInitial()
            if self.visible { self.startPolling(immediate: false) }
        }
    }

    // ── Загрузка ─────────────────────────────────────────────────────────────

    func loadInitial() async {
        let shop = ensureShop()
        guard shop != nil else { state = .failed("Организация ещё не выбрана — повторите через пару секунд"); return }
        // Опрос пустой переписки (poll зовёт сюда каждые 15 с) — тихо: без крутилки
        // поверх «Напишите нам» и без экрана ошибки при мигнувшей сети.
        let silent = state == .loaded
        if messages.isEmpty && !silent { state = .loading }
        do {
            let page = try await API.shared.supportMessages()
            guard isCurrent(shop) else { return }
            applyMeta(page)
            messages = page.items.filter { $0.id > 0 }
            syncedUpTo = messages.last?.id ?? 0
            hasMore = page.hasMore
            olderError = nil
            state = .loaded
            scrollToBottomTick += 1
            await markReadIfNeeded()
        } catch is CancellationError {
            // Ушли с экрана во время загрузки — при возврате start() повторит.
            if state == .loading { state = .idle }
        } catch {
            guard isCurrent(shop) else { return }
            if !silent { state = .failed(error.localizedDescription) }
        }
    }

    /// Опрос: новые сообщения после последнего известного.
    private func poll() async {
        let shop = ensureShop()
        guard shop != nil, state == .loaded else {
            // Загрузка прервана (ушли с экрана, сменили организацию) — тихо
            // пробуем снова. После ОШИБКИ не перезапускаем сами: ошибка каждые
            // 15 с сменялась крутилкой; повтор — кнопкой «Повторить».
            if state == .idle { await loadInitial() }
            return
        }
        // Переписки ещё нет (ничего не сверено) — берём последние сообщения целиком.
        guard syncedUpTo > 0 else {
            await loadInitial()
            return
        }
        do {
            let page = try await API.shared.supportMessages(afterId: syncedUpTo)
            guard isCurrent(shop) else { return }
            applyMeta(page)
            let added = merge(page.items)
            if let top = page.items.last?.id { syncedUpTo = max(syncedUpTo, top) }
            if added { scrollToBottomTick += 1 }
            await markReadIfNeeded()
        } catch {
            // Опрос молчит: сеть мигнула — следующая попытка через 15 с.
        }
    }

    /// «Показать раньше».
    func loadOlder() async {
        let shop = ensureShop()
        guard hasMore, !loadingOlder, let firstId = messages.first?.id, firstId > 0 else { return }
        loadingOlder = true
        olderError = nil
        defer { loadingOlder = false }
        do {
            let page = try await API.shared.supportMessages(beforeId: firstId)
            guard isCurrent(shop) else { return }
            _ = merge(page.items)
            hasMore = page.hasMore
            if let t = page.thread { applyThread(t) }
            keepVisibleId = firstId
        } catch is CancellationError {
        } catch {
            guard isCurrent(shop) else { return }
            olderError = error.localizedDescription
        }
    }

    private func applyMeta(_ page: ShopSupportPage) {
        if let t = page.thread { applyThread(t) }
        if let n = page.supportName, !n.isEmpty { supportName = n }
        if let b = page.maxBody, b > 0 { maxBody = b }
        if let f = page.maxFile, f > 0 { maxFile = f }
        if let i = page.maxImage, i > 0 { maxImage = i }
    }

    private func applyThread(_ t: ShopSupportThread) {
        thread = t
        ShopSupportUnreadStore.shared.update(unread: t.unread, shopId: boundShop)
    }

    /// Добавить/обновить сообщения по id. true — появились новые.
    @discardableResult
    private func merge(_ items: [ShopSupportMessage]) -> Bool {
        let fresh = items.filter { $0.id > 0 }
        guard !fresh.isEmpty else { return false }
        var byId: [Int: ShopSupportMessage] = [:]
        for m in messages { byId[m.id] = m }
        // Новое — любой id, которого ещё не было (ответ поддержки может
        // оказаться и раньше моего только что отправленного сообщения).
        let added = fresh.contains { byId[$0.id] == nil }
        for m in fresh { byId[m.id] = m }
        messages = byId.values.sorted { $0.id < $1.id }
        return added
    }

    /// Экран виден и есть непрочитанное от поддержки — отмечаем прочитанным
    /// до последнего показанного сообщения.
    private func markReadIfNeeded() async {
        guard visible, (thread?.unread ?? 0) > 0 else { return }
        // Только до сверенного с сервером: дальше могут быть ещё не показанные ответы.
        let upTo = syncedUpTo
        guard upTo > 0, upTo > readSentUpTo else { return }
        let shop = boundShop
        let before = readSentUpTo
        readSentUpTo = upTo
        do {
            let t = try await API.shared.markSupportRead(upToId: upTo)
            guard isCurrent(shop) else { return }
            applyThread(t)
        } catch {
            // Не отметилось — попробуем при следующем опросе.
            if isCurrent(shop) && readSentUpTo == upTo { readSentUpTo = before }
        }
    }

    // ── Отправка ─────────────────────────────────────────────────────────────

    /// Длина так, как её считает сервер (mb_strlen после trim).
    var draftLength: Int {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    var canSend: Bool {
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !isSending && !preparingAttachment && (hasText || attachment != nil) && draftLength <= maxBody
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let att = attachment
        guard !isSending, !preparingAttachment, !text.isEmpty || att != nil else { return }
        guard text.unicodeScalars.count <= maxBody else {
            sendError = "Сообщение длиннее \(maxBody) символов — сократите или разбейте на несколько"
            return
        }
        let shop = ensureShop()
        guard shop != nil else { return }
        // Тот же текст и то же вложение после сбоя — тот же ключ: если первый
        // запрос всё-таки дошёл, сервер вернёт уже созданное сообщение.
        let fingerprint = text + "\u{1F}" + (att?.id.uuidString ?? "")
        let key: String
        if let k = pendingKey, pendingFingerprint == fingerprint {
            key = k
        } else {
            key = UUID().uuidString
            pendingKey = key
            pendingFingerprint = fingerprint
        }
        // Показанное — только то, что сверено с сервером (см. syncedUpTo).
        let seen: Int? = syncedUpTo > 0 ? syncedUpTo : nil
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            let res: ShopSupportSendResult
            if let att {
                res = try await API.shared.sendSupportFile(body: text, seenUpTo: seen,
                                                           filename: att.filename, mime: att.mime,
                                                           data: att.data, idempotencyKey: key)
            } else {
                res = try await API.shared.sendSupportMessage(body: text, seenUpTo: seen, idempotencyKey: key)
            }
            guard isCurrent(shop) else { return }
            pendingKey = nil
            pendingFingerprint = nil
            // Пока уходило, могли допечатать — отправленное убираем из начала
            // поля, допечатанное оставляем.
            let rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if rest.hasPrefix(text) {
                draft = String(rest.dropFirst(text.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let att, attachment?.id == att.id { attachment = nil }
            if let m = res.message { _ = merge([m]) }
            if let t = res.thread { applyThread(t) }
            scrollToBottomTick += 1
            // История не загрузилась (была ошибка) — грузим целиком, иначе
            // после отправки на экране осталось бы одно новое сообщение.
            if state == .loaded { await poll() } else { await loadInitial() }
        } catch is CancellationError {
        } catch let e as IdempotencyError
                    where e.code == "idempotency_unknown_outcome" || e.code == "idempotency_key_reused" {
            guard isCurrent(shop) else { return }
            // С этим ключом сервер так и будет отказывать — «Повторить» пойдёт с
            // новым. Сообщение могло дойти: один раз перечитываем переписку (как
            // Android). in_progress сюда не попадает — там ключ оставляем.
            pendingKey = nil
            pendingFingerprint = nil
            sendError = e.localizedDescription
            await poll()
        } catch {
            guard isCurrent(shop) else { return }
            // Текст и вложение остаются — «Отправить» повторит с тем же ключом.
            sendError = error.localizedDescription
        }
    }

    // ── Вложения ─────────────────────────────────────────────────────────────

    /// Фото из галереи: сжимаем (как фото товаров) вне главного потока.
    func attachPhoto(_ image: UIImage) {
        fileError = nil
        preparingAttachment = true
        let limit = maxImage
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                ImageCompressor.jpegForUpload(image)
            }.value
            guard let self else { return }
            self.preparingAttachment = false
            guard let data, !data.isEmpty else {
                self.fileError = "Не удалось подготовить фото — выберите другое"
                return
            }
            if limit > 0 && data.count > limit {
                self.fileError = "Фото больше " + Self.mbText(limit) + " — выберите другое"
                return
            }
            self.attachment = ShopSupportDraftAttachment(isPdf: false, filename: "photo.jpg", mime: "image/jpeg",
                                                         data: data, preview: UIImage(data: data))
        }
    }

    /// PDF из «Файлов»: читаем под security scope вне главного потока.
    func attachPdf(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            fileError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.pathExtension.lowercased() == "pdf" else {
                fileError = "Можно прикрепить фото или PDF"
                return
            }
            let limit = maxFile
            let name = url.lastPathComponent
            fileError = nil
            preparingAttachment = true
            Task { [weak self] in
                let read = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    // Размер — до чтения: большой PDF (а из iCloud — ещё и со
                    // скачиванием) не читаем в память целиком, чтобы потом отказать.
                    if limit > 0, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limit {
                        return .failure(ShopSupportFileTooLarge())
                    }
                    return Result { try Data(contentsOf: url) }
                }.value
                guard let self else { return }
                self.preparingAttachment = false
                switch read {
                case .success(let data):
                    if data.isEmpty {
                        self.fileError = "Файл пустой"
                    } else if limit > 0 && data.count > limit {
                        self.fileError = "Файл больше " + Self.mbText(limit)
                    } else {
                        self.attachment = ShopSupportDraftAttachment(isPdf: true, filename: name.isEmpty ? "document.pdf" : name,
                                                                     mime: "application/pdf", data: data, preview: nil)
                    }
                case .failure(let error):
                    if error is ShopSupportFileTooLarge {
                        self.fileError = "Файл больше " + Self.mbText(limit)
                    } else {
                        self.fileError = "Не удалось прочитать файл: " + error.localizedDescription
                    }
                }
            }
        }
    }

    func removeAttachment() {
        attachment = nil
    }

    static func mbText(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 10 ? "\(Int(mb.rounded())) МБ" : String(format: "%.1f МБ", mb)
    }

    // ── Просмотр PDF ─────────────────────────────────────────────────────────

    /// Сервер отдаёт PDF «скачиванием» (Content-Disposition: attachment), в
    /// браузере он не открывался бы, — качаем во временную папку и показываем
    /// системным просмотрщиком.
    func openPdf(_ message: ShopSupportMessage) {
        guard openingMessageId == nil, let att = message.attachment, let url = att.fullURL else { return }
        openingMessageId = message.id
        var name = att.displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        let fileName = name
        Task { [weak self] in
            var result: URL?
            var failText: String?
            do {
                let (data, resp) = try await URLSession.shared.data(from: url)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 && !data.isEmpty {
                    // Запись на диск — не на главном потоке (PDF бывает в несколько МБ).
                    let saved = await Task.detached(priority: .userInitiated) { () -> URL? in
                        let dir = FileManager.default.temporaryDirectory
                            .appendingPathComponent("support", isDirectory: true)
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        do {
                            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            let dest = dir.appendingPathComponent(fileName)
                            try data.write(to: dest)
                            return dest
                        } catch {
                            return nil
                        }
                    }.value
                    if let saved {
                        result = saved
                    } else {
                        failText = "Не удалось сохранить файл на телефоне"
                    }
                } else {
                    failText = status == 404 ? "Файл не найден на сервере" : "Не удалось скачать файл (\(status))"
                }
            } catch {
                failText = "Не удалось скачать файл — проверьте интернет"
            }
            guard let self else { return }
            self.openingMessageId = nil
            if let result {
                self.previewFileURL = result
            } else {
                self.fileError = failText ?? "Не удалось открыть файл"
            }
        }
    }
}
