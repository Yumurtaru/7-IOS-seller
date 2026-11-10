import SwiftUI

// ============================================================================
//  «Выгрузка с фильтрами» (routes/seller_feeds.php, волна В4Б сайта): вид, набор,
//  фильтры из meta сервера, запуск задания, опрос готовности, скачивание готового
//  файла потоком на диск и системный share sheet.
//
//  Открывается из «Выгрузки и обмен», только если сайт отвечает на
//  /api/seller/exports/jobs (ExportFeature). Опрос: 3 с (реже после сбоев), один запрос
//  за раз, пауза при уходе с экрана, стоп через 10 минут + «Проверить ещё раз».
//  Логика и тексты — Core/ExportLogic.swift; на Android — ui/manage/ExportJobScreen.kt.
// ============================================================================

@MainActor
final class ExportJobViewModel: ObservableObject {
    @Published var kinds: [ExpLogic.Kind] = []
    @Published var kind: String?
    @Published var meta: ExpMeta?
    @Published var metaLoading = false
    @Published var metaError: String?
    @Published var presetId = ""
    @Published var columns: [String] = []
    @Published var filters: [String: String] = [:]
    @Published var format = "xlsx"
    @Published var starting = false
    @Published var formError: String?
    @Published var job: ExpJob?
    @Published var netWait = false
    @Published var gaveUp = false
    @Published var downloading = false
    @Published var recent: [ExpJob] = []
    @Published var shareFile: ShareFile?
    @Published var notice: String?

    private var pollTask: Task<Void, Never>?
    private var pollGen = 0
    private var failStreak = 0
    /// Начало отсчёта 10 минут опроса: не сбрасывается уходом с экрана (как на Android).
    private var pollBegan: Date?
    private var metaGen = 0

    var isRunning: Bool { job != nil && !ExpLogic.isFinal(job?.status) }

    func start() async {
        if kinds.isEmpty {
            let s = Session.shared
            kinds = ExpLogic.kinds(shopType: s.shopType) { s.can($0) }
            if let first = kinds.first { await selectKind(first.key) }
        }
        await loadRecent()
        if isRunning { startPolling() }
    }

    func selectKind(_ key: String) async {
        if kind == key && meta != nil { return }
        metaGen += 1
        let my = metaGen
        kind = key
        meta = nil
        metaLoading = true
        metaError = nil
        presetId = ""
        columns = []
        filters = [:]
        formError = nil
        await loadMeta(key, gen: my)
    }

    func reloadMeta() async {
        guard let k = kind else { return }
        metaGen += 1
        metaLoading = true
        metaError = nil
        await loadMeta(k, gen: metaGen)
    }

    private func loadMeta(_ key: String, gen: Int) async {
        do {
            let m = try await API.shared.expMeta(kind: key)
            guard gen == metaGen else { return }
            meta = m
            format = ExpLogic.pickFormat(m, wanted: format)
            metaLoading = false
        } catch is CancellationError {
            if gen == metaGen { metaLoading = false }
        } catch {
            guard gen == metaGen else { return }
            metaLoading = false
            metaError = ExpLogic.errorText(error)
        }
    }

    /// Пустой id — стандартный набор: колонки по умолчанию, фильтры сброшены.
    func applyPreset(_ id: String) {
        presetId = id
        formError = nil
        guard !id.isEmpty, let p = ExpLogic.presets(meta).first(where: { $0.presetId == id }) else {
            presetId = ""
            columns = []
            filters = [:]
            return
        }
        columns = p.spec?.columns ?? []
        filters = p.spec?.filters ?? [:]
        format = ExpLogic.pickFormat(meta, wanted: p.spec?.format ?? format)
    }

    func setFilter(_ key: String, _ value: String) {
        if value.isEmpty { filters.removeValue(forKey: key) } else { filters[key] = value }
        formError = nil
    }

