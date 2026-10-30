import SwiftUI

// ============================================================================
//  Документы склада — приход, списание, перемещение, инвентаризация, возврат.
//  Раздела в приложении не было: остатки было видно, а двигать их — нет.
//
//  Документ создаётся черновиком и остатки НЕ трогает. Двигает их только
//  проведение (отдельная ручка), отмена проведения разворачивает движения
//  обратно. Так устроен сервер, и в интерфейсе это видно явными кнопками.
// ============================================================================

@MainActor
final class DocumentsViewModel: ObservableObject {
    @Published var items: [StockDocument] = []
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var error: String?
    /// Сообщение об успехе с оговоркой (пропущенные строки при проведении, А316).
    @Published var notice: String?
    @Published var busyId: Int?
    // А316: список страницами (page/limit, meta.has_more). Старый сервер — одна страница.
    private static let pageSize = 50
    private var page = 1
    @Published private(set) var hasMore = false
    @Published private(set) var loadingMore = false
    @Published var moreError: String?
    @Published var typeFilter: String? { didSet { if typeFilter != oldValue { items = []; state = .loading; loadGen += 1; Task { await load() } } } }
    @Published var statusFilter: String? { didSet { if statusFilter != oldValue { items = []; state = .loading; loadGen += 1; Task { await load() } } } }

    static let statusChips: [(String?, String)] = [(nil, "Все"), ("draft", "Черновики"), ("posted", "Проведённые")]

