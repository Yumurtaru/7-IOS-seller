import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import ImageIO

// ============================================================================
//  «Приход по фото накладной» (routes/seller_invoice_ocr.php, волна В3 сайта).
//
//  Поток: снимки / галерея / PDF -> загрузка -> опрос статуса (раз в 2,5 с, пауза
//  при уходе с экрана) -> экран проверки (строки с вопросами подсвечены,
//  сопоставление, правка) -> предпросмотр -> «Провести приход».
//
//  Раздела нет на старом сервере (404/405): пункт в «Документах склада»
//  появляется только после ответа GET /state (InvoiceOcrFeature).
//  Тексты ошибок — сервера; свои тексты только там, где сервер молчит.
//  iOS отдаёт HEIC: каждый снимок перекодируется в JPEG до отправки
//  (сервер HEIC отклоняет кодом heic).
// ============================================================================

// ── Страница накладной в памяти ──────────────────────────────────────────────

struct OcrAttachment: Identifiable {
    let id = UUID()
    let name: String
    let mime: String
    let data: Data
    let isPdf: Bool
}

enum OcrImagePrep {
    /// JPEG для отправки. Сервер всё равно уменьшает до 2000 px, поэтому дальше не нужно.
    static func jpeg(_ image: UIImage) -> Data? {
        ImageCompressor.jpegForUpload(image, maxSide: 2000, quality: 0.75)
    }
}

/// Выбор нескольких фото из галереи за раз (PhotoLibraryPicker берёт одно).
/// Снимки обрабатываются ПО ОДНОМУ и без полной раскодировки в UIImage: файл из галереи
/// уменьшается через ImageIO до 2000 px по длинной стороне и сразу кодируется в JPEG
/// (10 полноразмерных фото с современного телефона разом съедали сотни мегабайт памяти).
struct MultiPhotoLibraryPicker: UIViewControllerRepresentable {
    let limit: Int
    /// Готовые JPEG (до 2000 px) и сколько фото выбрано всего.
    let onPick: ([Data], Int) -> Void
    /// Выбор закрыт, подготовка снимков началась.
    var onBegin: (() -> Void)? = nil
    var onFail: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration()
        cfg.filter = .images
        cfg.selectionLimit = max(1, limit)
        let picker = PHPickerViewController(configuration: cfg)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Миниатюра файла через ImageIO (EXIF-поворот применяется) и JPEG. nil — файл не открылся.
    // nonisolated: вызывается из фоновой очереди; в новых SDK View-структуры изолированы главным потоком.
    nonisolated static func jpegThumbnail(from url: URL, maxPixel: Int = 2000, quality: CGFloat = 0.75) -> Data? {
        let srcOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOptions as CFDictionary) else { return nil }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
    }

    /// Один снимок: файл копируется системой во временный URL, действующий только внутри колбэка —
    /// миниатюру делаем там же. Блокирует вызывающий (фоновый) поток до готовности.
    nonisolated static func loadJpeg(_ provider: NSItemProvider) -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
            if let url { result = jpegThumbnail(from: url) }
            sem.signal()
        }
        sem.wait()
        return result
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MultiPhotoLibraryPicker
        init(_ parent: MultiPhotoLibraryPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let providers = results.map { $0.itemProvider }
            let pick = parent.onPick
            let fail = parent.onFail
            let begin = parent.onBegin
            parent.dismiss()
            guard !providers.isEmpty else { return }   // «Отмена»
            begin?()
            DispatchQueue.global(qos: .userInitiated).async {
                // По одному: в памяти одновременно не больше одного снимка.
                var datas: [Data] = []
                for p in providers {
                    if let d = MultiPhotoLibraryPicker.loadJpeg(p), !d.isEmpty { datas.append(d) }
                }
                DispatchQueue.main.async {
                    if datas.isEmpty {
                        fail?("Не удалось открыть фото. Если оно в iCloud — дождитесь загрузки на телефон и выберите снова.")
                    } else {
                        if datas.count < providers.count {
                            fail?("Часть фото не открылась — добавьте их ещё раз.")
                        }
                        pick(datas, providers.count)
                    }
                }
            }
        }
    }
}

// ── Главный экран: загрузка и история ────────────────────────────────────────

@MainActor
final class OcrHomeViewModel: ObservableObject {
    @Published var attachments: [OcrAttachment] = []
    @Published var history: [OcrJob] = []
    @Published var historyTotal = 0
    @Published var state: LoadState = .idle
    @Published var preparing = false
    @Published var uploading = false
    @Published var loadingMore = false
    @Published var error: String?
    private var page = 1
    private var gen = 0

    private static let defaultMaxBytes = 20 * 1024 * 1024
    private static let defaultMaxFiles = 10

