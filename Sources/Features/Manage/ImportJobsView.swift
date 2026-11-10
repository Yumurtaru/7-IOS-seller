import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
//  «Импорт из файла» заданиями (routes/seller_import.php, волна В4А): загрузка, проверка
//  «было → станет», запуск после подтверждения, прогресс с паузой и отменой, итоги и откат,
//  история заданий. Это тот же раздел «Импорт», что и прежний экран: ImportView показывает эту
//  панель, только если сайт отвечает на /api/seller/import/jobs (ImportJobsFeature), иначе
//  работает прежний экран.
//  Логика и тексты — Core/ImportLogic.swift; на Android — ui/importer/ImportJobsScreen.kt.
//
//  Опрос: 2,5 с (реже после сбоев), один запрос за раз, пауза при уходе с экрана, стоп через
//  10 минут + «Проверить ещё раз». Запуск без ключа повтора (сервер запускает атомарно): после
//  обрыва задание сначала перечитывается, запуск вслепую второй раз не уходит.
// ============================================================================

@MainActor
final class ImpViewModel: ObservableObject {
    @Published var target = "products"
    @Published var upload: ImportUpload?
    @Published var mapping: [String: Int] = [:]
    @Published var mode = "both"
    @Published var skipErrors = true
    @Published var blankClears = false
    @Published var hideMissing = false
    @Published var confirmHide = false
    @Published var job: ImpJob?
    @Published var autoOpened = false
    @Published var busy: String?
    @Published var error: String?
    @Published var netWait = false
    @Published var gaveUp = false
    @Published var runUnsure = false
    @Published var permsChanged = false
    @Published var rows: [ImpRow] = []
    @Published var rowsFilter = "changed"
    @Published var rowsPage: Int?
    @Published var rowsPages: Int?
    @Published var rowsLoading = false
    @Published var rowsError: String?
    @Published var history: [ImpJob] = []
    @Published var shareFile: ShareFile?

    private var pollTask: Task<Void, Never>?
    private var pollGen = 0
    private var failStreak = 0
    /// Начало отсчёта 10 минут опроса: не сбрасывается уходом с экрана (как на Android).
    private var pollBegan: Date?
    private var hardStop = false
    /// Номер «принятого» состояния: ответ опроса, пришедший ПОСЛЕ действия (пауза, запуск), старым не затирает новое.
    private var seq = 0
    private var rowsGen = 0
    private var started = false

    var isPolling: Bool { ImpLogic.isPolling(job?.status) }
    var mappingStage: Bool { upload != nil && (job == nil || job?.status == ImpLogic.uploaded) }

    // ── Вход ─────────────────────────────────────────────────────────────

    func start() async {
        if started {
            await loadHistory()
            return
        }
        await loadHistory()
        // Возврат к незавершённому заданию (в том числе после перезапуска приложения).
        // started ставим только после ответа: отменённый Task (быстрый уход с экрана) не должен пропустить проверку.
        guard let r = try? await API.shared.impActive() else { return }
        started = true
        if let j = r.job, j.id > 0, job == nil, upload == nil, busy == nil {
            autoOpened = true
            adopt(j)
        }
    }

    func screenAppeared() {
        if isPolling { startPolling() }
    }

    func loadHistory() async {
        // Ошибку списка не показываем: он справочный, а импорт работает и без него.
        if let r = try? await API.shared.impJobs(page: 1, perPage: 20, retries: 0) { history = r.jobs }
    }

    /// Принять состояние задания с сервера. Переход в «проверка готова» подгружает строки «было → станет».
    private func adopt(_ j: ImpJob) {
        seq += 1
        let prev = job
        let sameJob = prev != nil && prev?.id == j.id
        let becameReady = j.status == ImpLogic.previewReady && (!sameJob || prev?.status != ImpLogic.previewReady)
        let becameFinal = ImpLogic.isFinal(j.status) && (!sameJob || prev?.status != j.status)
        job = j
        netWait = false
        if ImpLogic.isPolling(j.status) { startPolling() } else { stopPolling() }
        if becameReady {
            Task { [weak self] in await self?.loadRows(reset: true) }
        }
        if becameFinal {
            Task { [weak self] in await self?.loadHistory() }
        }
    }

    // ── Настройки ────────────────────────────────────────────────────────

