import SwiftUI
import UniformTypeIdentifiers

// ============================================================================
//  Импорт товаров и ингредиентов из файла.
//
//  Раньше загрузка была только в веб-кабинете: приложение умело скачать
//  шаблон, но не залить заполненный. Здесь те же три шага сервера —
//  upload -> preview -> run, — и предпросмотр обязателен: сначала показываем,
//  что произойдёт, и только потом даём кнопку «Импортировать».
//
//  Право — «Товары» (products).
// ============================================================================

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var target = "products"
    @Published var upload: ImportUpload?
    /// поле -> номер колонки в файле; nil = поле не заполняется.
    // Поменяли колонки или режим — прежняя проверка уже не про эти настройки:
    // раньше «Импортировать» оставалось активным, и каталог менялся без
    // предпросмотра нового режима.
    @Published var mapping: [String: Int] = [:] { didSet { if mapping != oldValue { preview = nil } } }
    @Published var mode = "both" { didSet { if mode != oldValue { preview = nil } } }
    @Published var skipErrors = true { didSet { if skipErrors != oldValue { preview = nil } } }
    @Published var preview: ImportResult?
    @Published var applied: ImportResult?
    @Published var busy: String?
    @Published var error: String?

    var canSubmit: Bool {
        guard let u = upload, u.fileId != nil else { return false }
        // Обязательные поля должны быть замаплены — иначе сервер отобьёт каждую строку.
        return missingRequired.isEmpty
    }

    /// Названия незаполненных обязательных полей.
    var missingRequired: [String] {
        guard let u = upload, let fields = u.fields else { return [] }
        return u.orderedFieldKeys.compactMap { key in
            guard fields[key]?.required == true, mapping[key] == nil else { return nil }
            return fields[key]?.label ?? key
        }
    }

    func load(filename: String, mime: String, data: Data) async {
        busy = "upload"
        defer { busy = nil }
        error = nil; preview = nil; applied = nil
        do {
            let res = try await API.shared.importUpload(target: target, filename: filename,
                                                        mime: mime, data: data)
            upload = res
            mapping = res.suggested ?? [:]
        } catch {
            self.error = error.localizedDescription
        }
    }

    // ── А60/П-23.6: импорт после обрыва связи / 409 «уже выполняется» ──────
    /// Импорт остановился на этой строке — можно продолжить с неё.
    @Published var stoppedAt: Int?
    /// Запуск сорвался (обрыв, сбой на сервере) — можно повторить тот же запрос:
    /// сервер не выполнит его второй раз, а отдаст сохранённый отчёт (replayed).
    @Published var canRetryRun = false
    /// Опрос не дождался итога — кнопка «Проверить статус».
    @Published var canCheckStatus = false
    /// Идёт опрос статуса: импорт выполняется на сервере.
    @Published var waitingStatus = false
    /// start_row последнего запуска — для повтора «того же запроса».
    private(set) var lastStartRow: Int?
    private var pollGen = 0
    /// Экран виден. Ушли во время долгого run или первого запроса статуса —
    /// опрос не начинаем (раньше он шёл ещё ~5 минут без экрана).
    private var onScreen = true
    func screenAppeared() { onScreen = true }

    func run(apply: Bool, startRow: Int? = nil) async {
        guard let u = upload, let fileId = u.fileId else { return }
        guard busy == nil else { return }   // двойной тап — один запуск
        busy = apply ? "run" : "preview"
        defer { busy = nil }
        error = nil
        if apply {
            // stoppedAt не сбрасываем до итога: если продолжение сорвётся отказом,
            // кнопка «Продолжить со строки N» должна остаться (finish обновит её).
            canRetryRun = false; canCheckStatus = false
            lastStartRow = startRow
        }
        let snap = (mapping, mode, skipErrors)
        do {
            let res = try await API.shared.importProcess(
                apply: apply, fileId: fileId, target: u.target ?? target,
                mapping: mapping, mode: mode, skipErrors: skipErrors, startRow: apply ? startRow : nil)
            // replayed (повтор после обрыва) — тот же отчёт, считаем как готово.
            if apply { finish(res) }
            else if mapping == snap.0 && mode == snap.1 && skipErrors == snap.2 { preview = res }
        } catch is CancellationError {
        } catch {
            // А60/П-23.6: обрыв или таймаут run не значит, что импорт не прошёл —
            // раньше показывалась ошибка, а повторный запуск задваивал товары.
            if apply { await recover(fileId: fileId, after: error) }
            else { self.error = error.localizedDescription }
        }
    }

    /// Кнопка «Проверить статус» — тот же опрос без нового запуска.
    func checkStatus() async {
        guard let fileId = upload?.fileId, busy == nil else { return }
        busy = "run"
        defer { busy = nil }
        error = nil
        canCheckStatus = false
        await recover(fileId: fileId, after: APIError.network,
                      text: "Итог импорта на сервере не найден — запустите импорт ещё раз")
    }

    /// Ушли с экрана — опрос прекращаем (вернувшись, можно проверить статус).
    func stopPolling() {
        onScreen = false
        let active = waitingStatus || busy == "run"
        pollGen += 1
        waitingStatus = false
        if active { canCheckStatus = true }
    }

    /// Нет сети / нет ответа — сервер запрос мог и не увидеть.
    private static func isConnectionDrop(_ error: Error) -> Bool {
        guard let e = error as? APIError else { return false }
        switch e {
        case .network, .timeout: return true
        default: return false
        }
    }

    private func finish(_ res: ImportResult) {
        stoppedAt = (res.stoppedAt ?? 0) > 0 ? res.stoppedAt : nil
        applied = res
    }

    /// Опрос GET /api/seller/import/status раз в 4 с (до ~5 минут):
    /// running — ждём; done — отчёт; stopped — «Продолжить со строки N»;
    /// failed/interrupted — «Повторить». Для ответа-отказа сервера (409 и т. п.)
    /// опрос идёт, только если импорт этого файла и правда сейчас выполняется.
    private func recover(fileId: String, after original: Error, text: String? = nil) async {
        var dropped = false
        if let e = original as? APIError {
            // Обрыв, таймаут, 5xx шлюза (504 на долгом запросе) или непонятный
            // ответ при успехе — итог неизвестен, импорт мог пройти или ещё идёт.
            switch e {
            case .network, .timeout, .decoding, .http: dropped = true
            default: break
            }
        }
        let originalText = text ?? original.localizedDescription
        pollGen += 1
        let myGen = pollGen
        guard onScreen else { canCheckStatus = true; return }
        var sawRunning = false
        var failures = 0
        defer { if myGen == pollGen { waitingStatus = false } }
        for attempt in 0..<75 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            guard myGen == pollGen, onScreen, !Task.isCancelled else {
                if !onScreen { canCheckStatus = true }
                return
            }
            let st: ImportStatus
            do {
                st = try await API.shared.importStatus(fileId: fileId)
            } catch is CancellationError {
                return
            } catch {
                guard myGen == pollGen else { return }
                // Старый сервер (ручки нет) или отказ — показываем исходную ошибку,
                // как раньше. Ждём дальше только при обрыве связи во время опроса.
                if !sawRunning && (!dropped || !Self.isConnectionDrop(error)) {
                    self.error = originalText
                    return
                }
                failures += 1
                if failures >= 5 { break }
                continue
            }
            guard myGen == pollGen else { return }
            // Статус чужого файла — не про наш запуск.
            if let f = st.fileId, !f.isEmpty, f != fileId {
                self.error = originalText
                if dropped { canRetryRun = true }
                return
            }
            switch st.state {
            case "running":
                sawRunning = true
                waitingStatus = true
                continue
            case "done" where dropped || sawRunning:
                finish(st.result ?? ImportResult())
                return
            case "stopped" where dropped || sawRunning:
                finish(st.result ?? ImportResult())
                if stoppedAt == nil { canRetryRun = true }
                return
            case "failed" where dropped || sawRunning, "interrupted" where dropped || sawRunning:
                self.error = "Импорт прервался на сервере — запустите его ещё раз"
                canRetryRun = true
                return
            default:
                // unknown — запуск до сервера не дошёл; отказ сервера — его текст.
                self.error = originalText
                if dropped { canRetryRun = true }
                return
            }
        }
        guard myGen == pollGen else { return }
        self.error = "Импорт ещё идёт или нет связи — проверьте результат чуть позже"
        canCheckStatus = true
    }

    func reset() {
        pollGen += 1   // опрос прежнего файла больше не нужен
        upload = nil; mapping = [:]; preview = nil; applied = nil; error = nil
        stoppedAt = nil; canRetryRun = false; canCheckStatus = false; waitingStatus = false
        lastStartRow = nil
    }
}