    /// keepPages: перечитать уже загруженные страницы (после действия над
    /// документом), а не откатываться к первой. Не больше 5 страниц за раз.
    func load(keepPages: Bool = false) async {
        loadGen += 1
        let myGen = loadGen
        moreError = nil
        if items.isEmpty { state = .loading }
        do {
            let upTo = keepPages ? min(max(1, page), 5) : 1
            var all: [StockDocument] = []
            var more = false
            var p = 0
            while p < upTo {
                p += 1
                let r = try await API.shared.documentsPage(type: typeFilter, status: statusFilter,
                                                           page: p, limit: Self.pageSize)
                guard myGen == loadGen else { return }
                all += r.items
                more = r.hasMore
                if !more { break }
            }
            var seen = Set<Int>()
            items = all.filter { seen.insert($0.docId).inserted }
            page = max(1, p)
            hasMore = more
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Следующая страница — по прокрутке до последней строки.
    func loadMoreIfNeeded(current: StockDocument) async {
        guard hasMore, !loadingMore, current.docId == items.last?.docId else { return }
        await loadMore()
    }

    func loadMore() async {
        guard hasMore, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let myGen = loadGen
        moreError = nil
        do {
            let r = try await API.shared.documentsPage(type: typeFilter, status: statusFilter,
                                                       page: page + 1, limit: Self.pageSize)
            guard myGen == loadGen else { return }
            page += 1
            let known = Set(items.map(\.docId))
            items += r.items.filter { !known.contains($0.docId) }
            hasMore = r.hasMore
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            moreError = error.localizedDescription
        }
    }

    // Кнопки гаснут только к следующему кадру: двойной тап «Провести» слал два
    // запроса (второй — ошибкой поверх проведённого), «Копия» делала две копии.
    // Пока одно действие в пути, второе не начинаем.
    func post(_ d: StockDocument) async {
        guard busyId == nil else { return }
        busyId = d.docId; defer { busyId = nil }
        do {
            let ack = try await API.shared.postDocument(id: d.docId)
            // А316: проведение пропустило блюда, наборы, услуги — называем их.
            notice = ack.skippedLines?.text
            await load(keepPages: true)
        }
        catch {
            self.error = error.localizedDescription
            // Отказ «уже проведён/удалён» (другое устройство) или обрыв связи, когда
            // сервер успел провести: перечитываем, иначе строка оставалась
            // «Черновиком» с кнопкой «Провести», которая снова давала ошибку.
            await load(keepPages: true)
        }
    }

    func cancel(_ d: StockDocument) async {
        guard busyId == nil else { return }
        busyId = d.docId; defer { busyId = nil }
        do { _ = try await API.shared.cancelDocument(id: d.docId); await load(keepPages: true) }
        catch {
            self.error = error.localizedDescription
            await load(keepPages: true)   // то же для отмены проведения и черновика
        }
    }

    func duplicate(_ d: StockDocument) async {
        guard busyId == nil else { return }
        busyId = d.docId; defer { busyId = nil }
        do { _ = try await API.shared.duplicateDocument(id: d.docId); await load(keepPages: true) }
        catch { self.error = error.localizedDescription }
    }
}

struct DocumentsView: View {
    @StateObject private var vm = DocumentsViewModel()
    @State private var creating: DocType?
    @State private var openDoc: StockDocument?
    @State private var cancelTarget: StockDocument?
    /// А316: отмена черновика (status → cancelled, без движений) — с вопросом.
    @State private var draftCancelTarget: StockDocument?

    var body: some View {
        VStack(spacing: 0) {
            filters
            List {
                ForEach(vm.items) { d in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: d.docType.icon).foregroundColor(Brand.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(d.docType.title) \(d.number ?? "")")
                                    .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                                Text(DateFmt.short(d.createdAt)).font(.caption).foregroundColor(Brand.muted)
                                if let s = d.supplier, !s.isEmpty {
                                    Text(s).font(.caption2).foregroundColor(Brand.muted)
                                }
                                // А99: накладная поставщика № и дата (старый сервер их не шлёт).
                                if let n = ReceiptMath.supplierDocText(no: d.supplierDocNo, date: d.supplierDocDate) {
                                    Text(n).font(.caption2).foregroundColor(Brand.muted)
                                }
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(Money.rub(d.totalAmount)).font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                                // Паритет с Android: отменённый документ (status = cancelled,
                                // после «Отменить проведение») подписывался «Черновиком».
                                StatusBadge(text: d.isPosted ? "Проведён" : (d.status == "cancelled" ? "Отменён" : "Черновик"),
                                            color: d.isPosted ? Brand.green : (d.status == "cancelled" ? Brand.red : Brand.amber))
                            }
                        }
                        HStack(spacing: 12) {
                            Button("Состав") { openDoc = d }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                            // Проведение двигает остатки, отмена возвращает их
                            // назад — оба действия закрыты своими правами внутри
                            // «Документов склада».
                            if d.isPosted {
                                if Session.shared.can("documents.cancel") {
                                    // Откат движений склада — с вопросом: кнопка стоит
                                    // вплотную к «Составу», и промах сразу менял остатки.
                                    Button("Отменить проведение") { cancelTarget = d }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.borderless)
                                        .foregroundColor(Brand.red)
                                }
                            } else if d.status != "cancelled" && Session.shared.can("documents.post") {
                                // Отменённый документ сервер не проводит (только черновик) —
                                // кнопка давала ошибку; на Android её у отменённых нет.
                                Button("Провести") { Task { await vm.post(d) } }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.borderless)
                                    .foregroundColor(Brand.green)
                            }
                            Button("Копия") { Task { await vm.duplicate(d) } }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.borderless)
                            // А316: черновик можно отменить — право то же, что у отмены проведения.
                            if !d.isPosted && d.status != "cancelled" && Session.shared.can("documents.cancel") {
                                Button("Отменить черновик") { draftCancelTarget = d }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.borderless)
                                    .foregroundColor(Brand.red)
                            }
                        }
                        // Пока идёт действие по любому документу, кнопки остальных тоже
                        // неактивны: нажатие на них молча отбрасывалось.
                        .disabled(vm.busyId != nil)
                    }
                    .padding(.vertical, 2)
                    .listRowBackground(Brand.card)
                    .task { await vm.loadMoreIfNeeded(current: d) }
                }
                if vm.loadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Brand.card)
                } else if let err = vm.moreError, !vm.items.isEmpty {
                    Button { Task { await vm.loadMore() } } label: {
                        Text("Не загрузилось: \(err) · Повторить")
                            .font(.footnote.weight(.semibold)).foregroundColor(Brand.red)
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Brand.card)
                } else if vm.hasMore {
                    Button { Task { await vm.loadMore() } } label: {
                        Text("Показать ещё").font(.footnote.weight(.semibold)).foregroundColor(Brand.accent)
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "doc.text", emptyTitle: "Документов нет",
                       emptySubtitle: "Приход, списание, перемещение, инвентаризация и возврат поставщику",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Документы склада")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(DocType.allCases) { t in
                        Button { creating = t } label: { Label(t.title, systemImage: t.icon) }
                    }
                } label: { Image(systemName: "plus") }
            }
        }
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.load() } }
        .sheet(item: $creating) { t in
            NavigationStack {
                DocumentEditView(type: t, onSaved: { Task { await vm.load() } },
                                 // Окно ещё закрывается — сообщение показываем после него.
                                 onNotice: { text in
                                     DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { vm.notice = text }
                                 })
            }
        }
        .sheet(item: $openDoc) { d in
            NavigationStack { DocumentDetailView(docId: d.docId) }
        }
        .confirmationDialog(
            "Отменить проведение?",
            isPresented: Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } }),
            titleVisibility: .visible,
            presenting: cancelTarget
        ) { d in
            Button("Отменить проведение", role: .destructive) {
                cancelTarget = nil
                Task { await vm.cancel(d) }
            }
            Button("Не отменять", role: .cancel) { cancelTarget = nil }
        } message: { _ in
            Text("Движения документа по складу будут развёрнуты обратно — остатки изменятся.")
        }
        .confirmationDialog(
            "Отменить черновик?",
            isPresented: Binding(get: { draftCancelTarget != nil }, set: { if !$0 { draftCancelTarget = nil } }),
            titleVisibility: .visible,
            presenting: draftCancelTarget
        ) { d in
            Button("Отменить черновик", role: .destructive) {
                draftCancelTarget = nil
                Task { await vm.cancel(d) }
            }
            Button("Не отменять", role: .cancel) { draftCancelTarget = nil }
        } message: { _ in
            Text("Черновик станет «Отменён» — провести его будет нельзя. Остатки не меняются.")
        }
        .alert("Готово", isPresented: Binding(get: { vm.notice != nil && vm.error == nil }, set: { if !$0 { vm.notice = nil } })) {
            Button("Понятно", role: .cancel) { vm.notice = nil }
        } message: { Text(vm.notice ?? "") }
        .alert("Не получилось", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("Понятно", role: .cancel) { vm.error = nil }
        } message: { Text(vm.error ?? "") }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "Все типы", selected: vm.typeFilter == nil) { vm.typeFilter = nil }
                ForEach(DocType.allCases) { t in
                    FilterChip(title: t.title, selected: vm.typeFilter == t.rawValue) { vm.typeFilter = t.rawValue }
                }
                Divider().frame(height: 20)
                ForEach(DocumentsViewModel.statusChips, id: \.1) { value, title in
                    FilterChip(title: title, selected: vm.statusFilter == value) { vm.statusFilter = value }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

// ── Состав документа ─────────────────────────────────────────────────────────

@MainActor
final class DocumentDetailViewModel: ObservableObject {
    @Published var doc: StockDocumentDetail?
    @Published var state: LoadState = .idle

    func load(id: Int) async {
        state = .loading
        do { doc = try await API.shared.document(id: id); state = .loaded }
        catch is CancellationError {}
        catch { state = .failed(error.localizedDescription) }
    }
}

struct DocumentDetailView: View {
    let docId: Int
    @StateObject private var vm = DocumentDetailViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let d = vm.doc {
                Section {
                    InfoRow(label: "Тип", value: d.docType.title)
                    InfoRow(label: "Номер", value: d.number ?? "—")
                    // Паритет с Android: отменённый — «Отменён», а не «Черновик».
                    InfoRow(label: "Статус", value: d.isPosted ? "Проведён" : (d.status == "cancelled" ? "Отменён" : "Черновик"))
                    InfoRow(label: "Создан", value: DateFmt.short(d.createdAt))
                    if d.isPosted { InfoRow(label: "Проведён", value: DateFmt.short(d.postedAt)) }
                    // А99: накладная поставщика № и дата.
                    if let n = ReceiptMath.supplierDocText(no: d.supplierDocNo, date: d.supplierDocDate) {
                        InfoRow(label: "Накладная поставщика", value: String(n.dropFirst("Накладная ".count)))
                    }
                    if let c = d.comment, !c.isEmpty { InfoRow(label: "Комментарий", value: c) }
                }
                .listRowBackground(Brand.card)

                Section("Позиции") {
                    ForEach(d.items ?? []) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                            // У инвентаризации показываем план/факт/расхождение:
                            // ради него документ и заводят.
                            if d.docType.isInventory {
                                // Излишек со знаком «+»: «разница 3» не говорило, больше или меньше.
                                let diff = item.qtyDiff ?? 0
                                let diffText = (diff > 0 ? "+" : "") + qty(diff)
                                Text("план \(qty(item.qtyPlan)) · факт \(qty(item.qtyFact)) · разница " + diffText)
                                    .font(.caption).foregroundColor((item.qtyDiff ?? 0) == 0 ? Brand.muted : Brand.red)
                            } else {
                                Text("\(qty(item.qtyFact)) \(item.unit ?? "") × \(Money.rub(item.price))")
                                    .font(.caption).foregroundColor(Brand.muted)
                            }
                            if let r = item.reason, !r.isEmpty {
                                Text(DocWriteoffReason(rawValue: r)?.title ?? r)
                                    .font(.caption2).foregroundColor(Brand.muted)
                            }
                        }
                    }
                }
                .listRowBackground(Brand.card)

                Section {
                    InfoRow(label: "Итого", value: Money.rub(d.totalAmount))
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Документ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        .task { await vm.load(id: docId) }
        .listState(vm.state, isEmpty: vm.doc == nil,
                   emptyIcon: "doc.text", emptyTitle: "Документ не найден", emptySubtitle: nil,
                   retry: { Task { await vm.load(id: docId) } })
    }

    /// Общий форматтер вместо нового NumberFormatter на каждую строку состава.
    private func qty(_ v: Decimal?) -> String {
        QtyFmt.qty(v)
    }
}
