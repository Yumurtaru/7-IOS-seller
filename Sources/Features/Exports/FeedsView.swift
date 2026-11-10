import SwiftUI
import UIKit

// ============================================================================
//  «Фиды для площадок» (routes/seller_feeds.php, волна В4Б сайта): карточки Яндекс Маркета,
//  VK, Авито и Google Merchant — включение, простые настройки, ссылка (скопировать,
//  поделиться, перевыпустить), «Собрать сейчас», статус последней сборки и замечания
//  по товарам. Пункт виден, только если сайт отвечает (FeedFeature) и есть право «Товары».
//  Логика и тексты — Core/ExportLogic.swift (FeedLogic); на Android — ui/manage/FeedsScreen.kt.
// ============================================================================

@MainActor
final class FeedsViewModel: ObservableObject {
    @Published var data: FeedsReply?
    @Published var state: LoadState = .idle
    @Published var busy: Set<String> = []
    @Published var notice: String?
    @Published var info: String?
    @Published var netWait = false
    @Published var gaveUp = false
    @Published var settingsError: String?

    private var pollTask: Task<Void, Never>?
    private var pollGen = 0
    private var failStreak = 0
    /// Начало отсчёта 10 минут опроса: не сбрасывается уходом с экрана (как на Android).
    private var pollBegan: Date?
    private var loadGen = 0
    private var infoGen = 0

    var anyBuilding: Bool { (data?.feeds ?? []).contains { FeedLogic.isBuilding($0) } }

    func start() async {
        await load()
    }

    func load() async {
        loadGen += 1
        let my = loadGen
        if data == nil { state = .loading }
        do {
            let r = try await API.shared.feeds(retries: 2)
            guard my == loadGen else { return }
            data = r
            state = .loaded
            gaveUp = false
            netWait = false
            if anyBuilding { startPolling() } else { stopPolling(); pollBegan = nil }
        } catch is CancellationError {
        } catch {
            guard my == loadGen else { return }
            let text = ExpLogic.errorText(error)
            if data == nil { state = .failed(text) } else { notice = text }
        }
    }

    // ── Опрос сборки ─────────────────────────────────────────────────────

    func startPolling() {
        guard pollTask == nil, anyBuilding else { return }
        pollGen += 1
        let my = pollGen
        gaveUp = false
        let began = pollBegan ?? Date()
        pollBegan = began
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay: UInt64 = self.failStreak == 0 ? FeedLogic.buildPollNanos : ExpLogic.pollNanos(failures: self.failStreak)
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                await self.pollOnce()
                if Task.isCancelled { return }
                if !self.anyBuilding {
                    if self.pollGen == my { self.pollTask = nil }
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
        do {
            let r = try await API.shared.feeds(retries: 0)
            data = r
            failStreak = 0
            netWait = false
        } catch is CancellationError {
        } catch {
            if ExpLogic.isTransient(error) {
                failStreak += 1
                netWait = true
            } else {
                notice = ExpLogic.errorText(error)
                gaveUp = true
                stopPolling()
            }
        }
    }

    func checkAgain() async {
        gaveUp = false
        failStreak = 0
        pollBegan = nil
        stopPolling()
        await load()
    }

    // ── Действия ─────────────────────────────────────────────────────────

    private func replace(_ card: FeedCard?) {
        guard let card, var d = data else { return }
        d.feeds = d.feeds.map { $0.type == card.type ? card : $0 }
        data = d
        if anyBuilding { startPolling() }
    }

    private func begin(_ key: String) -> Bool {
        if busy.contains(key) { return false }
        busy.insert(key)
        return true
    }

    func setEnabled(_ type: String, _ on: Bool) async {
        guard begin(type) else { return }
        defer { busy.remove(type) }
        do {
            replace(try await API.shared.feedEnable(type: type, on: on).feed)
        } catch is CancellationError {
        } catch {
            notice = ExpLogic.errorText(error)
        }
    }

    func rotate(_ type: String) async {
        guard begin(type) else { return }
        defer { busy.remove(type) }
        do {
            replace(try await API.shared.feedRotate(type: type).feed)
        } catch is CancellationError {
        } catch {
            notice = ExpLogic.errorText(error)
        }
    }

    func rebuild(_ type: String) async {
        guard begin(type) else { return }
        defer { busy.remove(type) }
        do {
            replace(try await API.shared.feedRebuild(type: type).feed)
        } catch is CancellationError {
        } catch {
            notice = ExpLogic.errorText(error)
        }
    }

    /// Сохранить настройки. true — окно можно закрыть. Ошибку заполнения показываем в окне, без запроса.
    func saveOptions(_ type: String, _ d: FeedDraft) async -> Bool {
        if let e = FeedLogic.validate(type: type, d) { settingsError = e; return false }
        guard begin(type) else { return false }
        defer { busy.remove(type) }
        settingsError = nil
        do {
            replace(try await API.shared.feedSaveOptions(type: type, options: FeedLogic.optionsBody(type: type, d)).feed)
            showInfo(FeedLogic.saved)
            return true
        } catch is CancellationError {
            return false
        } catch {
            settingsError = ExpLogic.errorText(error)
            return false
        }
    }

    func setVat(_ value: String) async {
        guard begin("vat") else { return }
        defer { busy.remove("vat") }
        do {
            let r = try await API.shared.feedSetVat(value)
            if let v = r.vat, var d = data { d.vat = v; data = d }
            // Ставка влияет на файл Маркета: сервер пересоберёт его сам — перечитаем список.
            await load()
        } catch is CancellationError {
        } catch {
            notice = ExpLogic.errorText(error)
        }
    }

    func showInfo(_ text: String) {
        info = text
        infoGen += 1
        let my = infoGen
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, self.infoGen == my else { return }
            self.info = nil
        }
    }
}