    func setMode(_ m: String) {
        mode = m
        if hideMissing && !ImpLogic.hideAllowed(target: upload?.target ?? target, mode: m) { hideMissing = false }
    }

    func setColumn(_ field: String, _ index: Int) {
        if index < 0 { mapping.removeValue(forKey: field) } else { mapping[field] = index }
    }

    // ── Файл ─────────────────────────────────────────────────────────────

    func loadFile(url: URL, name: String) async {
        guard busy == nil else { return }
        busy = "upload"
        error = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let res = try await API.shared.impUpload(target: target, filename: name,
                                                     mime: ImpLogic.mime(for: name), source: url)
            upload = res
            mapping = res.suggested ?? [:]
            job = nil
            autoOpened = false
            rows = []
            rowsPage = nil
            permsChanged = false
            runUnsure = false
            confirmHide = false
            hideMissing = false
            blankClears = false
            if mode == "prices_stock" && (res.target ?? target) != "products" { mode = "both" }
            busy = nil
        } catch is CancellationError {
            busy = nil
        } catch {
            busy = nil
            self.error = ImpLogic.errorText(error)
        }
    }

    /// XLSX с несколькими листами: другой лист — файл читается заново, сопоставление берём подсказкой сервера.
    func selectSheet(_ name: String) async {
        guard busy == nil, let u = upload, let id = u.jobId, u.sheet != name, !name.isEmpty else { return }
        busy = "sheet"
        error = nil
        defer { busy = nil }
        do {
            let res = try await API.shared.impSheet(id: id, name: name)
            upload = res
            mapping = res.suggested ?? [:]
        } catch is CancellationError {
        } catch {
            self.error = ImpLogic.errorText(error)
        }
    }

    // ── Проверка ─────────────────────────────────────────────────────────

    /// «Проверить файл»: пробный прогон с выбранными колонками и режимом.
    func runCheck() async {
        guard busy == nil, let u = upload, let id = u.jobId else { return }
        let t = u.target ?? target
        let body = ImpLogic.previewBody(mapping: mapping, mode: mode, skipErrors: skipErrors,
                                        blankClears: blankClears,
                                        hideMissing: hideMissing && ImpLogic.hideAllowed(target: t, mode: mode))
        await sendPreview(id: id, body: body)
    }

    /// «Проверить заново» с теми же настройками задания (права изменились, настройки устарели).
    func recheck() async {
        guard busy == nil, let j = job else { return }
        await sendPreview(id: j.id, body: ImpLogic.previewBodyFromJob(j))
    }

    private func sendPreview(id: Int, body: [String: Any?]) async {
        stopPolling()
        pollBegan = nil
        failStreak = 0
        busy = "preview"
        error = nil
        gaveUp = false
        permsChanged = false
        runUnsure = false
        confirmHide = false
        defer { busy = nil }
        do {
            let j = try await API.shared.impPreview(id: id, body: body)
            rows = []
            rowsPage = nil
            adopt(j)
        } catch is CancellationError {
        } catch {
            if ImpLogic.isUnknownOutcome(error) {
                await reread(id: id, fallback: ImpLogic.errorText(error), unsure: nil)
            } else {
                self.error = ImpLogic.errorText(error)
            }
        }
    }

    /// Исход запроса неизвестен: читаем задание и показываем то, что на сервере (запрос вслепую не повторяем).
    private func reread(id: Int, fallback: String, unsure: String?) async {
        do {
            let j = try await API.shared.impJob(id: id)
            error = unsure
            adopt(j)
        } catch is CancellationError {
        } catch {
            self.error = fallback
        }
    }

    // ── Опрос ────────────────────────────────────────────────────────────

    func startPolling() {
        guard pollTask == nil, isPolling, !gaveUp else { return }
        pollGen += 1
        let my = pollGen
        let began = pollBegan ?? Date()
        pollBegan = began
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: ImpLogic.pollNanos(failures: self.failStreak))
                if Task.isCancelled { return }
                await self.pollOnce()
                if Task.isCancelled { return }
                if self.hardStop {
                    self.hardStop = false
                    if self.pollGen == my { self.pollTask = nil }
                    return
                }
                if !self.isPolling {
                    if self.pollGen == my { self.pollTask = nil }
                    return
                }
                if Date().timeIntervalSince(began) >= ImpLogic.pollGiveUpSeconds {
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

    private func pollOnce() async {
        guard let id = job?.id else { return }
        let mySeq = seq
        do {
            let j = try await API.shared.impJob(id: id)
            failStreak = 0
            netWait = false
            if mySeq == seq && job?.id == id { adopt(j) }
        } catch is CancellationError {
        } catch {
            if ImpLogic.isTransient(error) {
                failStreak += 1
                netWait = true
            } else {
                // 404 и прочие ясные отказы: задание не найдено или нет права — ждать нечего.
                self.error = ImpLogic.errorText(error)
                netWait = false
                hardStop = true
            }
        }
    }

    /// «Проверить ещё раз» после остановки опроса: один запрос сейчас, дальше опрос идёт как обычно.
    func checkAgain() async {
        gaveUp = false
        failStreak = 0
        pollBegan = nil
        error = nil
        stopPolling()
        await pollOnce()
        if isPolling { startPolling() }
    }

    // ── Запуск и действия ────────────────────────────────────────────────

    func run() async {
        guard let id = job?.id, busy == nil else { return }
        busy = "run"
        error = nil
        defer { busy = nil }
        if runUnsure {
            // Прошлый запуск оборвался: сначала узнаём, что на сервере. Запуск вслепую второй раз не шлём.
            do {
                let j = try await API.shared.impJob(id: id)
                adopt(j)
                runUnsure = false
                if j.status != ImpLogic.previewReady { return }
            } catch is CancellationError {
                return
            } catch {
                self.error = ImpLogic.runUnsureFail
                return
            }
        }
        do {
            let j = try await API.shared.impRun(id: id, confirmHide: confirmHide)
            runUnsure = false
            pollBegan = nil
            gaveUp = false
            adopt(j)
        } catch is CancellationError {
        } catch {
            if SellerNewErrors.status(error) == 409 {
                // Любой 409: задание могло уже идти или измениться — показываем текст сервера и перечитываем его.
                if ImpLogic.isPermsChanged(error) { permsChanged = true }
                let text = ImpLogic.errorText(error)
                await reread(id: id, fallback: text, unsure: text)
                if job?.status != ImpLogic.previewReady { runUnsure = false }
            } else if ImpLogic.isUnknownOutcome(error) {
                runUnsure = true
                await reread(id: id, fallback: ImpLogic.runUnsureFail, unsure: ImpLogic.runUnsure)
                // Задание уже идёт — запуск прошёл, предупреждение не нужно.
                if job?.status != ImpLogic.previewReady { runUnsure = false; self.error = nil }
            } else {
                self.error = ImpLogic.errorText(error)
            }
        }
    }

    /// Пауза, продолжение, отмена, откат. kind: pause | resume | cancel | rollback.
    func act(_ kind: String) async {
        guard let id = job?.id, busy == nil else { return }
        busy = "action"
        error = nil
        defer { busy = nil }
        do {
            let j: ImpJob
            switch kind {
            case "pause": j = try await API.shared.impPause(id: id)
            case "resume": j = try await API.shared.impResume(id: id)
            case "cancel": j = try await API.shared.impCancel(id: id)
            default: j = try await API.shared.impRollback(id: id)
            }
            gaveUp = false
            pollBegan = nil
            adopt(j)
        } catch is CancellationError {
        } catch {
            if SellerNewErrors.status(error) == 409 {
                if ImpLogic.isPermsChanged(error) { permsChanged = true }
                let text = ImpLogic.errorText(error)
                await reread(id: id, fallback: text, unsure: text)
            } else if ImpLogic.isUnknownOutcome(error) {
                await reread(id: id, fallback: ImpLogic.errorText(error), unsure: nil)
            } else {
                self.error = ImpLogic.errorText(error)
            }
        }
    }

    // ── Строки «было → станет» ───────────────────────────────────────────

    func setRowsFilter(_ f: String) {
        guard rowsFilter != f else { return }
        rowsFilter = f
        Task { [weak self] in await self?.loadRows(reset: true) }
    }

    func loadRows(reset: Bool) async {
        guard let id = job?.id else { return }
        let page = reset ? 1 : (rowsPage ?? 0) + 1
        if !reset && (rowsLoading || !ImpLogic.hasMore(page: rowsPage, pages: rowsPages)) { return }
        rowsGen += 1
        let gen = rowsGen
        let filter = rowsFilter
        rowsLoading = true
        rowsError = nil
        if reset { rows = [] }
        do {
            let r = try await API.shared.impRows(id: id, filter: filter, page: page)
            guard gen == rowsGen else { return }
            rows = (reset ? [] : rows) + r.rows
            rowsPage = r.page ?? page
            rowsPages = r.pages ?? 1
            rowsLoading = false
        } catch is CancellationError {
            if gen == rowsGen { rowsLoading = false }
        } catch {
            guard gen == rowsGen else { return }
            rowsLoading = false
            rowsError = ImpLogic.errorText(error)
        }
    }

    // ── Файл ошибок ──────────────────────────────────────────────────────

    func downloadErrors() async {
        guard let j = job, busy == nil else { return }
        busy = "download"
        error = nil
        defer { busy = nil }
        do {
            let url = try await API.shared.impErrorsFile(job: j)
            shareFile = ShareFile(url: url)
        } catch is CancellationError {
        } catch {
            self.error = ImpLogic.errorText(error)
        }
    }

    // ── Навигация ────────────────────────────────────────────────────────

    /// Открыть задание из истории: показываем сразу, потом перечитываем свежее состояние.
    func open(_ j: ImpJob) async {
        guard busy == nil else { return }
        pollBegan = nil
        failStreak = 0
        upload = nil
        error = nil
        gaveUp = false
        permsChanged = false
        runUnsure = false
        confirmHide = false
        autoOpened = false
        rowsFilter = "changed"
        rows = []
        rowsPage = nil
        adopt(j)
        if let fresh = try? await API.shared.impJob(id: j.id), job?.id == j.id { adopt(fresh) }
    }

    /// К сопоставлению колонок (файл ещё на экране): задание остаётся на сервере, проверку можно запустить заново.
    func backToMapping() {
        guard busy == nil, upload != nil else { return }
        seq += 1
        stopPolling()
        job = nil
        rows = []
        rowsPage = nil
        permsChanged = false
        runUnsure = false
        confirmHide = false
        error = nil
    }

    /// К выбору файла. Идущее задание не бросаем: кнопка доступна, только когда сервер ничего не делает.
    func newImport() {
        guard busy == nil, !isPolling else { return }
        seq += 1
        stopPolling()
        upload = nil
        mapping = [:]
        job = nil
        autoOpened = false
        rows = []
        rowsPage = nil
        permsChanged = false
        runUnsure = false
        confirmHide = false
        hideMissing = false
        blankClears = false
        skipErrors = true
        mode = "both"
        error = nil
        Task { [weak self] in await self?.loadHistory() }
    }
}