struct ImportView: View {
    @EnvironmentObject private var session: Session
    /// Право запуска импорта (см. actionsSection).
    private var canRun: Bool { session.can("products.create") }
    @StateObject private var vm = ImportViewModel()
    @State private var picking = false

    var body: some View {
        Form {
            if vm.applied != nil {
                resultSection
            } else if vm.upload == nil {
                pickSection
            } else {
                mappingSection
                optionsSection
                if let p = vm.preview { previewSection(p) }
                actionsSection
            }
            recoverySection
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Импорт из файла")
        .navigationBarTitleDisplayMode(.inline)
        // А60/П-23.6: ушли с экрана — опрос статуса не крутится в фоне.
        .onAppear { vm.screenAppeared() }
        .onDisappear { vm.stopPolling() }
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: allowedTypes,
                      allowsMultipleSelection: false) { result in
            handlePick(result)
        }
    }

    /// CSV и XLSX — ровно то, что принимает сервер.
    private var allowedTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText]
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let xls = UTType(filenameExtension: "xls") { types.append(xls) }
        return types
    }

    // ── Шаг 1: выбор файла ───────────────────────────────────────────────
    private var pickSection: some View {
        Section {
            Picker("Что импортируем", selection: $vm.target) {
                Text("Товары").tag("products")
                if session.shopType == "cafe" {
                    Text("Ингредиенты").tag("ingredients")
                }
            }
            Button {
                picking = true
            } label: {
                HStack {
                    Label("Выбрать файл", systemImage: "doc.badge.plus")
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
            Text("CSV или XLSX до 10 МБ, до 10 000 строк. Проще всего скачать шаблон, заполнить его и загрузить обратно.")
        }
        .listRowBackground(Brand.card)
    }

    // ── Шаг 2: сопоставление колонок ─────────────────────────────────────
    @ViewBuilder
    private var mappingSection: some View {
        if let u = vm.upload {
            Section {
                ForEach(u.orderedFieldKeys, id: \.self) { key in
                    Picker(selection: Binding(
                        get: { vm.mapping[key] ?? -1 },
                        set: { newValue in
                            if newValue < 0 { vm.mapping.removeValue(forKey: key) }
                            else { vm.mapping[key] = newValue }
                        }
                    )) {
                        Text("— не заполнять —").tag(-1)
                        ForEach(Array((u.headers ?? []).enumerated()), id: \.offset) { idx, head in
                            Text(head.isEmpty ? "Колонка \(idx + 1)" : head).tag(idx)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(u.fields?[key]?.label ?? key)
                            if u.fields?[key]?.required == true {
                                Text("*").foregroundColor(Brand.red)
                            }
                        }
                    }
                }
            } header: {
                Text("Колонки файла")
            } footer: {
                Text("Строк в файле: \(u.total ?? 0). Звёздочкой отмечены обязательные поля — без них строка не импортируется.")
            }
            .listRowBackground(Brand.card)
        }
    }

    private var optionsSection: some View {
        Section {
            Picker("Режим", selection: $vm.mode) {
                Text("Добавлять и обновлять").tag("both")
                Text("Только добавлять").tag("add")
                Text("Только обновлять").tag("update")
            }
            Toggle("Пропускать строки с ошибками", isOn: $vm.skipErrors)
        } footer: {
            Text("Совпадения ищутся по артикулу, штрихкоду и названию. Без пропуска ошибок импорт остановится на первой плохой строке.")
        }
        .listRowBackground(Brand.card)
    }

    // ── Шаг 3: что получится ─────────────────────────────────────────────
    private func previewSection(_ p: ImportResult) -> some View {
        Section {
            countersRow(p.report)
            // По порядку, а не по номеру строки: у одной строки файла сервер даёт
            // несколько записей (нет права «Цены» и «Склад») — одинаковый id в
            // списке формы путал строки и мог уронить обновление списка.
            ForEach(Array((p.errors ?? []).prefix(10).enumerated()), id: \.offset) { _, e in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Строка \(e.line ?? 0): \(e.error ?? "ошибка")")
                        .font(.caption).foregroundColor(Brand.red)
                    if let n = e.name, !n.isEmpty {
                        Text(n).font(.caption2).foregroundColor(Brand.muted)
                    }
                }
            }
        } header: {
            Text("Что получится")
        } footer: {
            Text("Это только расчёт — в базе пока ничего не изменилось.")
        }
        .listRowBackground(Brand.card)
    }

    private var actionsSection: some View {
        Section {
            if !vm.missingRequired.isEmpty {
                Text("Заполните обязательные поля: " + vm.missingRequired.joined(separator: ", "))
                    .font(.footnote).foregroundColor(Brand.amber)
            }
            Button {
                Task { await vm.run(apply: false) }
            } label: {
                HStack {
                    Label("Проверить", systemImage: "eye")
                    Spacer()
                    if vm.busy == "preview" { ProgressView() }
                }
            }
            .disabled(vm.busy != nil || !vm.canSubmit)
            .foregroundColor(Brand.text)

            // Сам импорт (POST import/run) заводит и меняет товары — сервер пускает
            // только с правом «Создавать товары» (StaffAccess::actionPerms →
            // products.create). Проверить файл можно и без него; запуск вёл к 403.
            if canRun {
                Button {
                    Task { await vm.run(apply: true) }
                } label: {
                    HStack {
                        Label("Импортировать", systemImage: "square.and.arrow.down.on.square")
                        Spacer()
                        if vm.busy == "run" { ProgressView() }
                    }
                }
                // Импорт открываем только после проверки: иначе владелец узнаёт
                // о битом файле уже по факту изменённого каталога.
                .disabled(vm.busy != nil || !vm.canSubmit || vm.preview == nil)
                .foregroundColor(vm.preview == nil ? Brand.muted : Brand.accent)
                // Серая «Импортировать» без объяснения выглядела сломанной: она ждёт
                // проверку, а смена колонок или режима проверку сбрасывает.
                if vm.canSubmit && vm.preview == nil && vm.busy == nil {
                    Text("Сначала нажмите «Проверить» — импорт откроется после предпросмотра.")
                        .font(.footnote).foregroundColor(Brand.muted)
                }
            } else {
                Text("Импортировать может владелец или сотрудник с правом «Создавать товары» — файл можно только проверить.")
                    .font(.footnote).foregroundColor(Brand.muted)
            }

            Button(role: .destructive) { vm.reset() } label: {
                Label("Выбрать другой файл", systemImage: "arrow.counterclockwise")
            }
            .disabled(vm.busy != nil)
        }
        .listRowBackground(Brand.card)
    }

    private var resultSection: some View {
        Section {
            // Итог уже выполненного импорта: «Добавлено», а не «Добавить» —
            // повелительные подписи предпросмотра читались как «ещё не сделано».
            countersRow(vm.applied?.report, done: true)
            // По порядку: номер строки в отчёте повторяется (см. previewSection).
            ForEach(Array((vm.applied?.errors ?? []).prefix(20).enumerated()), id: \.offset) { _, e in
                Text("Строка \(e.line ?? 0): \(e.error ?? "ошибка")")
                    .font(.caption).foregroundColor(Brand.red)
            }
            // А60/П-23.6: импорт остановился — продолжить с той строки (start_row).
            if let s = vm.stoppedAt {
                Button {
                    Task { await vm.run(apply: true, startRow: s) }
                } label: {
                    Label("Продолжить со строки \(s)", systemImage: "play.fill")
                }
                .disabled(vm.busy != nil || !canRun)
                .foregroundColor(Brand.accent)
            }
            Button { vm.reset() } label: {
                Label("Импортировать ещё файл", systemImage: "arrow.counterclockwise")
            }
            .disabled(vm.busy != nil)
            .foregroundColor(Brand.text)
        } header: {
            Text(vm.stoppedAt.map { "Импорт остановлен на строке \($0)" } ?? "Импорт завершён")
        }
        .listRowBackground(Brand.card)
    }

    /// А60/П-23.6: ожидание итога на сервере, повтор того же запуска, проверка статуса.
    @ViewBuilder
    private var recoverySection: some View {
        let continuing = vm.applied != nil && vm.busy == "run" && !vm.waitingStatus
        if vm.waitingStatus || vm.canRetryRun || vm.canCheckStatus || continuing {
            Section {
                if vm.waitingStatus {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Импорт выполняется на сервере — ждём результат…").font(.footnote)
                    }
                } else if continuing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Импорт продолжается…").font(.footnote)
                    }
                }
                if vm.canRetryRun {
                    Button {
                        Task { await vm.run(apply: true, startRow: vm.lastStartRow) }
                    } label: {
                        Label("Повторить импорт", systemImage: "arrow.clockwise")
                    }
                    // Колонки/режим поменяли после сбоя — это уже другой запрос: сначала «Проверить».
                    .disabled(vm.busy != nil || (vm.applied == nil && vm.preview == nil) || !canRun)
                    .foregroundColor(Brand.accent)
                }
                if vm.canCheckStatus {
                    Button {
                        Task { await vm.checkStatus() }
                    } label: {
                        Label("Проверить статус", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(vm.busy != nil)
                    .foregroundColor(Brand.text)
                }
            } footer: {
                if vm.canRetryRun {
                    Text("Повтор безопасен: если импорт уже прошёл, сервер вернёт тот же отчёт и ничего не задвоит.")
                }
            }
            .listRowBackground(Brand.card)
        }
    }

    private func countersRow(_ c: ImportCounters?, done: Bool = false) -> some View {
        HStack(spacing: 14) {
            counter(done ? "Добавлено" : "Добавить", c?.add ?? 0, Brand.green)
            counter(done ? "Обновлено" : "Обновить", c?.update ?? 0, Brand.accent)
            counter(done ? "Пропущено" : "Пропуск", c?.skip ?? 0, Brand.muted)
            counter(done ? "Ошибок" : "Ошибки", c?.error ?? 0, Brand.red)
        }
        .frame(maxWidth: .infinity)
    }

    private func counter(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline).foregroundColor(color)
            Text(title).font(.caption2).foregroundColor(Brand.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // П-22.9: сервер решает только по расширению имени (MIME не смотрит):
            // CSV/TXT под другим именем не разберётся — пускаем .csv/.xlsx/.xls и
            // отправляем с исходным именем файла.
            let ext = url.pathExtension.lowercased()
            guard ["csv", "xlsx", "xls"].contains(ext) else {
                vm.error = "Нужен файл .csv или .xlsx — другой формат сервер не примет"
                return
            }
            // Файл лежит вне песочницы приложения — читаем под security scope.
            let scoped = url.startAccessingSecurityScopedResource()
            let maxBytes = 10 * 1024 * 1024
            // П-22.9: больше 10 МБ сервер не примет — не гоняем файл по сети зря.
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                if scoped { url.stopAccessingSecurityScopedResource() }
                vm.error = "Файл больше 10 МБ — разбейте его на части"
                return
            }
            let name = url.lastPathComponent
            let mime = ext == "csv"
                ? "text/csv"
                : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            // Чтение — не на главном потоке: файл до 10 МБ (а из iCloud Drive —
            // ещё и со скачиванием) читался прямо в интерфейсе, экран замирал.
            // Пока читаем, «Выбрать файл» занята — второй выбор не начинается.
            vm.error = nil
            vm.busy = "upload"
            Task { @MainActor in
                let read = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                    Result { try Data(contentsOf: url) }
                }.value
                if scoped { url.stopAccessingSecurityScopedResource() }
                vm.busy = nil
                switch read {
                case .success(let data):
                    guard data.count <= maxBytes else {
                        vm.error = "Файл больше 10 МБ — разбейте его на части"
                        return
                    }
                    await vm.load(filename: name, mime: mime, data: data)
                case .failure(let error):
                    vm.error = "Не удалось прочитать файл: " + error.localizedDescription
                }
            }
        case .failure(let error):
            vm.error = error.localizedDescription
        }
    }
}