private enum FeedsSheet: Identifiable {
    case settings(type: String)
    case share(text: String)

    var id: String {
        switch self {
        case .settings(let t): return "settings-" + t
        case .share(let x): return "share-" + x
        }
    }
}

struct FeedsView: View {
    @StateObject private var vm = FeedsViewModel()
    @State private var sheet: FeedsSheet?
    @State private var rotateType: String?

    var body: some View {
        List {
            Section {
                Text(FeedLogic.hint).font(.footnote).foregroundColor(Brand.muted)
            }
            .listRowBackground(Color.clear)
            if let info = vm.info {
                Section { Text(info).font(.footnote).foregroundColor(Brand.green) }
                    .listRowBackground(Brand.card)
            }
            if let data = vm.data {
                vatSection(data)
                if vm.netWait {
                    Section { Text(FeedLogic.networkWait).font(.footnote).foregroundColor(Brand.muted) }
                        .listRowBackground(Brand.card)
                }
                if vm.gaveUp && vm.anyBuilding {
                    Section {
                        Text(ExpLogic.slow).font(.footnote)
                        Button(ExpLogic.checkAgain) { Task { await vm.checkAgain() } }
                    }
                    .listRowBackground(Brand.card)
                }
                ForEach(data.feeds) { card in
                    feedSection(card)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(FeedLogic.sectionTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "link", emptyTitle: FeedLogic.sectionTitle, emptySubtitle: nil,
                   retry: { Task { await vm.load() } })
        .task { await vm.start() }
        .onDisappear { vm.stopPolling() }
        .sheet(item: $sheet) { s in
            switch s {
            case .settings(let type):
                if let card = vm.data?.feeds.first(where: { $0.type == type }) {
                    FeedSettingsSheet(vm: vm, card: card, categories: vm.data?.categories ?? [])
                } else {
                    EmptyView()
                }
            case .share(let text):
                ShareSheet(items: [text])
            }
        }
        .confirmationDialog(FeedLogic.rotateTitle,
                            isPresented: Binding(get: { rotateType != nil }, set: { if !$0 { rotateType = nil } }),
                            titleVisibility: .visible,
                            presenting: rotateType) { t in
            // presenting передаёт тип в действие копией: закрытие диалога (rotateType = nil) его не теряет.
            Button(FeedLogic.rotateYes, role: .destructive) { Task { await vm.rotate(t) } }
            Button(FeedLogic.keep, role: .cancel) {}
        } message: { _ in
            Text(FeedLogic.rotateNote)
        }
        .errorAlert($vm.notice)
    }

    // ── Секции ───────────────────────────────────────────────────────────

    private func vatSection(_ data: FeedsReply) -> some View {
        let options = (data.vat?.options ?? []).filter { $0.value != nil }
        let value = data.vat?.value ?? ""
        return Section {
            Picker(FeedLogic.vatTitle, selection: Binding(get: { value }, set: { v in Task { await vm.setVat(v) } })) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                    Text(o.label ?? o.value ?? "").tag(o.value ?? "")
                }
            }
            .pickerStyle(.menu)
            .disabled(vm.busy.contains("vat") || options.isEmpty)
            if value.isEmpty {
                Text(FeedLogic.vatWarning).font(.footnote).foregroundColor(Brand.red)
            }
        }
        .listRowBackground(Brand.card)
    }

    @ViewBuilder
    private func feedSection(_ card: FeedCard) -> some View {
        let type = card.type ?? ""
        let busy = vm.busy.contains(type)
        let enabled = card.enabled ?? false
        let url = (card.url ?? "").trimmingCharacters(in: .whitespaces)
        Section {
            Toggle(isOn: Binding(get: { enabled }, set: { on in Task { await vm.setEnabled(type, on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title ?? type).font(.headline)
                    Text(FeedLogic.statusText(card)).font(.caption)
                        .foregroundColor(card.status == "error" ? Brand.red : Brand.muted)
                }
            }
            .disabled(busy)
            if enabled || (card.exists ?? false) {
                if let t = FeedLogic.builtText(card) { Text(t).font(.footnote) }
                if let t = FeedLogic.itemsText(card) { Text(t).font(.footnote) }
                if let t = FeedLogic.fetchText(card) { Text(t).font(.footnote) }
                if let e = card.buildError, !e.isEmpty { Text(e).font(.footnote).foregroundColor(Brand.red) }
            }
            if !url.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(FeedLogic.link).font(.caption).foregroundColor(Brand.muted)
                    Text(url).font(.footnote).textSelection(.enabled)
                }
                HStack {
                    Button(FeedLogic.copy) {
                        UIPasteboard.general.string = url
                        vm.showInfo(FeedLogic.copied)
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button(FeedLogic.share) { sheet = .share(text: FeedLogic.shareText(card) ?? url) }
                        .buttonStyle(.borderless)
                }
            } else if card.urlHidden ?? false {
                Text(FeedLogic.urlHidden).font(.footnote).foregroundColor(Brand.red)
            }
            if enabled {
                Button {
                    Task { await vm.rebuild(type) }
                } label: {
                    HStack {
                        Text(busy ? FeedLogic.rebuilding : FeedLogic.rebuild)
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy)
            }
            Button(FeedLogic.settings) { sheet = .settings(type: type) }
                .disabled(busy)
            if !url.isEmpty || (card.urlHidden ?? false) {
                Button(FeedLogic.rotate) { rotateType = type }
                    .disabled(busy)
            }
            let issues = card.issues.filter { !($0.title ?? "").isEmpty }
            if !issues.isEmpty {
                Text(FeedLogic.issues).font(.caption).foregroundColor(Brand.muted)
                ForEach(Array(issues.enumerated()), id: \.offset) { _, it in
                    Text("• " + FeedLogic.issueLine(title: it.title, count: it.count))
                        .font(.footnote)
                        .foregroundColor(it.level == "error" ? Brand.red : Brand.muted)
                }
            }
            if let help = card.help, !(help.whereTo ?? "").isEmpty || !(help.steps ?? []).isEmpty {
                DisclosureGroup(FeedLogic.howTo) {
                    if let w = help.whereTo, !w.isEmpty { Text(w).font(.footnote) }
                    ForEach(Array((help.steps ?? []).enumerated()), id: \.offset) { i, s in
                        Text("\(i + 1). \(s)").font(.footnote)
                    }
                    ForEach(Array((help.notes ?? []).enumerated()), id: \.offset) { _, n in
                        Text(n).font(.caption).foregroundColor(Brand.muted)
                    }
                }
            }
        }
        .listRowBackground(Brand.card)
    }
}

/// Окно настроек фида. Закрывается само после успешного сохранения.
private struct FeedSettingsSheet: View {
    @ObservedObject var vm: FeedsViewModel
    let card: FeedCard
    let categories: [ExpOption]
    @State private var draft: FeedDraft
    @Environment(\.dismiss) private var dismiss

    init(vm: FeedsViewModel, card: FeedCard, categories: [ExpOption]) {
        self.vm = vm
        self.card = card
        self.categories = categories
        _draft = State(initialValue: FeedLogic.draft(of: card))
    }

    private var type: String { card.type ?? "" }
    private var busy: Bool { vm.busy.contains(type) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(FeedLogic.onlyAvailable, isOn: $draft.onlyAvailable)
                    Toggle(FeedLogic.descFallback, isOn: $draft.descFallback)
                    HStack {
                        Text(FeedLogic.markup)
                        Spacer()
                        TextField("0", text: $draft.markup)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    Text(FeedLogic.markupHint)
                }
                .listRowBackground(Brand.card)

                Section(FeedLogic.categories) {
                    NavigationLink {
                        FeedCategoriesPicker(categories: categories, selected: $draft.categories)
                    } label: {
                        HStack {
                            Text(FeedLogic.categories)
                            Spacer()
                            Text(draft.categories.isEmpty ? FeedLogic.categoriesAll : "Выбрано: \(draft.categories.count)")
                                .foregroundColor(Brand.muted)
                        }
                    }
                    .disabled(categories.isEmpty)
                }
                .listRowBackground(Brand.card)

                Section(FeedLogic.utmTitle) {
                    TextField("source", text: $draft.utmSource).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("medium", text: $draft.utmMedium).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("campaign", text: $draft.utmCampaign).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .listRowBackground(Brand.card)

                if type == "avito" {
                    Section(FeedLogic.avitoTitle) {
                        TextField("Категория", text: $draft.avitoCategory)
                        TextField("Вид товара", text: $draft.avitoGoodsType)
                        TextField("Тип объявления", text: $draft.avitoAdType)
                        TextField("Адрес", text: $draft.avitoAddress)
                        TextField("Телефон", text: $draft.avitoPhone)
                        TextField("Менеджер", text: $draft.avitoManager)
                    }
                    .listRowBackground(Brand.card)
                }
                if type == "google_merchant" {
                    Section(FeedLogic.googleTitle) {
                        TextField("Бренд", text: $draft.googleBrand)
                        TextField("Категория Google", text: $draft.googleProductCategory)
                    }
                    .listRowBackground(Brand.card)
                }
                if let e = vm.settingsError {
                    Section { Text(e).font(.footnote).foregroundColor(Brand.red) }
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle((card.title ?? type) + ": " + FeedLogic.settings.lowercased())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FeedLogic.close) { vm.settingsError = nil; dismiss() }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            if await vm.saveOptions(type, draft) { dismiss() }
                        }
                    } label: {
                        if busy { ProgressView() } else { Text(FeedLogic.save) }
                    }
                    .disabled(busy)
                }
            }
        }
        .interactiveDismissDisabled(busy)
    }
}

/// Выбор категорий фида (пусто — все категории).
private struct FeedCategoriesPicker: View {
    let categories: [ExpOption]
    @Binding var selected: Set<String>

    var body: some View {
        List {
            Section {
                Button(FeedLogic.categoriesAll) { selected = [] }
            }
            .listRowBackground(Brand.card)
            Section {
                ForEach(Array(categories.enumerated()), id: \.offset) { _, c in
                    let id = c.value ?? ""
                    if !id.isEmpty {
                        Button {
                            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
                        } label: {
                            HStack {
                                Text(c.label ?? id).foregroundColor(Brand.text)
                                Spacer()
                                if selected.contains(id) { Image(systemName: "checkmark").foregroundColor(Brand.text) }
                            }
                        }
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(FeedLogic.categories)
        .navigationBarTitleDisplayMode(.inline)
    }
}