    func run() async {
        guard let kind, !starting, !isRunning else { return }
        if let e = ExpLogic.validate(filters) { formError = e; return }
        stopPolling()
        starting = true
        formError = nil
        job = nil
        gaveUp = false
        netWait = false
        failStreak = 0
        pollBegan = nil
        defer { starting = false }
        do {
            let r = try await API.shared.expRun(kind: kind, columns: columns,
                                                filters: ExpLogic.cleanFilters(filters), format: format)
            job = r.job
            if r.job == nil { notice = ExpLogic.failedTitle } else if isRunning { startPolling() }
            await loadRecent()
        } catch is CancellationError {
        } catch {
            let unknown = ExpLogic.isUnknownOutcome(error)
            formError = ExpLogic.errorText(error) + (unknown ? "\n" + ExpLogic.unknownStart : "")
            if unknown { await loadRecent() }
        }
    }

    func loadRecent() async {
        // Ошибку списка не показываем: он справочный, а выгрузка работает и без него.
        if let r = try? await API.shared.expJobs(retries: 0) { recent = r.jobs }
    }

    // ── Опрос ────────────────────────────────────────────────────────────

    func startPolling() {
        guard pollTask == nil, isRunning else { return }
        pollGen += 1
        let my = pollGen
        gaveUp = false
        let began = pollBegan ?? Date()
        pollBegan = began
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: ExpLogic.pollNanos(failures: self.failStreak))
                if Task.isCancelled { return }
                await self.pollOnce()
                if Task.isCancelled { return }
                if !self.isRunning {
                    if self.pollGen == my { self.pollTask = nil }
                    await self.loadRecent()
                    return
                }
                if Date().timeIntervalSince(began) >= ExpLogic.pollGiveUpSeconds {
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
        guard let id = job?.jobId else { return }
        do {
            let r = try await API.shared.expJob(id: id)
            if let j = r.job { job = j }
            failStreak = 0
            netWait = false
        } catch is CancellationError {
        } catch {
            if ExpLogic.isTransient(error) {
                failStreak += 1
                netWait = true
            } else {
                // 404 и прочие ясные отказы: задание не найдено или нет права — ждать нечего.
                job?.status = "failed"
                job?.error = ExpLogic.errorText(error)
                netWait = false
            }
        }
    }

    /// «Проверить ещё раз» после остановки опроса: один запрос сейчас, дальше опрос идёт как обычно.
    func checkAgain() async {
        gaveUp = false
        failStreak = 0
        pollBegan = nil
        stopPolling()
        await pollOnce()
        if isRunning { startPolling() } else { await loadRecent() }
    }

    func cancelJob() async {
        guard let id = job?.jobId else { return }
        do {
            let r = try await API.shared.expCancel(id: id)
            if let j = r.job { job = j }
            if !isRunning { stopPolling() }
            await loadRecent()
        } catch is CancellationError {
        } catch {
            notice = ExpLogic.errorText(error)
        }
    }

    /// Открыть задание из списка последних: идущее продолжит опрос, готовое можно скачать.
    func open(_ j: ExpJob) {
        stopPolling()
        job = j
        gaveUp = false
        netWait = false
        failStreak = 0
        pollBegan = nil
        formError = nil
        if isRunning { startPolling() }
    }

    func dismissJob() {
        if !isRunning { job = nil }
    }

    func download() async {
        guard let j = job, !downloading else { return }
        downloading = true
        defer { downloading = false }
        do {
            let url = try await API.shared.expDownload(job: j)
            shareFile = ShareFile(url: url)
        } catch is CancellationError {
        } catch {
            notice = ExpLogic.errorText(error)
        }
    }
}

struct ExportJobView: View {
    @StateObject private var vm = ExportJobViewModel()
    @State private var confirmCancel = false