    var limits: OcrState? { InvoiceOcrFeature.shared.state }
    var maxFiles: Int {
        let v = limits?.maxFiles ?? Self.defaultMaxFiles
        return v > 0 ? v : Self.defaultMaxFiles
    }
    var maxBytes: Int {
        let v = limits?.maxBytes ?? Self.defaultMaxBytes
        return v > 0 ? v : Self.defaultMaxBytes
    }
    var totalBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }
    var slotsLeft: Int { max(0, maxFiles - attachments.count) }
    var busy: Bool { preparing || uploading }
    var hasMoreHistory: Bool { history.count < historyTotal }

    func loadHistory() async {
        gen += 1
        let my = gen
        if history.isEmpty { state = .loading }
        do {
            let h = try await API.shared.ocrHistory(page: 1)
            guard my == gen else { return }
            history = h.items
            historyTotal = h.total ?? h.items.count
            page = 1
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard my == gen else { return }
            state = .failed(SellerNewErrors.text(error))
        }
    }

    func loadMore() async {
        guard hasMoreHistory, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let h = try await API.shared.ocrHistory(page: page + 1)
            let known = Set(history.map { $0.id })
            history += h.items.filter { !known.contains($0.id) }
            historyTotal = h.total ?? historyTotal
            page += 1
        } catch is CancellationError {
        } catch {
            self.error = SellerNewErrors.text(error)
        }
    }

    func addImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let room = slotsLeft
        guard room > 0 else {
            error = OcrLogic.tooManyPages(maxFiles)
            return
        }
        let take = Array(images.prefix(room))
        if take.count < images.count {
            error = OcrLogic.partAdded(take.count, of: images.count, max: maxFiles)
        }
        preparing = true
        let startIndex = attachments.count
        Task {
            let datas = await Task.detached(priority: .userInitiated) { () -> [Data?] in
                take.map { OcrImagePrep.jpeg($0) }
            }.value
            preparing = false
            var added = 0
            for d in datas {
                guard let d, !d.isEmpty else { continue }
                attachments.append(OcrAttachment(name: OcrLogic.pageName(startIndex + added), mime: "image/jpeg",
                                                 data: d, isPdf: false))
                added += 1
            }
            if added < take.count { error = "Не удалось подготовить часть снимков — снимите их ещё раз." }
        }
    }

    /// Снимки из галереи уже готовы (JPEG до 2000 px): только кладём на страницы.
    func addPreparedJpegs(_ datas: [Data], picked: Int) {
        preparing = false
        guard !datas.isEmpty else { return }
        let room = slotsLeft
        guard room > 0 else {
            error = OcrLogic.tooManyPages(maxFiles)
            return
        }
        let take = Array(datas.prefix(room))
        if take.count < max(picked, datas.count) {
            error = OcrLogic.partAdded(take.count, of: max(picked, datas.count), max: maxFiles)
        }
        var added = attachments.count
        for d in take {
            attachments.append(OcrAttachment(name: OcrLogic.pageName(added), mime: "image/jpeg", data: d, isPdf: false))
            added += 1
        }
    }

    func beginPreparing() { preparing = true }

    func addPdf(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let e):
            error = e.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            guard url.pathExtension.lowercased() == "pdf" else {
                error = "Выберите файл PDF"
                return
            }
            guard slotsLeft > 0 else {
                error = OcrLogic.tooManyPages(maxFiles)
                return
            }
            let limit = maxBytes
            let name = url.lastPathComponent.isEmpty ? "invoice.pdf" : url.lastPathComponent
            preparing = true
            Task {
                let read = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > limit {
                        return .failure(OcrFileTooLarge())
                    }
                    return Result { try Data(contentsOf: url) }
                }.value
                preparing = false
                switch read {
                case .success(let data):
                    if data.isEmpty { error = "Файл пустой" }
                    else if data.count > limit { error = OcrLogic.fileTooBig(limit) }
                    else { attachments.append(OcrAttachment(name: name, mime: "application/pdf", data: data, isPdf: true)) }
                case .failure(let e):
                    if e is OcrFileTooLarge { error = OcrLogic.fileTooBig(limit) }
                    else { error = "Не удалось прочитать файл: " + e.localizedDescription }
                }
            }
        }
    }

    func remove(_ a: OcrAttachment) {
        attachments.removeAll { $0.id == a.id }
    }

    /// Загрузка. Возвращает номер задания, чтобы открыть экран ожидания.
    func upload() async -> Int? {
        guard !uploading, !preparing, !attachments.isEmpty else { return nil }
        guard attachments.count <= maxFiles else {
            error = OcrLogic.tooManyPages(maxFiles)
            return nil
        }
        guard OcrLogic.fitsLimit(attachments.map { $0.data.count }, maxBytes: maxBytes) else {
            error = OcrLogic.totalTooBig(maxBytes)
            return nil
        }
        uploading = true
        defer { uploading = false }
        let files = attachments.map { OcrUploadFile(filename: $0.name, mime: $0.mime, data: $0.data) }
        do {
            let job = try await API.shared.ocrUpload(files)
            attachments = []
            await loadHistory()
            return job.jobId
        } catch is CancellationError {
            return nil
        } catch {
            var text = SellerNewErrors.text(error)
            // Ответ не дошёл, а задание могло создаться (и это платный вызов).
            if let api = error as? APIError, api.isRetryable || api.isTimeout {
                text += "\nЕсли накладная уже появилась в списке ниже — не отправляйте её второй раз."
            }
            self.error = text
            await loadHistory()
            return nil
        }
    }
}

private struct OcrFileTooLarge: Error {}

private enum OcrPicker: String, Identifiable {
    case camera, library
    var id: String { rawValue }
}

struct InvoiceOcrHomeView: View {
    @StateObject private var vm = OcrHomeViewModel()
    @ObservedObject private var feature = InvoiceOcrFeature.shared
    @State private var picker: OcrPicker?
    @State private var pickingPdf = false
    @State private var openJob: Int?