/// Что спрашиваем у человека подтверждением (один confirmationDialog на экран).
private enum ImpAsk: Identifiable {
    case run, cancel, rollback
    var id: Int {
        switch self {
        case .run: return 0
        case .cancel: return 1
        case .rollback: return 2
        }
    }
}

struct ImportJobsView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = ImpViewModel()
    @State private var picking = false
    @State private var ask: ImpAsk?

    /// Запуск, продолжение и откат — действие products.create на сервере.
    private var canCreate: Bool { session.can("products.create") }

    var body: some View {
        Form {
            if let e = vm.error {
                Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                    .listRowBackground(Color.clear)
            }
            if vm.mappingStage {
                mappingSections
            } else if let j = vm.job, j.status != ImpLogic.uploaded {
                jobSections(j)
            } else {
                pickSections
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .task { await vm.start() }
        .onAppear { vm.screenAppeared() }
        .onDisappear { vm.stopPolling() }
        .fileImporter(isPresented: $picking, allowedContentTypes: allowedTypes,
                      allowsMultipleSelection: false) { result in
            handlePick(result)
        }
        .sheet(item: $vm.shareFile) { file in
            ShareSheet(items: [file.url])
        }
        .confirmationDialog(askTitle, isPresented: askBinding, titleVisibility: .visible) {
            switch ask {
            case .run:
                Button(ImpLogic.runYes) { Task { await vm.run() } }
                Button(ImpLogic.keep, role: .cancel) {}
            case .cancel:
                Button(ImpLogic.cancelYes, role: .destructive) { Task { await vm.act("cancel") } }
                Button(ImpLogic.keep, role: .cancel) {}
            case .rollback:
                Button(ImpLogic.rollbackYes, role: .destructive) { Task { await vm.act("rollback") } }
                Button(ImpLogic.keep, role: .cancel) {}
            case nil:
                EmptyView()
            }
        } message: {
            Text(askMessage)
        }
    }

    private var askBinding: Binding<Bool> {
        Binding(get: { ask != nil }, set: { if !$0 { ask = nil } })
    }

    private var askTitle: String {
        switch ask {
        case .run: return ImpLogic.confirmTitle(ImpLogic.plan(vm.job)?.changes ?? 0)
        case .cancel: return ImpLogic.cancelTitle
        case .rollback: return ImpLogic.rollbackTitle
        case nil: return ""
        }
    }

    private var askMessage: String {
        switch ask {
        case .run:
            var text = ImpLogic.runNote
            if let p = ImpLogic.plan(vm.job), p.hide > 0 {
                text += "\n\n" + ImpLogic.hideText(hide: p.hide, catalog: p.catalog, pct: p.hidePct)
            }
            if ImpLogic.blankClears(vm.job) { text += "\n\n" + ImpLogic.blankWarning }
            return text
        case .cancel: return ImpLogic.cancelNote
        case .rollback: return ImpLogic.rollbackNote
        case nil: return ""
        }
    }

    /// CSV и XLSX — ровно то, что принимает сервер.
    private var allowedTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        return types
    }

    // ── Шаг 1: выбор файла и история ─────────────────────────────────────

    @ViewBuilder
    private var pickSections: some View {
        Section {
            Picker(ImpLogic.pickWhat, selection: $vm.target) {
                Text("Товары").tag("products")
                if session.shopType == "cafe" {
                    Text("Ингредиенты").tag("ingredients")
                }
            }
            Button {
                picking = true
            } label: {
                HStack {
                    Label(vm.busy == "upload" ? ImpLogic.uploading : ImpLogic.pickFile, systemImage: "doc.badge.plus")
                    Spacer()
                    if vm.busy == "upload" { ProgressView() }
                }
            }
            .disabled(vm.busy != nil)
            .foregroundColor(Brand.text)
            NavigationLink { ExportsView() } label: {
                Label("Скачать шаблон", systemImage: "square.and.arrow.down")
            }
        } footer: {
            Text(ImpLogic.pickHint)
        }
        .listRowBackground(Brand.card)

        if !vm.history.isEmpty {
            Section(ImpLogic.history) {
                ForEach(Array(vm.history.enumerated()), id: \.offset) { _, j in
                    HStack {
                        Text(ImpLogic.jobLine(j)).font(.subheadline)
                        Spacer()
                        Button(ImpLogic.historyOpen) { Task { await vm.open(j) } }
                            .buttonStyle(.borderless)
                            .disabled(vm.busy != nil)
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Шаг 2: сопоставление колонок ─────────────────────────────────────

    @ViewBuilder
    private var mappingSections: some View {
        if let u = vm.upload {
            let target = u.target ?? vm.target
            let sheets = (u.sheets ?? []).filter { $0.visible != false && !($0.name ?? "").isEmpty }
            Section {
                if sheets.count > 1 {
                    Picker(ImpLogic.sheet, selection: Binding(
                        get: { u.sheet ?? "" },
                        set: { n in Task { await vm.selectSheet(n) } }
                    )) {
                        ForEach(Array(sheets.enumerated()), id: \.offset) { _, s in
                            Text(s.name ?? "").tag(s.name ?? "")
                        }
                    }
                    .disabled(vm.busy != nil)
                }
                ForEach(u.orderedFieldKeys, id: \.self) { key in
                    Picker(selection: Binding(
                        get: { vm.mapping[key] ?? -1 },
                        set: { vm.setColumn(key, $0) }
                    )) {
                        Text(ImpLogic.notFill).tag(-1)
                        ForEach(Array((u.headers ?? []).enumerated()), id: \.offset) { idx, head in
                            Text(head.isEmpty ? "\(ImpLogic.columnN) \(idx + 1)" : head).tag(idx)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(u.fields?[key]?.label ?? key)
                            if u.fields?[key]?.required == true {
                                Text("*").foregroundColor(Brand.red)
                            }
                        }
                    }
                    .disabled(vm.busy != nil)
                }
            } header: {
                Text("\(ImpLogic.columns) · строк: \(u.total ?? 0)")
            }
            .listRowBackground(Brand.card)

            Section {
                Picker(ImpLogic.mode, selection: Binding(get: { vm.mode }, set: { vm.setMode($0) })) {
                    ForEach(Array(ImpLogic.modes(target: target).enumerated()), id: \.offset) { _, m in
                        Text(m.1).tag(m.0)
                    }
                }
                Toggle(ImpLogic.skipErrors, isOn: $vm.skipErrors)
                Toggle(ImpLogic.blankClears, isOn: $vm.blankClears)
                if vm.blankClears {
                    Text(ImpLogic.blankWarning).font(.footnote).foregroundColor(Brand.red)
                }
                if ImpLogic.hideAllowed(target: target, mode: vm.mode) {
                    Toggle(ImpLogic.hideMissing, isOn: $vm.hideMissing)
                }
            }
            .disabled(vm.busy != nil)
            .listRowBackground(Brand.card)

            Section {
                Button {
                    Task { await vm.runCheck() }
                } label: {
                    HStack {
                        Label(vm.busy == "preview" ? ImpLogic.checking : ImpLogic.check, systemImage: "eye")
                        Spacer()
                        if vm.busy == "preview" { ProgressView() }
                    }
                }
                .disabled(vm.busy != nil || vm.mapping.isEmpty)
                .foregroundColor(Brand.text)
                Button(role: .destructive) { vm.newImport() } label: {
                    Label(ImpLogic.anotherFile, systemImage: "arrow.counterclockwise")
                }
                .disabled(vm.busy != nil)
            }
            .listRowBackground(Brand.card)
        }
    }

    // ── Задание: проверка, ход, итоги ────────────────────────────────────

    @ViewBuilder
    private func jobSections(_ j: ImpJob) -> some View {
        let polling = vm.isPolling
        let plan = ImpLogic.plan(j)
        let busy = vm.busy != nil

        Section {
            if vm.autoOpened {
                Text(ImpLogic.activeFound).font(.caption).foregroundColor(Brand.muted)
            }
            Text(polling ? ImpLogic.progressText(j) : ImpLogic.title(j)).font(.headline)
            Text(ImpLogic.jobLine(j)).font(.caption).foregroundColor(Brand.muted)
            if polling {
                if let p = ImpLogic.progress(j), p > 0 {
                    ProgressView(value: Double(p), total: 100)
                } else {
                    ProgressView()
                }
                if let rows = ImpLogic.rowsText(j) { Text(rows).font(.footnote) }
                if j.stalled == true { Text(ImpLogic.stalled).font(.footnote) }
                if vm.netWait {
                    Text(ImpLogic.networkWait).font(.footnote).foregroundColor(Brand.muted)
                }
            }
            if vm.gaveUp && polling {
                Text(ImpLogic.slow).font(.footnote)
                Button(ImpLogic.checkAgain) { Task { await vm.checkAgain() } }
            }
            if j.status == ImpLogic.paused, let rows = ImpLogic.rowsText(j) {
                Text(rows).font(.footnote)
            }
            if j.status == ImpLogic.failed, let e = j.errorText, !e.isEmpty {
                Text(e).font(.footnote).foregroundColor(Brand.red)
            }
            if ImpLogic.canPause(j) {
                Button(ImpLogic.pause) { Task { await vm.act("pause") } }.disabled(busy)
            }
            if ImpLogic.canResume(j, hasRight: canCreate) {
                Button(ImpLogic.resume) { Task { await vm.act("resume") } }.disabled(busy)
            }
            if ImpLogic.canCancel(j) && j.status != ImpLogic.previewReady && !ImpLogic.isRollbackPhase(j) {
                Button(ImpLogic.cancel, role: .destructive) { ask = .cancel }.disabled(busy)
            }
        }
        .listRowBackground(Brand.card)

        if j.status == ImpLogic.previewReady {
            previewSections(j, plan: plan, busy: busy)
        }

        resultSections(j, polling: polling, busy: busy)
    }

    // Проверка готова: «было → станет», запуск.
    @ViewBuilder
    private func previewSections(_ j: ImpJob, plan: ImpLogic.Plan?, busy: Bool) -> some View {
        if let p = plan {
            Section {
                HStack(spacing: 14) {
                    counter("Создастся", p.add, Brand.green)
                    counter("Изменится", p.update, Brand.accent)
                    counter("Пропущено", p.skip, Brand.muted)
                    counter("Ошибки", p.error, Brand.red)
                }
                .frame(maxWidth: .infinity)
                if p.unchanged > 0 { Text("Без изменений: \(p.unchanged)").font(.footnote) }
                if p.warn > 0 { Text("Предупреждений: \(p.warn)").font(.footnote) }
                if p.hide > 0 {
                    Text(ImpLogic.hideText(hide: p.hide, catalog: p.catalog, pct: p.hidePct))
                        .font(.footnote).foregroundColor(Brand.red)
                }
            } header: {
                Text(ImpLogic.summary)
            } footer: {
                Text(ImpLogic.summaryNote)
            }
            .listRowBackground(Brand.card)
        }

        if ImpLogic.blankClears(j) {
            Section { Text(ImpLogic.blankWarning).font(.footnote).foregroundColor(Brand.red) }
                .listRowBackground(Brand.card)
        }

        if j.hasErrorsFile == true || (plan?.error ?? 0) > 0 {
            Section { errorsFileButton(busy: busy) }.listRowBackground(Brand.card)
        }

        Section {
            Picker(ImpLogic.rowsTitle, selection: Binding(get: { vm.rowsFilter }, set: { vm.setRowsFilter($0) })) {
                ForEach(Array(ImpLogic.filters.enumerated()), id: \.offset) { _, f in
                    Text(f.1).tag(f.0)
                }
            }
            .pickerStyle(.segmented)
            ForEach(Array(vm.rows.enumerated()), id: \.offset) { _, r in
                rowView(r)
            }
            if vm.rowsLoading {
                Text(ImpLogic.rowsLoading).font(.footnote).foregroundColor(Brand.muted)
            }
            if let e = vm.rowsError {
                Text(e).font(.footnote).foregroundColor(Brand.red)
                Button("Повторить") { Task { await vm.loadRows(reset: vm.rows.isEmpty) } }
            }
            if !vm.rowsLoading && vm.rowsError == nil && vm.rows.isEmpty {
                Text(ImpLogic.rowsEmpty).font(.footnote).foregroundColor(Brand.muted)
            }
            if ImpLogic.hasMore(page: vm.rowsPage, pages: vm.rowsPages) && !vm.rowsLoading {
                Button(ImpLogic.rowsMore) { Task { await vm.loadRows(reset: false) } }
            }
        } header: {
            Text(ImpLogic.rowsTitle)
        }
        .listRowBackground(Brand.card)

        // Запуск — только после проверки и подтверждения.
        Section {
            if let p = plan, p.hideNeedsConfirm {
                Toggle(isOn: $vm.confirmHide) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ImpLogic.hideText(hide: p.hide, catalog: p.catalog, pct: p.hidePct))
                        Text(ImpLogic.confirmHide).font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .disabled(busy)
            }
            if vm.permsChanged {
                Text(ImpLogic.permsChangedHint).font(.footnote).foregroundColor(Brand.red)
            }
            if !canCreate {
                Text(ImpLogic.noRightRun).font(.footnote).foregroundColor(Brand.muted)
            }
            if let p = plan, p.changes == 0 {
                Text(ImpLogic.nothingToChange).font(.footnote)
            }
            if let p = plan, ImpLogic.canRun(j, hasRight: canCreate), p.changes > 0, !vm.permsChanged {
                Button {
                    ask = .run
                } label: {
                    HStack {
                        Label(vm.busy == "run" ? ImpLogic.runStarting : ImpLogic.run, systemImage: "square.and.arrow.down.on.square")
                        Spacer()
                        if vm.busy == "run" { ProgressView() }
                    }
                }
                .disabled(busy || (p.hideNeedsConfirm && !vm.confirmHide))
                .foregroundColor(Brand.accent)
            }
            Button {
                Task { await vm.recheck() }
            } label: {
                HStack {
                    Label(vm.busy == "preview" ? ImpLogic.checking : ImpLogic.checkRestart, systemImage: "arrow.clockwise")
                    Spacer()
                    if vm.busy == "preview" { ProgressView() }
                }
            }
            .disabled(busy)
            .foregroundColor(Brand.text)
            if vm.upload != nil {
                Button(ImpLogic.columns) { vm.backToMapping() }.disabled(busy)
            } else {
                Button(ImpLogic.anotherFile) { vm.newImport() }.disabled(busy)
            }
        }
        .listRowBackground(Brand.card)
    }

    // Итоги выполнения и отката.
    @ViewBuilder
    private func resultSections(_ j: ImpJob, polling: Bool, busy: Bool) -> some View {
        let showResult = j.status == ImpLogic.done || j.status == ImpLogic.cancelled || j.status == ImpLogic.failed
            || j.status == ImpLogic.paused || j.status == ImpLogic.rolledBack
        if showResult, let c = ImpLogic.counts(j) {
            Section(ImpLogic.result) {
                ForEach(Array(ImpLogic.resultLines(c).enumerated()), id: \.offset) { _, line in
                    HStack {
                        Text(line.0)
                        Spacer()
                        Text("\(line.1)").fontWeight(.medium)
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
        if showResult, let r = ImpLogic.rollbackInfo(j) {
            let lines = ImpLogic.rollbackLines(r)
            if !lines.isEmpty {
                Section(ImpLogic.rollbackResult) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        HStack {
                            Text(line.0)
                            Spacer()
                            Text("\(line.1)").fontWeight(.medium)
                        }
                    }
                }
                .listRowBackground(Brand.card)
            }
        }
        if j.status != ImpLogic.previewReady && j.status != ImpLogic.previewing && j.hasErrorsFile == true && !polling {
            Section { errorsFileButton(busy: busy) }.listRowBackground(Brand.card)
        }
        if vm.permsChanged && j.status != ImpLogic.previewReady {
            Section { Text(ImpLogic.permsChangedHint).font(.footnote).foregroundColor(Brand.red) }
                .listRowBackground(Brand.card)
        }
        if ImpLogic.canRollback(j, hasRight: canCreate) {
            Section {
                Button(ImpLogic.rollback, role: .destructive) { ask = .rollback }.disabled(busy)
            }
            .listRowBackground(Brand.card)
        }
        if !polling && j.status != ImpLogic.previewReady {
            Section {
                Button {
                    vm.newImport()
                } label: {
                    Label(ImpLogic.newImport, systemImage: "arrow.counterclockwise")
                }
                .disabled(busy)
                .foregroundColor(Brand.text)
            }
            .listRowBackground(Brand.card)
        }
    }

    private func errorsFileButton(busy: Bool) -> some View {
        Button {
            Task { await vm.downloadErrors() }
        } label: {
            HStack {
                Label(vm.busy == "download" ? ImpLogic.errorsFileLoading : ImpLogic.errorsFile, systemImage: "square.and.arrow.up")
                Spacer()
                if vm.busy == "download" { ProgressView() }
            }
        }
        .disabled(busy)
        .foregroundColor(Brand.text)
    }

    private func rowView(_ r: ImpRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ImpLogic.rowTitle(r)).font(.subheadline.weight(.medium))
            let action = ImpLogic.actionText(r.action)
            if !action.isEmpty {
                Text(action).font(.caption).foregroundColor(Brand.muted)
            }
            ForEach(Array(r.diff.enumerated()), id: \.offset) { _, d in
                VStack(alignment: .leading, spacing: 1) {
                    Text(ImpLogic.diffLabel(d)).font(.caption.weight(.medium))
                    Text("\(ImpLogic.was): \(ImpLogic.valueText(d.from))").font(.footnote)
                    Text("\(ImpLogic.willBe): \(ImpLogic.valueText(d.to))").font(.footnote)
                }
            }
            // Тексты ошибок и предупреждений — как прислал сервер.
            ForEach(Array(r.errors.enumerated()), id: \.offset) { _, e in
                Text(ImpLogic.rowErrorText(e))
                    .font(.caption)
                    .foregroundColor(ImpLogic.isWarning(e) ? Brand.amber : Brand.red)
            }
        }
    }

    private func counter(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline).foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity)
    }

    // ── Выбор файла ──────────────────────────────────────────────────────

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let name = url.lastPathComponent
            guard ImpLogic.isAllowedFileName(name) else {
                vm.error = ImpLogic.fileBadExt
                return
            }
            // Размер проверяем ДО чтения и отправки; файл в память не читаем — он уходит потоком.
            let scoped = url.startAccessingSecurityScopedResource()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            if scoped { url.stopAccessingSecurityScopedResource() }
            if let size, size > ImpLogic.maxBytes {
                vm.error = ImpLogic.fileTooBig
                return
            }
            vm.error = nil
            Task { await vm.loadFile(url: url, name: name) }
        case .failure(let error):
            vm.error = error.localizedDescription
        }
    }
}