    var body: some View {
        Form {
            kindSection
            if vm.metaLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }.listRowBackground(Brand.card)
            } else if let err = vm.metaError {
                Section {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                    Button("Повторить") { Task { await vm.reloadMeta() } }
                }
                .listRowBackground(Brand.card)
            } else if let meta = vm.meta {
                optionsSection(meta)
                filtersSection(meta)
                startSection
            }
            if let j = vm.job { jobSection(j) }
            if !vm.recent.isEmpty { recentSection }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(ExpLogic.newTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.start() }
        .onDisappear { vm.stopPolling() }
        .sheet(item: $vm.shareFile) { file in
            ShareSheet(items: [file.url])
        }
        .confirmationDialog(ExpLogic.cancelTitle, isPresented: $confirmCancel, titleVisibility: .visible) {
            Button(ExpLogic.cancelYes, role: .destructive) { Task { await vm.cancelJob() } }
            Button(ExpLogic.keep, role: .cancel) {}
        } message: {
            Text(ExpLogic.cancelNote)
        }
        .errorAlert($vm.notice)
    }

    // ── Секции ───────────────────────────────────────────────────────────

    private var locked: Bool { vm.isRunning || vm.starting }

    private var kindSection: some View {
        Section {
            Picker(ExpLogic.what, selection: Binding(get: { vm.kind ?? "" },
                                                      set: { v in Task { await vm.selectKind(v) } })) {
                ForEach(vm.kinds) { k in Text(k.title).tag(k.key) }
            }
            .pickerStyle(.menu)
            .disabled(locked)
        } footer: {
            Text(ExpLogic.newHint)
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private func optionsSection(_ meta: ExpMeta) -> some View {
        let presets = ExpLogic.presets(meta)
        let formats = meta.formats.filter { !($0.value ?? "").isEmpty }
        if !presets.isEmpty || formats.count > 1 {
            Section {
                if !presets.isEmpty {
                    Picker(ExpLogic.preset, selection: Binding(get: { vm.presetId }, set: { vm.applyPreset($0) })) {
                        Text(ExpLogic.presetDefault).tag("")
                        ForEach(presets) { p in Text(p.name ?? "").tag(p.presetId ?? "") }
                    }
                    .pickerStyle(.menu)
                    .disabled(locked)
                }
                if formats.count > 1 {
                    Picker(ExpLogic.format, selection: $vm.format) {
                        ForEach(Array(formats.enumerated()), id: \.offset) { _, f in
                            Text(f.label ?? f.value ?? "").tag(f.value ?? "")
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(locked)
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    @ViewBuilder
    private func filtersSection(_ meta: ExpMeta) -> some View {
        let list = meta.filters.filter { f in
            !(f.key ?? "").isEmpty && ["text", "select", "date", "bool"].contains(f.type ?? "")
        }
        if !list.isEmpty {
            Section(ExpLogic.filters) {
                ForEach(list) { f in
                    filterRow(f)
                }
            }
            .listRowBackground(Brand.card)
            .disabled(locked)
        }
    }

    @ViewBuilder
    private func filterRow(_ f: ExpFilter) -> some View {
        let key = f.key ?? ""
        let label = (f.label ?? "").isEmpty ? key : (f.label ?? key)
        switch f.type ?? "" {
        case "text":
            TextField(label, text: Binding(get: { vm.filters[key] ?? "" }, set: { vm.setFilter(key, String($0.prefix(120))) }))
        case "date":
            ExportDateRow(title: label, value: vm.filters[key] ?? "") { vm.setFilter(key, $0) }
        case "bool":
            Toggle(label, isOn: Binding(get: { vm.filters[key] == "1" }, set: { vm.setFilter(key, $0 ? "1" : "") }))
        case "select":
            let opts = f.options.filter { $0.value != nil }
            Picker(label, selection: Binding(get: { vm.filters[key] ?? "" }, set: { vm.setFilter(key, $0) })) {
                Text(ExpLogic.anyValue).tag("")
                ForEach(Array(opts.enumerated()), id: \.offset) { _, o in
                    Text(o.label ?? o.value ?? "").tag(o.value ?? "")
                }
            }
            .pickerStyle(.menu)
        default:
            EmptyView()
        }
    }

    private var startSection: some View {
        Section {
            if let e = vm.formError {
                Text(e).font(.footnote).foregroundColor(Brand.red)
            }
            Button {
                Task { await vm.run() }
            } label: {
                HStack {
                    Text(vm.starting ? ExpLogic.starting : ExpLogic.start)
                    Spacer()
                    if vm.starting { ProgressView() }
                }
            }
            .disabled(locked || vm.kind == nil)
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private func jobSection(_ j: ExpJob) -> some View {
        let running = vm.isRunning
        Section {
            Text(jobTitle(j)).font(.headline)
            Text(ExpLogic.jobLine(j)).font(.caption).foregroundColor(Brand.muted)
            if running {
                if let p = j.progress, p > 0 {
                    ProgressView(value: Double(min(100, p)), total: 100)
                } else {
                    ProgressView()
                }
                if let rows = ExpLogic.rowsText(done: j.rowsDone, total: j.rowsTotal) {
                    Text(rows).font(.footnote)
                }
                if vm.netWait {
                    Text(ExpLogic.networkWait).font(.footnote).foregroundColor(Brand.muted)
                }
                if vm.gaveUp {
                    Text(ExpLogic.slow).font(.footnote)
                    Button(ExpLogic.checkAgain) { Task { await vm.checkAgain() } }
                }
                Button(ExpLogic.cancel, role: .destructive) { confirmCancel = true }
            }
            if j.status == "done" {
                let facts = [ExpLogic.rowsText(done: nil, total: j.rowsTotal), ExpLogic.sizeText(j.size)].compactMap { $0 }
                if !facts.isEmpty { Text(facts.joined(separator: " · ")).font(.footnote) }
                ForEach(Array(ExpLogic.warnings(j).enumerated()), id: \.offset) { _, w in
                    Text(w).font(.footnote).foregroundColor(Brand.muted)
                }
                Button {
                    Task { await vm.download() }
                } label: {
                    HStack {
                        Text(vm.downloading ? ExpLogic.downloading : ExpLogic.download)
                        Spacer()
                        if vm.downloading { ProgressView() }
                    }
                }
                .disabled(vm.downloading)
                Text(ExpLogic.ttlNote).font(.caption).foregroundColor(Brand.muted)
            }
            if j.status == "failed", let e = j.error, !e.isEmpty {
                Text(e).font(.footnote).foregroundColor(Brand.red)
            }
            if !running {
                Button(ExpLogic.close) { vm.dismissJob() }
            }
        }
        .listRowBackground(Brand.card)
    }

    private func jobTitle(_ j: ExpJob) -> String {
        switch j.status ?? "" {
        case "done": return ExpLogic.ready
        case "failed": return ExpLogic.failedTitle
        case "cancelled": return ExpLogic.cancelledTitle
        case "expired": return ExpLogic.expiredText
        default: return ExpLogic.progressPercentText(j)
        }
    }

    private var recentSection: some View {
        Section(ExpLogic.recent) {
            ForEach(vm.recent) { j in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ExpLogic.jobLine(j))
                        if let c = j.createdAt, !c.isEmpty {
                            Text(DateFmt.short(c)).font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                    Spacer()
                    Button("Открыть") { vm.open(j) }
                        .buttonStyle(.borderless)
                        .disabled(vm.job?.jobId == j.jobId)
                }
            }
        }
        .listRowBackground(Brand.card)
    }
}

/// Строка даты фильтра: значение «yyyy-MM-dd»; пусто — «Не выбрана» (нажатие ставит сегодня), рядом «Сбросить».
private struct ExportDateRow: View {
    let title: String
    let value: String
    let onChange: (String) -> Void

    var body: some View {
        if value.isEmpty {
            HStack {
                Text(title)
                Spacer()
                Button(ExpLogic.dateNotSet) { onChange(DateFmt.ymd(Date())) }
                    .buttonStyle(.borderless)
            }
        } else {
            HStack {
                DatePicker(title, selection: Binding(get: { DateFmt.parse(value) ?? Date() },
                                                     set: { onChange(DateFmt.ymd($0)) }),
                           displayedComponents: .date)
                Button(ExpLogic.dateClear) { onChange("") }
                    .buttonStyle(.borderless)
            }
        }
    }
}