    var body: some View {
        List {
            uploadSection
            historySection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Приход по фото накладной")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.loadHistory() }
        .task {
            await feature.refresh(shopId: Session.shared.activeShopId)
            await vm.loadHistory()
        }
        .sheet(item: $picker) { p in
            switch p {
            case .camera:
                CameraPicker { img in vm.addImages([img]) }
                    .ignoresSafeArea()
            case .library:
                MultiPhotoLibraryPicker(limit: vm.slotsLeft,
                                        onPick: { datas, picked in vm.addPreparedJpegs(datas, picked: picked) },
                                        onBegin: { vm.beginPreparing() },
                                        onFail: { vm.preparing = false; vm.error = $0 })
            }
        }
        .fileImporter(isPresented: $pickingPdf, allowedContentTypes: [UTType.pdf],
                      allowsMultipleSelection: false) { result in
            vm.addPdf(result)
        }
        .navigationDestination(isPresented: Binding(get: { openJob != nil }, set: { if !$0 { openJob = nil } })) {
            if let id = openJob {
                InvoiceOcrReviewView(jobId: id, onChanged: { Task { await vm.loadHistory() } })
            }
        }
        .errorAlert($vm.error)
    }

    private var uploadSection: some View {
        Section {
            if let s = vm.limits, let limit = s.dailyLimit, limit > 0 {
                Text("Сегодня распознано: \(s.usedToday ?? 0) из \(limit)")
                    .font(.footnote).foregroundColor(Brand.muted)
            }
            Button { picker = .camera } label: {
                Label("Снять накладную", systemImage: "camera")
            }
            .disabled(vm.busy || vm.slotsLeft == 0)
            Button { picker = .library } label: {
                Label("Выбрать фото из галереи", systemImage: "photo.on.rectangle")
            }
            .disabled(vm.busy || vm.slotsLeft == 0)
            Button { pickingPdf = true } label: {
                Label("Выбрать PDF", systemImage: "doc")
            }
            .disabled(vm.busy || vm.slotsLeft == 0)

            if vm.preparing {
                HStack { ProgressView(); Text("Готовим страницы…").font(.footnote).foregroundColor(Brand.muted) }
            }
            ForEach(Array(vm.attachments.enumerated()), id: \.element.id) { index, a in
                HStack(spacing: 10) {
                    if a.isPdf {
                        Image(systemName: "doc.richtext").frame(width: 44, height: 44).foregroundColor(Brand.accent)
                    } else if let ui = UIImage(data: a.data) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(OcrLogic.pageTitle(index, isPdf: a.isPdf)).font(.subheadline).foregroundColor(Brand.text)
                        Text(Self.sizeText(a.data.count)).font(.caption2).foregroundColor(Brand.muted)
                    }
                    Spacer()
                    Button { vm.remove(a) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Brand.muted) }
                        .buttonStyle(.borderless)
                        .disabled(vm.uploading)
                        .accessibilityLabel("Убрать страницу")
                }
            }
            if !vm.attachments.isEmpty {
                Button {
                    Task { if let id = await vm.upload() { openJob = id } }
                } label: {
                    HStack {
                        Text(vm.uploading ? OcrLogic.sending : OcrLogic.sendText(vm.attachments.count)).fontWeight(.semibold)
                        Spacer()
                        if vm.uploading { ProgressView() }
                    }
                }
                .disabled(vm.busy)
            }
        } header: {
            Text("Новая накладная")
        } footer: {
            Text(OcrLogic.limitsHint(maxFiles: vm.maxFiles, maxBytes: vm.maxBytes))
        }
        .listRowBackground(Brand.card)
    }

    private var historySection: some View {
        Section("Распознанные накладные") {
            switch vm.state {
            case .loading where vm.history.isEmpty:
                HStack { Spacer(); ProgressView(); Spacer() }
            case .failed(let msg) where vm.history.isEmpty:
                ErrorBanner(message: msg) { Task { await vm.loadHistory() } }
            default:
                if vm.history.isEmpty {
                    Text("Пока ничего не распознано").font(.footnote).foregroundColor(Brand.muted)
                }
                ForEach(vm.history) { job in
                    Button { openJob = job.id } label: { historyRow(job) }
                        .buttonStyle(.plain)
                }
                if vm.loadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if vm.hasMoreHistory {
                    Button { Task { await vm.loadMore() } } label: {
                        Text("Показать ещё").font(.footnote.weight(.semibold)).foregroundColor(Brand.accent)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .listRowBackground(Brand.card)
    }

    private func historyRow(_ job: OcrJob) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                let title = (job.supplierName ?? "").isEmpty ? "Накладная №\(job.id)" : (job.supplierName ?? "")
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                if let n = ReceiptMath.supplierDocText(no: job.docNo, date: job.docDate) {
                    Text(n).font(.caption).foregroundColor(Brand.muted)
                } else {
                    Text(DateFmt.short(job.createdAt)).font(.caption).foregroundColor(Brand.muted)
                }
                if job.status == "failed", let e = job.error, !e.isEmpty {
                    Text(e).font(.caption2).foregroundColor(Brand.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let t = job.totalGross { Text(Money.rub(t)).font(.subheadline.weight(.bold)).foregroundColor(Brand.text) }
                StatusBadge(text: (job.receiptId ?? 0) > 0 ? "Приход оформлен" : OcrLogic.statusTitle(job),
                            color: Self.statusColor(job))
            }
        }
        .contentShape(Rectangle())
    }

    static func statusColor(_ job: OcrJob) -> Color {
        if (job.receiptId ?? 0) > 0 { return Brand.green }
        switch job.status ?? "" {
        case "done": return Brand.accent
        case "failed": return Brand.red
        case "cancelled": return Brand.muted
        default: return Brand.amber
        }
    }

    static func sizeText(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            let mb = Double(bytes) / 1048576.0
            return String(format: "%.1f", mb).replacingOccurrences(of: ".", with: ",") + " МБ"
        }
        return "\(max(1, bytes / 1024)) КБ"
    }
}

// ── Ожидание и проверка ──────────────────────────────────────────────────────

@MainActor
final class OcrReviewViewModel: ObservableObject {
    let jobId: Int
    @Published var job: OcrJob?
    @Published var state: LoadState = .idle
    @Published var busy = false
    @Published var error: String?
    @Published var offlineNote = false
    @Published var deleted = false
    /// Опрос остановлен через 10 минут: экран пишет «идёт дольше обычного» и даёт «Проверить ещё раз».
    @Published var gaveUp = false
    private var pollTask: Task<Void, Never>?
    private var pollGen = 0
    private var failStreak = 0

    init(jobId: Int) { self.jobId = jobId }

    func start() async {
        await load()
        // Экран закрыт, пока шла загрузка, — опрос заново не запускаем.
        guard !Task.isCancelled else { return }
        startPolling()
    }

    /// «Проверить ещё раз» после остановки опроса.
    func checkAgain() async {
        gaveUp = false
        failStreak = 0
        stopPolling()
        await load()
        guard !Task.isCancelled else { return }
        startPolling()
    }

    func load() async {
        if job == nil { state = .loading }
        do {
            let j = try await API.shared.ocrJob(id: jobId)
            job = j
            state = .loaded
        } catch is CancellationError {
        } catch {
            if job == nil { state = .failed(SellerNewErrors.text(error)) }
            else { self.error = SellerNewErrors.text(error) }
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        if let j = job, OcrLogic.isFinal(j.status) { return }
        pollGen += 1
        let my = pollGen
        gaveUp = false
        let began = Date()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let streak = self.failStreak
                // Раз в 2,5 с; после сбоев сети — реже (до 10 с), чтобы не плодить запросы.
                let delay = OcrLogic.pollNanos * UInt64(min(4, 1 + streak))
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                let finished = await self.pollOnce()
                if finished {
                    if self.pollGen == my { self.pollTask = nil }
                    return
                }
                if Date().timeIntervalSince(began) >= OcrLogic.pollGiveUpSeconds {
                    if self.pollGen == my { self.pollTask = nil; self.gaveUp = true }
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollGen += 1
        pollTask?.cancel()
        pollTask = nil
    }

    /// true — опрос больше не нужен (конечный статус или задания нет).
    private func pollOnce() async -> Bool {
        do {
            let j = try await API.shared.ocrJob(id: jobId, retries: 0)
            failStreak = 0
            offlineNote = false
            job = j
            state = .loaded
            return OcrLogic.isFinal(j.status)
        } catch is CancellationError {
            return false
        } catch {
            if let s = SellerNewErrors.status(error), s == 404 {
                state = .failed(SellerNewErrors.text(error))
                return true
            }
            failStreak += 1
            offlineNote = true
            return false
        }
    }

    /// Выполняет правку; ответ сервера (полный вид накладной) заменяет экран. Текст ошибки или nil.
    func run(_ op: () async throws -> OcrJob) async -> String? {
        guard !busy else { return "Подождите, предыдущее действие ещё выполняется" }
        busy = true
        defer { busy = false }
        do {
            let j = try await op()
            job = j
            state = .loaded
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return SellerNewErrors.text(error)
        }
    }

    func setSkipped(_ line: OcrLine, _ skipped: Bool) async {
        error = await run { try await API.shared.ocrUpdateLine(id: jobId, lineId: line.id, fields: ["skipped": skipped]) }
    }

    /// Подтверждение единицы: те же kind / id / factor, ручное сопоставление снимает пометку.
    func confirmUnit(_ line: OcrLine) async {
        // Как Android Ocr.confirmBody: удалённый товар (missing) и пустые kind / id не подтверждаем.
        guard OcrLogic.canConfirmUnit(line.map), let m = line.map, let kind = m.kind, let itemId = m.itemId else { return }
        let factor = OcrLogic.plain(m.factor ?? 1)
        error = await run { try await API.shared.ocrMap(id: jobId, lineId: line.id, kind: kind, itemId: itemId, factor: factor) }
    }

    func saveHeader(_ fields: [String: Any?]) async -> String? {
        await run { try await API.shared.ocrUpdateHeader(id: jobId, fields: fields) }
    }

    /// Правка строки и (если выбрано) сопоставления. Сопоставление — после правки:
    /// смена названия на сервере запускает автосопоставление.
    func saveLine(_ line: OcrLine, fields: [String: Any?],
                  map: (kind: String, id: Int, factor: String)?) async -> String? {
        if !fields.isEmpty {
            if let e = await run({ try await API.shared.ocrUpdateLine(id: jobId, lineId: line.id, fields: fields) }) { return e }
        }
        if let m = map {
            return await run { try await API.shared.ocrMap(id: jobId, lineId: line.id, kind: m.kind, itemId: m.id, factor: m.factor) }
        }
        return nil
    }

    /// «Сопоставить сами»: сервер сопоставляет несопоставленные строки по памяти ИНН, штрихкодам и артикулам.
    func automap() async {
        let id = jobId
        error = await run { try await API.shared.ocrAutomap(id: id) }
    }

    func retry() async {
        let id = jobId
        let e = await run { try await API.shared.ocrRetry(id: id) }
        error = e
        if e == nil {
            failStreak = 0
            startPolling()
        }
    }

    func delete() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await API.shared.ocrDelete(id: jobId)
            stopPolling()
            deleted = true
        } catch is CancellationError {
        } catch {
            self.error = SellerNewErrors.text(error)
        }
    }
}

private enum OcrReviewSheet: Identifiable {
    case line(Int)
    case header
    case receipt
    var id: String {
        switch self {
        case .line(let n): return "line-\(n)"
        case .header: return "header"
        case .receipt: return "receipt"
        }
    }
}

private enum OcrConfirm: Identifiable {
    case retry, delete
    var id: String { self == .retry ? "retry" : "delete" }
}

struct InvoiceOcrReviewView: View {
    let jobId: Int
    let onChanged: () -> Void
    @StateObject private var vm: OcrReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: OcrReviewSheet?
    @State private var confirm: OcrConfirm?
    @State private var openDocId: Int?

    init(jobId: Int, onChanged: @escaping () -> Void = {}) {
        self.jobId = jobId
        self.onChanged = onChanged
        _vm = StateObject(wrappedValue: OcrReviewViewModel(jobId: jobId))
    }

    var body: some View {
        List {
            if let job = vm.job {
                switch job.status ?? "" {
                case "done": doneContent(job)
                case "failed", "cancelled": failedContent(job)
                default: progressContent(job)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Накладная")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let job = vm.job {
                    Menu {
                        if job.status == "done" && (job.receiptId ?? 0) == 0 {
                            Button { confirm = .retry } label: { Label("Распознать заново", systemImage: "arrow.clockwise") }
                        }
                        Button(role: .destructive) { confirm = .delete } label: {
                            Label(job.status == "processing" ? OcrLogic.cancelRecognition : OcrLogic.deleteButton, systemImage: "trash")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(vm.busy)
                }
            }
        }
        .listState(vm.state, isEmpty: vm.job == nil,
                   emptyIcon: "doc.text.viewfinder", emptyTitle: "Накладная не найдена", emptySubtitle: nil,
                   retry: { Task { await vm.start() } })
        .task { await vm.start() }
        .onDisappear { vm.stopPolling() }
        .onChange(of: vm.job?.status) { _ in onChanged() }
        .onChange(of: vm.deleted) { gone in if gone { onChanged(); dismiss() } }
        .sheet(item: $sheet) { s in sheetContent(s) }
        .navigationDestination(isPresented: Binding(get: { openDocId != nil }, set: { if !$0 { openDocId = nil } })) {
            if let id = openDocId { DocumentDetailView(docId: id) }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            titleVisibility: .visible, presenting: confirm) { c in
            switch c {
            case .retry:
                Button("Распознать заново", role: .destructive) { confirm = nil; Task { await vm.retry() } }
            case .delete:
                Button(vm.job?.status == "processing" ? OcrLogic.cancelYes : "Удалить", role: .destructive) { confirm = nil; Task { await vm.delete() } }
            }
            Button(OcrLogic.keep, role: .cancel) { confirm = nil }
        } message: { c in
            Text(confirmMessage(c))
        }
        .errorAlert($vm.error)
    }

    private var confirmTitle: String {
        guard let c = confirm else { return "" }
        if c == .retry { return "Распознать заново?" }
        return vm.job?.status == "processing" ? OcrLogic.cancelTitle : OcrLogic.deleteTitle
    }

    private func confirmMessage(_ c: OcrConfirm) -> String {
        switch c {
        case .retry:
            return "Ваши правки пропадут, а повторное распознавание считается в лимит."
        case .delete:
            // Сервер «отменяет» только то, что уже распознаётся; из очереди задание удаляется.
            return vm.job?.status == "processing" ? OcrLogic.cancelNote : OcrLogic.deleteNote
        }
    }

    // ── Ожидание ────────────────────────────────────────────────────────────
    @ViewBuilder
    private func progressContent(_ job: OcrJob) -> some View {
        Section {
            HStack(spacing: 12) {
                ProgressView()
                Text("Распознаём накладную…").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
            }
            if let h = job.progress?.hint, !h.isEmpty {
                Text(h).font(.footnote).foregroundColor(Brand.muted)
            }
            if let s = job.progress?.elapsedSec, s > 0 {
                Text("Прошло \(s) с").font(.caption).foregroundColor(Brand.muted)
            }
            if vm.offlineNote {
                Text("Нет связи — проверим позже").font(.caption).foregroundColor(Brand.amber)
            }
            if vm.gaveUp {
                Text(OcrLogic.slowText).font(.footnote).foregroundColor(Brand.text)
                Button(OcrLogic.checkAgain) { Task { await vm.checkAgain() } }
                    .buttonStyle(.borderless)
            }
            Text(OcrLogic.canCloseNote)
                .font(.caption).foregroundColor(Brand.muted)
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private func failedContent(_ job: OcrJob) -> some View {
        Section {
            Text(job.status == "cancelled" ? "Распознавание отменено" : "Не удалось распознать накладную")
                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
            if let e = job.error, !e.isEmpty {
                Text(e).font(.footnote).foregroundColor(Brand.red)
            }
            if let left = job.retriesLeft {
                Text("Повторных распознаваний осталось: \(left)").font(.caption).foregroundColor(Brand.muted)
            }
            Button { Task { await vm.retry() } } label: { Label("Распознать заново", systemImage: "arrow.clockwise") }
                .disabled(vm.busy)
            Button(role: .destructive) { confirm = .delete } label: { Label(OcrLogic.deleteButton, systemImage: "trash") }
                .disabled(vm.busy)
        }
        .listRowBackground(Brand.card)
    }

    // ── Проверка ────────────────────────────────────────────────────────────
    @ViewBuilder
    private func doneContent(_ job: OcrJob) -> some View {
        if let doc = job.document {
            let hasReceipt = (doc.receipt?.receiptId ?? job.receiptId ?? 0) > 0
            let checkN = OcrLogic.checkCount(doc)
            headerSection(doc, hasReceipt: hasReceipt)
            if hasReceipt { receiptDoneSection(doc, job: job) }
            if !doc.checks.isEmpty {
                Section("Замечания") {
                    ForEach(Array(doc.checks.enumerated()), id: \.offset) { _, c in
                        Text(c.text ?? "")
                            .font(.footnote)
                            .foregroundColor(c.level == "warn" ? Brand.amber : Brand.muted)
                    }
                }
                .listRowBackground(Brand.card)
            }
            Section {
                HStack {
                    if checkN > 0 {
                        Label(OcrLogic.needCheckText(checkN), systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundColor(Brand.amber)
                    } else {
                        Label(OcrLogic.allChecked, systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold)).foregroundColor(Brand.green)
                    }
                    Spacer()
                    if !hasReceipt && (doc.unmapped ?? 0) > 0 {
                        Button(OcrLogic.automap) { Task { await vm.automap() } }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                            .disabled(vm.busy)
                    }
                }
                ForEach(doc.lines) { line in lineRow(line, canEdit: !hasReceipt) }
            } header: {
                Text("Позиции (\(doc.lines.count))")
            }
            .listRowBackground(Brand.card)
            if !hasReceipt && (doc.canReceipt ?? true) && !doc.lines.isEmpty {
                Section {
                    Button { sheet = .receipt } label: {
                        Text("Провести приход").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.accent)
                    .disabled(vm.busy)
                } footer: {
                    Text("Перед проведением покажем итог: сумму, пропущенные и несопоставленные строки.")
                }
                .listRowBackground(Color.clear)
            }
        } else {
            Section {
                Text(OcrLogic.noData).font(.footnote)
                Button(OcrLogic.refresh) { Task { await vm.load() } }
            }
            .listRowBackground(Brand.card)
        }
    }

    @ViewBuilder
    private func headerSection(_ doc: OcrDocument, hasReceipt: Bool) -> some View {
        Section {
            InfoRow(label: "Документ", value: (doc.docTypeLabel ?? "").isEmpty ? "Накладная" : (doc.docTypeLabel ?? ""))
            InfoRow(label: "Номер", value: (doc.docNo ?? "").isEmpty ? "—" : (doc.docNo ?? ""))
            InfoRow(label: "Дата", value: (doc.docDate ?? "").isEmpty ? "—" : ReceiptMath.ruDate(doc.docDate))
            if let s = doc.supplier {
                InfoRow(label: "Поставщик", value: (s.name ?? "").isEmpty ? "—" : (s.name ?? ""))
                if let inn = s.inn, !inn.isEmpty {
                    InfoRow(label: "ИНН", value: inn)
                }
                if s.willCreate ?? false {
                    Text("Поставщика нет в вашем списке — при проведении прихода он будет создан.")
                        .font(.caption).foregroundColor(Brand.muted)
                } else if let m = s.match?.name, !m.isEmpty {
                    Text("Найден в поставщиках: \(m)").font(.caption).foregroundColor(Brand.muted)
                }
            }
            if let t = doc.totals {
                if let g = t.gross { InfoRow(label: "Итого с НДС", value: Money.rub(g)) }
                if let n = t.net { InfoRow(label: "Без НДС", value: Money.rub(n)) }
                if let v = t.vat { InfoRow(label: "НДС", value: Money.rub(v)) }
            }
            if let r = doc.reconcile, r.checked ?? false, !(r.ok ?? true), let d = r.diffGross {
                Text("Сумма строк не совпадает с итогом накладной на \(Money.rub(d))")
                    .font(.footnote).foregroundColor(Brand.amber)
            }
            if !hasReceipt {
                Button { sheet = .header } label: { Label("Изменить данные накладной", systemImage: "pencil") }
                    .disabled(vm.busy)
            }
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private func receiptDoneSection(_ doc: OcrDocument, job: OcrJob) -> some View {
        let docId = doc.receipt?.receiptId ?? job.receiptId ?? 0
        Section {
            Label("Приход оформлен" + ((doc.receipt?.number ?? "").isEmpty ? "" : ": " + (doc.receipt?.number ?? "")),
                  systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.green)
            if docId > 0 {
                Button { openDocId = docId } label: { Label("Открыть документ прихода", systemImage: "doc.text") }
            }
        }
        .listRowBackground(Brand.card)
    }

    private func lineRow(_ line: OcrLine, canEdit: Bool) -> some View {
        let skipped = line.skipped ?? false
        let needs = OcrLogic.needsCheck(line)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(OcrLogic.lineTitle(line))
                    .font(.subheadline.weight(.semibold)).foregroundColor(skipped ? Brand.muted : Brand.text)
                Spacer(minLength: 6)
                if skipped { StatusBadge(text: "Пропущена", color: Brand.muted) }
            }
            let amount = (line.amountGross ?? 0) > 0 ? line.amountGross : line.amountNet
            Text("\(QtyFmt.qty(line.qty)) \(line.unit ?? "") × \(Money.rub(line.price)) = \(Money.rub(amount))")
                .font(.caption).foregroundColor(Brand.muted)
            if let m = line.map {
                if m.missing ?? false {
                    Text("Товар удалён — выберите другой").font(.caption).foregroundColor(Brand.red)
                } else {
                    Text("На складе: \(m.name ?? "—") · коэффициент \(QtyFmt.qty(m.factor ?? 1))")
                        .font(.caption).foregroundColor(Brand.text)
                }
                if m.check ?? false {
                    Text("Проверьте единицу: в накладной «\(line.unit ?? "")», на складе «\(m.unit ?? "")»")
                        .font(.caption).foregroundColor(Brand.amber)
                }
            } else if !skipped {
                Text("Не сопоставлена с товаром").font(.caption).foregroundColor(Brand.red)
            }
            if !skipped {
                ForEach(Array(line.flags.enumerated()), id: \.offset) { _, f in
                    Text(f.text ?? "").font(.caption2).foregroundColor(Brand.amber)
                }
            }
            if canEdit {
                HStack(spacing: 14) {
                    Button("Править") { sheet = .line(line.id) }
                    if (line.map?.check ?? false) && !skipped && OcrLogic.canConfirmUnit(line.map) {
                        Button("Подтвердить единицу") { Task { await vm.confirmUnit(line) } }
                            .foregroundColor(Brand.green)
                    }
                    Button(skipped ? "Вернуть" : "Пропустить") { Task { await vm.setSkipped(line, !skipped) } }
                        .foregroundColor(skipped ? Brand.accent : Brand.red)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
                .disabled(vm.busy)
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(needs ? Brand.amber.opacity(0.14) : Brand.card)
    }

    @ViewBuilder
    private func sheetContent(_ s: OcrReviewSheet) -> some View {
        switch s {
        case .line(let lineId):
            if let line = vm.job?.document?.lines.first(where: { $0.id == lineId }) {
                OcrLineEditSheet(line: line, vm: vm)
            } else {
                Text("Строка не найдена").padding()
            }
        case .header:
            if let doc = vm.job?.document { OcrHeaderEditSheet(doc: doc, vm: vm) }
        case .receipt:
            OcrReceiptSheet(jobId: jobId, onOpenDoc: { id in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openDocId = id }
            }, onDone: { Task { await vm.load(); onChanged() } })
        }
    }
}

// ── Правка строки ────────────────────────────────────────────────────────────

private struct OcrLineEditSheet: View {
    let line: OcrLine
    @ObservedObject var vm: OcrReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var unit = ""
    @State private var qty = ""
    @State private var price = ""
    @State private var factor = "1"
    @State private var picked: StockSearchItem?
    @State private var showSearch = false
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Из накладной") {
                    TextField("Название", text: $name)
                    TextField("Единица", text: $unit)
                    TextField("Количество", text: $qty).keyboardType(.decimalPad)
                    TextField("Цена за единицу", text: $price).keyboardType(.decimalPad)
                }
                Section {
                    if let p = picked {
                        Text("Выбрано: \(p.name ?? "—")").font(.subheadline)
                    } else if let m = line.map, !(m.missing ?? false) {
                        Text("Сейчас: \(m.name ?? "—") (\(m.unit ?? ""))").font(.subheadline)
                    } else {
                        Text("Не сопоставлена").font(.subheadline).foregroundColor(Brand.red)
                    }
                    Button { showSearch = true } label: { Label("Выбрать товар на складе", systemImage: "magnifyingglass") }
                    if picked != nil || line.map != nil {
                        TextField("Коэффициент", text: $factor).keyboardType(.decimalPad)
                    }
                } header: {
                    Text("Что это на складе")
                } footer: {
                    Text("Коэффициент: сколько складских единиц в одной единице накладной. Если единицы одинаковые — 1.")
                }
                if let e = error {
                    Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Строка накладной")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Сохранить") }
                    }
                    .disabled(saving)
                }
            }
            .sheet(isPresented: $showSearch) {
                StockSearchSheet(warehouseId: nil) { hit in
                    picked = hit
                    factor = "1"
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear(perform: fill)
        }
    }

    private func fill() {
        name = line.name ?? ""
        unit = line.unit ?? ""
        qty = line.qty.map { OcrLogic.input($0) } ?? ""
        price = line.price.map { OcrLogic.input($0) } ?? ""
        factor = line.map?.factor.map { OcrLogic.plain($0).replacingOccurrences(of: ".", with: ",") } ?? "1"
    }

    private func save() async {
        error = nil
        var fields: [String: Any?] = [:]
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { error = "Укажите название позиции"; return }
        if n != (line.name ?? "") { fields["name"] = n }
        let u = unit.trimmingCharacters(in: .whitespaces)
        if u != (line.unit ?? "") { fields["unit"] = u }
        var numbersChanged = false
        if let q = ReceiptMath.parse(qty, maxFraction: 3) {
            if q != (line.qty ?? 0) { fields["qty"] = OcrLogic.plain(q); numbersChanged = true }
        } else { error = "Количество — неотрицательное число, например 2 или 0,5"; return }
        if let p = ReceiptMath.parse(price, maxFraction: 2) {
            if p != (line.price ?? 0) { fields["price"] = OcrLogic.plain(p); numbersChanged = true }
        } else { error = "Цена — неотрицательное число, например 149,90"; return }
        // Сумма пересчитается по количеству и цене (иначе строка останется со старой суммой).
        if numbersChanged { fields["recalc"] = true }

        var mapArg: (kind: String, id: Int, factor: String)?
        if picked != nil || line.map != nil {
            guard let f = ReceiptMath.parse(factor, maxFraction: 4), f > 0 else {
                error = "Коэффициент — положительное число, например 1 или 0,5"; return
            }
            let factorText = OcrLogic.plain(f)
            if let p = picked, let id = p.itemId {
                mapArg = (kind: p.isIngredient ? "ingredient" : "product", id: id, factor: factorText)
            } else if let m = line.map, let kind = m.kind, let id = m.itemId, !(m.missing ?? false),
                      f != (m.factor ?? 1) {
                mapArg = (kind: kind, id: id, factor: factorText)
            }
        }
        if fields.isEmpty && mapArg == nil { dismiss(); return }
        saving = true
        defer { saving = false }
        if let e = await vm.saveLine(line, fields: fields, map: mapArg) { error = e } else { dismiss() }
    }
}

// ── Правка шапки ─────────────────────────────────────────────────────────────

private struct OcrHeaderEditSheet: View {
    let doc: OcrDocument
    @ObservedObject var vm: OcrReviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var docNo = ""
    @State private var docDate = ""
    @State private var supplierName = ""
    @State private var supplierInn = ""
    @State private var net = ""
    @State private var vat = ""
    @State private var gross = ""
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Накладная") {
                    TextField("Номер", text: $docNo)
                    TextField("Дата (ДД.ММ.ГГГГ)", text: $docDate).keyboardType(.numbersAndPunctuation)
                }
                Section {
                    TextField("Название поставщика", text: $supplierName)
                    TextField("ИНН", text: $supplierInn).keyboardType(.numberPad)
                } header: {
                    Text("Поставщик")
                } footer: {
                    Text("Поставщик для прихода подбирается по ИНН, а если его нет — по названию. Смена ИНН заново сопоставит позиции.")
                }
                Section {
                    TextField("Итого с НДС", text: $gross).keyboardType(.decimalPad)
                    TextField("Без НДС", text: $net).keyboardType(.decimalPad)
                    TextField("НДС", text: $vat).keyboardType(.decimalPad)
                } header: {
                    Text("Итоги накладной")
                } footer: {
                    Text("Пустое поле — итог не задан.")
                }
                if let e = error {
                    Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Данные накладной")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("Сохранить") }
                    }
                    .disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear(perform: fill)
        }
    }

    private func money(_ v: Decimal?) -> String { v.map { ReceiptMath.moneyInput($0) } ?? "" }

    private func fill() {
        docNo = doc.docNo ?? ""
        docDate = (doc.docDate ?? "").isEmpty ? "" : ReceiptMath.ruDate(doc.docDate)
        supplierName = doc.supplier?.name ?? ""
        supplierInn = doc.supplier?.inn ?? ""
        net = money(doc.totals?.net)
        vat = money(doc.totals?.vat)
        gross = money(doc.totals?.gross)
    }

    /// Итог: пусто -> "" (очистить), число -> строка с точкой, мусор -> nil.
    private func total(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "" }
        guard let d = ReceiptMath.parse(t, maxFraction: 2) else { return nil }
        return OcrLogic.plain(d)
    }

    private func save() async {
        error = nil
        var f: [String: Any?] = [:]
        func same(_ a: String, _ b: String?) -> Bool { a.trimmingCharacters(in: .whitespaces) == (b ?? "") }
        if !same(docNo, doc.docNo) { f["doc_no"] = docNo.trimmingCharacters(in: .whitespaces) }
        let oldDate = (doc.docDate ?? "").isEmpty ? "" : ReceiptMath.ruDate(doc.docDate)
        if docDate.trimmingCharacters(in: .whitespaces) != oldDate { f["doc_date"] = docDate.trimmingCharacters(in: .whitespaces) }
        if !same(supplierName, doc.supplier?.name) { f["supplier_name"] = supplierName.trimmingCharacters(in: .whitespaces) }
        if !same(supplierInn, doc.supplier?.inn) { f["supplier_inn"] = supplierInn.trimmingCharacters(in: .whitespaces) }
        for (key, text, old) in [("total_net", net, doc.totals?.net), ("total_vat", vat, doc.totals?.vat),
                                 ("total_gross", gross, doc.totals?.gross)] {
            guard let v = total(text) else { error = "Итог накладной — число, например 1250,50"; return }
            if v != (old.map { OcrLogic.plain($0) } ?? "") && !(v.isEmpty && old == nil) { f[key] = v }
        }
        if f.isEmpty { dismiss(); return }
        saving = true
        defer { saving = false }
        if let e = await vm.saveHeader(f) { error = e } else { dismiss() }
    }
}

// ── Предпросмотр и «Провести приход» ─────────────────────────────────────────

@MainActor
final class OcrReceiptViewModel: ObservableObject {
    let jobId: Int
    @Published var preview: OcrPreview?
    @Published var previewState: LoadState = .idle
    @Published var warehouses: [WarehouseInfo] = []
    @Published var warehouseId = 0
    @Published var priceBasis = "gross"
    @Published var skipUnmapped = false
    @Published var acceptDiff = false
    @Published var sending = false
    @Published var error: String?
    @Published var ack: OcrReceiptAck?
    private var previewGen = 0

    init(jobId: Int) { self.jobId = jobId }

    var canPost: Bool {
        InvoiceOcrFeature.shared.state?.canPost ?? Session.shared.can("documents.post")
    }

    func load() async {
        async let wh: Void = loadWarehouses()
        await loadPreview()
        await wh
    }

    private func loadWarehouses() async {
        if let list = try? await API.shared.warehouses() {
            warehouses = list
            if warehouseId == 0 { warehouseId = list.first(where: { $0.isDefault ?? false })?.warehouseId ?? 0 }
        }
    }

    func loadPreview() async {
        previewGen += 1
        let my = previewGen
        previewState = .loading
        do {
            let p = try await API.shared.ocrPreview(id: jobId, priceBasis: priceBasis)
            guard my == previewGen else { return }
            preview = p
            previewState = .loaded
        } catch is CancellationError {
        } catch {
            guard my == previewGen else { return }
            previewState = .failed(SellerNewErrors.text(error))
        }
    }

    func send() async {
        guard !sending, ack == nil else { return }
        sending = true
        error = nil
        defer { sending = false }
        do {
            ack = try await API.shared.ocrReceipt(id: jobId, warehouseId: warehouseId, post: canPost,
                                                  priceBasis: priceBasis, skipUnmapped: skipUnmapped,
                                                  acceptDiff: acceptDiff)
        } catch is CancellationError {
        } catch {
            var text = OcrLogic.receiptErrorText(error)
            if let api = error as? APIError, api.isRetryable || api.isTimeout {
                text += "\nНажмите «Провести приход» ещё раз: повтор не создаст второй приход."
            }
            self.error = text
            // Разница сумм — подсказываем включить подтверждение.
            if SellerNewErrors.code(error) == "receipt_diff" { await loadPreview() }
        }
    }
}

private struct OcrReceiptSheet: View {
    let jobId: Int
    let onOpenDoc: (Int) -> Void
    let onDone: () -> Void
    @StateObject private var rvm: OcrReceiptViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSend = false

    init(jobId: Int, onOpenDoc: @escaping (Int) -> Void, onDone: @escaping () -> Void) {
        self.jobId = jobId
        self.onOpenDoc = onOpenDoc
        self.onDone = onDone
        _rvm = StateObject(wrappedValue: OcrReceiptViewModel(jobId: jobId))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let ack = rvm.ack { doneView(ack) } else { formView }
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Приход по накладной")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(rvm.ack == nil ? "Отмена" : "Закрыть") { close() }.disabled(rvm.sending)
                }
            }
            .interactiveDismissDisabled(rvm.sending)
            .task { await rvm.load() }
        }
    }

    private func close() {
        let done = rvm.ack != nil
        dismiss()
        if done { onDone() }
    }

    private var formView: some View {
        List {
            Section {
                switch rvm.previewState {
                case .loading where rvm.preview == nil:
                    HStack { ProgressView(); Text("Считаем итог…").font(.footnote).foregroundColor(Brand.muted) }
                case .failed(let msg) where rvm.preview == nil:
                    ErrorBanner(message: msg) { Task { await rvm.loadPreview() } }
                default:
                    if let p = rvm.preview {
                        InfoRow(label: "Сумма по накладной", value: Money.rub(p.updTotal))
                        InfoRow(label: "Сумма прихода", value: Money.rub(p.receiptTotal))
                        InfoRow(label: "Разница", value: Money.rub(p.diff))
                        if !p.skippedLines.isEmpty {
                            InfoRow(label: "Пропущено строк", value: "\(p.skippedLines.count)")
                        }
                        if !p.unmappedLines.isEmpty {
                            InfoRow(label: "Не сопоставлено строк", value: "\(p.unmappedLines.count)")
                        }
                        if !p.unconfirmedLines.isEmpty {
                            InfoRow(label: "Единица не подтверждена", value: "\(p.unconfirmedLines.count)")
                        }
                        ForEach(Array(p.warnings.enumerated()), id: \.offset) { _, w in
                            Text(w).font(.footnote).foregroundColor(Brand.amber)
                        }
                    }
                }
            } header: { Text("Итог") }
            .listRowBackground(Brand.card)

            Section {
                Picker("Цены в накладной", selection: $rvm.priceBasis) {
                    Text("С НДС").tag("gross")
                    Text("Без НДС").tag("net")
                }
                .pickerStyle(.segmented)
                .onChange(of: rvm.priceBasis) { _ in Task { await rvm.loadPreview() } }
                if rvm.warehouses.count > 1 {
                    Picker("Склад", selection: $rvm.warehouseId) {
                        ForEach(rvm.warehouses) { w in Text(w.name ?? "Склад").tag(w.warehouseId) }
                    }
                }
                if let p = rvm.preview, !p.unmappedLines.isEmpty {
                    Toggle("Пропустить несопоставленные строки", isOn: $rvm.skipUnmapped)
                }
                if (rvm.preview?.diffBlocking ?? false) || rvm.acceptDiff {
                    Toggle("Подтвердить разницу сумм", isOn: $rvm.acceptDiff)
                }
            } footer: {
                Text(rvm.canPost ? "Приход будет проведён: остатки на складе изменятся."
                                 : "У вас нет права проводить документы — приход сохранится черновиком.")
            }
            .listRowBackground(Brand.card)

            if let e = rvm.error {
                Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                    .listRowBackground(Brand.card)
            }

            Section {
                Button { confirmSend = true } label: {
                    HStack {
                        Spacer()
                        if rvm.sending { ProgressView() }
                        Text(rvm.canPost ? "Провести приход" : "Сохранить черновиком").font(.headline)
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent).tint(Brand.accent)
                .disabled(rvm.sending || rvm.preview == nil)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog(rvm.canPost ? "Провести приход?" : "Сохранить приход черновиком?",
                            isPresented: $confirmSend, titleVisibility: .visible) {
            Button(rvm.canPost ? "Провести" : "Сохранить") { Task { await rvm.send() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(rvm.canPost ? "Остатки на складе изменятся." : "Остатки не изменятся, пока документ не проведён.")
        }
    }

    private func doneView(_ ack: OcrReceiptAck) -> some View {
        List {
            Section {
                Label(OcrLogic.receiptDoneText(ack), systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundColor(Brand.green)
                if let n = ack.number, !n.isEmpty { InfoRow(label: "Номер", value: n) }
                if let t = ack.total { InfoRow(label: "Сумма", value: Money.rub(t)) }
                if let l = ack.lines { InfoRow(label: "Строк", value: "\(l)") }
                if let pe = ack.postError, !pe.isEmpty {
                    Text(pe).font(.footnote).foregroundColor(Brand.amber)
                }
            }
            .listRowBackground(Brand.card)
            Section {
                if let id = ack.stockDocumentId, id > 0 {
                    Button {
                        let docId = id
                        dismiss()
                        onDone()
                        onOpenDoc(docId)
                    } label: { Label("Открыть документ прихода", systemImage: "doc.text") }
                }
                Button("Готово") { close() }
            }
            .listRowBackground(Brand.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}
