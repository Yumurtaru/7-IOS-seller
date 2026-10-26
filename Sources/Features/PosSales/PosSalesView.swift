import SwiftUI

// ============================================================================
//  Продажи с кассы — раздел, которого в приложении не было совсем.
//
//  Два взгляда на один срез: «Позиции» (что продаётся) и «Чеки» (лента с
//  разворотом до состава). Период — быстрые кнопки, они же превращаются в
//  from/to сервера: серверный фильтр принимает только даты, никакого
//  «period=month» там нет.
//
//  Срез строится по orders.source = 'pos'. На базе без этой колонки сервер
//  отвечает 422 с понятным текстом — показываем его как есть, а не «ошибка».
// ============================================================================

/// Период среза. Хранит не даты, а способ их посчитать: иначе экран,
/// открытый вечером, назавтра показывал бы вчерашний «сегодня».
enum PosPeriod: String, CaseIterable, Identifiable {
    case today, week, month, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Сегодня"
        case .week:  return "7 дней"
        case .month: return "30 дней"
        case .all:   return "Всё время"
        }
    }

    /// (from, to) в формате сервера. nil = без ограничения.
    var range: (String?, String?) {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .today: return (DateFmt.ymdMoscow(now), DateFmt.ymdMoscow(now))
        case .week:  return (DateFmt.ymdMoscow(cal.date(byAdding: .day, value: -6, to: now) ?? now), DateFmt.ymdMoscow(now))
        case .month: return (DateFmt.ymdMoscow(cal.date(byAdding: .day, value: -29, to: now) ?? now), DateFmt.ymdMoscow(now))
        case .all:   return (nil, nil)
        }
    }
}

@MainActor
final class PosSalesViewModel: ObservableObject {
    @Published var summary: PosSalesSummary?
    @Published var items: [PosSalesItem] = []
    @Published var receipts: [PosReceipt] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    @Published var period: PosPeriod = .month { didSet { if period != oldValue { Task { await reload() } } } }
    @Published var paid: String? { didSet { if paid != oldValue { Task { await reload() } } } }
    @Published var sort: String = "revenue" { didSet { if sort != oldValue { Task { await loadItems() } } } }
    @Published var query: String = ""

    private var page = 1
    private var hasMore = false
    private var loadingMore = false
    // Позиции тоже постраничные (по 50): без дозагрузки хвост просто терялся.
    private var itemsPage = 1
    /// Запрос, по которому загружена первая страница: догрузка не берёт
    /// недонабранный текст из поля (иначе страница 2 другого поиска).
    private var itemsQuery = ""
    private var itemsHasMore = false
    private var itemsLoadingMore = false
    /// Номер «поколения» запроса позиций: ответ старого фильтра/сортировки,
    /// пришедший позже нового, отбрасывается.
    private var itemsGen = 0
    /// То же для ленты чеков: «Сегодня» → «30 дней», и опоздавший ответ по
    /// сегодняшним чекам ложился под чип «30 дней», а старая догрузка
    /// дописывалась в новый список.
    private var receiptsGen = 0
    /// Позиции не загрузились. Успешная загрузка чеков раньше снимала эту
    /// ошибку, и вкладка «Позиции» без итогов писала «Продаж нет».
    private var itemsFailed = false

    static let paidChips: [(String?, String)] = [(nil, "Все"), ("paid", "Оплачены"), ("unpaid", "Не оплачены")]
    static let sortChips: [(String, String)] = [
        ("revenue", "По выручке"), ("qty", "По количеству"), ("receipts", "По чекам"), ("name", "По названию"),
    ]

    func reload() async {
        if items.isEmpty && receipts.isEmpty { state = .loading }
        await loadItems()
        await loadReceipts(reset: true)
        if case .failed = state {} else { state = .loaded }
    }

    func loadItems() async {
        let (from, to) = period.range
        itemsGen += 1
        let gen = itemsGen
        error = nil
        do {
            let q = query
            let res = try await API.shared.posSales(from: from, to: to, paid: paid,
                                                    q: q.isEmpty ? nil : q, sort: sort)
            guard gen == itemsGen else { return }
            itemsQuery = q
            itemsFailed = false
            summary = res.summary
            items = res.items ?? []
            itemsPage = 1
            itemsHasMore = res.hasMore ?? false
            error = nil
            if case .failed = state { state = .loaded }
        } catch is CancellationError {
        } catch {
            guard gen == itemsGen else { return }
            itemsFailed = true
            state = .failed(error.localizedDescription)
            // Плитки «Выручка / Средний чек / Наличные / Карта» показывают итоги
            // ПРЕЖНЕГО периода, если новый не загрузился: продавец жмёт «Сегодня»
            // на плохом Wi-Fi, запрос падает, чип подсвечен — и цифры за 30 дней
            // читаются как дневная выручка. Поэтому чистим и говорим об ошибке.
            summary = nil
            items = []
            itemsHasMore = false
            // Полоска сверху — только если на экране ещё есть данные (лента
            // чеков): при пустом списке тот же текст уже показывает баннер
            // listState с кнопкой «Повторить», и дублировать его незачем.
            self.error = receipts.isEmpty ? nil : error.localizedDescription
        }
    }

    /// Дозагрузка позиций при прокрутке к последней строке.
    func loadMoreItemsIfNeeded(current: PosSalesItem) async {
        guard itemsHasMore, !itemsLoadingMore, current.id == items.last?.id else { return }
        itemsLoadingMore = true
        defer { itemsLoadingMore = false }
        let gen = itemsGen
        let next = itemsPage + 1
        let (from, to) = period.range
        do {
            let res = try await API.shared.posSales(from: from, to: to, paid: paid,
                                                    q: itemsQuery.isEmpty ? nil : itemsQuery, sort: sort, page: next)
            guard gen == itemsGen else { return }
            let known = Set(items.map(\.id))
            items += (res.items ?? []).filter { !known.contains($0.id) }
            itemsPage = next
            itemsHasMore = res.hasMore ?? false
        } catch {
            // Страница не пришла — номер не двигаем, следующая прокрутка повторит её.
        }
    }

    func loadReceipts(reset: Bool) async {
        if reset { receiptsGen += 1 }
        let gen = receiptsGen
        let target = reset ? 1 : page + 1
        let (from, to) = period.range
        do {
            let res = try await API.shared.posReceipts(page: target, from: from, to: to, paid: paid)
            guard gen == receiptsGen else { return }
            let batch = res.items ?? []
            if reset {
                receipts = batch
            } else {
                let known = Set(receipts.map(\.receiptId))
                receipts += batch.filter { !known.contains($0.receiptId) }
            }
            page = target          // двигаем номер страницы только после успеха
            hasMore = res.hasMore ?? false
            // Успех снимает прежнюю ошибку: иначе красная полоса висела до
            // следующего переключения периода, хотя данные уже пришли.
            if reset && !itemsFailed { error = nil; if case .failed = state { state = .loaded } }
        } catch is CancellationError {
        } catch {
            guard gen == receiptsGen else { return }
            if reset {
                state = .failed(error.localizedDescription)
                receipts = []
                hasMore = false
                self.error = items.isEmpty ? nil : error.localizedDescription
            }
        }
    }

    /// Дозагрузка ленты чеков. Флаг loadingMore не даёт запустить два запроса
    /// на одну и ту же страницу, пока первый ещё в пути.
    func loadMoreIfNeeded(current: PosReceipt) async {
        guard hasMore, !loadingMore, current.receiptId == receipts.last?.receiptId else { return }
        loadingMore = true
        await loadReceipts(reset: false)
        loadingMore = false
    }
}

struct PosSalesView: View {
    @StateObject private var vm = PosSalesViewModel()
    @State private var tab = 0
    @State private var openReceipt: PosReceipt?

    var body: some View {
        VStack(spacing: 0) {
            // Ошибка обновления видна сразу: иначе на экране оставались бы цифры
            // прежнего периода под новым фильтром (см. loadItems()).
            if let err = vm.error { InlineErrorBar(message: err) }
            periodChips
            summaryTiles
            Picker("", selection: $tab) {
                Text("Позиции").tag(0)
                Text("Чеки").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if tab == 0 { itemsList } else { receiptsList }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Продажи с кассы")
        .navigationBarTitleDisplayMode(.inline)
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.reload() } }
        .sheet(item: $openReceipt) { r in
            NavigationStack { PosReceiptView(receiptId: r.receiptId) }
        }
    }

    // ── Период и оплата ─────────────────────────────────────────────────────
    private var periodChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PosPeriod.allCases) { p in
                    FilterChip(title: p.title, selected: vm.period == p) { vm.period = p }
                }
                Divider().frame(height: 20)
                ForEach(PosSalesViewModel.paidChips, id: \.1) { value, title in
                    FilterChip(title: title, selected: vm.paid == value) { vm.paid = value }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // ── Сводка ──────────────────────────────────────────────────────────────
    @ViewBuilder
    private var summaryTiles: some View {
        if let s = vm.summary {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    tile("Чеки", "\(s.receipts ?? 0)")
                    tile("Выручка", Money.rub(s.revenue))
                    tile("Средний чек", Money.rub(s.avgCheck))
                    // Раскладку показываем только если сервер её умеет:
                    // на старой базе там нули, и две пустые плитки только мешают.
                    if s.hasSplit == true {
                        tile("Наличными", Money.rub(s.cash))
                        tile("Картой", Money.rub(s.card))
                    }
                    // Выручка уже за вычетом возвратов, а нал и карта — нет:
                    // показываем возвраты, чтобы шапка сходилась (как на сайте).
                    if let back = s.returned, back > 0 {
                        tile("Возвраты", "−" + Money.rub(back))
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundColor(Brand.muted)
            Text(value).font(.headline).foregroundColor(Brand.text).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minWidth: 110, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // ── Позиции ─────────────────────────────────────────────────────────────
    private var itemsList: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PosSalesViewModel.sortChips, id: \.0) { key, title in
                            FilterChip(title: title, selected: vm.sort == key) { vm.sort = key }
                        }
                    }
                }
                .listRowBackground(Brand.bg)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            ForEach(vm.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name ?? "—").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                        HStack(spacing: 8) {
                            Text(qtyText(item)).font(.caption).foregroundColor(Brand.muted)
                            Text("· чеков: \(item.receipts ?? 0)").font(.caption).foregroundColor(Brand.muted)
                        }
                        // Возвраты прячем, пока их нет: строка «возвращено 0» —
                        // шум в списке, который читают каждый день.
                        if let ret = item.qtyReturned, ret > 0 {
                            Text("возвращено: \(decimalText(ret))").font(.caption2).foregroundColor(Brand.red)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(Money.rub(item.revenue)).font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                }
                .listRowBackground(Brand.card)
                .task { await vm.loadMoreItemsIfNeeded(current: item) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(text: $vm.query, prompt: "Поиск по названию")
        .onSubmit(of: .search) { Task { await vm.loadItems() } }
        // Очистили поиск (крестик/«Отменить») — возвращаем полный список:
        // раньше позиции и итоги оставались отфильтрованными по старому запросу.
        .onChange(of: vm.query) { q in if q.isEmpty { Task { await vm.loadItems() } } }
        .refreshable { await vm.reload() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "cart", emptyTitle: "Продаж нет",
                   emptySubtitle: "За выбранный период касса не пробила ни одного чека",
                   retry: { Task { await vm.reload() } })
    }

    // ── Чеки ────────────────────────────────────────────────────────────────
    private var receiptsList: some View {
        List {
            ForEach(vm.receipts) { r in
                Button { openReceipt = r } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Чек №\(r.dailyNumber ?? r.receiptId)")
                                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                            Text(DateFmt.short(r.createdAt)).font(.caption).foregroundColor(Brand.muted)
                            Text("позиций: \(r.positions ?? 0) · \(payText(r))")
                                .font(.caption2).foregroundColor(Brand.muted)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(Money.rub(r.total)).font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                            StatusBadge(text: r.isPaid ? "Оплачен" : "Не оплачен",
                                        color: r.isPaid ? Brand.green : Brand.amber)
                        }
                    }
                }
                .listRowBackground(Brand.card)
                .task { await vm.loadMoreIfNeeded(current: r) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.loadReceipts(reset: true) }
        .listState(vm.state, isEmpty: vm.receipts.isEmpty,
                   emptyIcon: "receipt", emptyTitle: "Чеков нет",
                   emptySubtitle: "За выбранный период касса не пробила ни одного чека",
                   retry: { Task { await vm.reload() } })
    }

    // ── Текстовки ───────────────────────────────────────────────────────────
    private func qtyText(_ item: PosSalesItem) -> String {
        let unit = (item.unit?.isEmpty == false) ? item.unit! : "шт"
        return "\(decimalText(item.qty ?? 0)) \(unit)"
    }

    /// Количество приходит как "7.000" — хвостовые нули убираем, дробные
    /// (весовой товар) оставляем.
    /// Общий форматтер (QtyFmt) — раньше новый NumberFormatter на каждую строку
    /// при каждой перерисовке длинного списка позиций.
    private func decimalText(_ v: Decimal) -> String {
        QtyFmt.qty(v)
    }

    private func payText(_ r: PosReceipt) -> String {
        switch r.paidMethod {
        case "pay_cash", "cash": return "наличные"
        case "pay_card", "card": return "карта"
        case "mixed":            return "смешанная"
        // Касса пишет paid_method = sbp (stations.php), а payment_type у такого
        // чека может остаться cash — оплата СБП читалась как «Наличные».
        case "sbp":              return "СБП"
        default:                 return PaymentLabels.type(r.paymentType)
        }
    }
}

// ============================================================================
//  Один чек
// ============================================================================

@MainActor
final class PosReceiptViewModel: ObservableObject {
    @Published var receipt: PosReceiptDetail?
    @Published var state: LoadState = .idle

    func load(id: Int) async {
        state = .loading
        do {
            receipt = try await API.shared.posReceipt(id: id)
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct PosReceiptView: View {
    let receiptId: Int
    @StateObject private var vm = PosReceiptViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let r = vm.receipt {
                Section {
                    InfoRow(label: "Чек", value: "№\(r.dailyNumber ?? (r.id ?? 0))")
                    InfoRow(label: "Дата", value: DateFmt.short(r.createdAt))
                    InfoRow(label: "Статус", value: (r.paymentStatus ?? "") == "paid" ? "Оплачен" : "Не оплачен")
                }
                .listRowBackground(Brand.card)

                Section("Позиции") {
                    // Две одинаковые строки чека (два капучино по 200 ₽ с разными
                    // добавками) давали один id «имя-цена-кол-во»: дубли в List
                    // путают строки и могут уронить список. Ключ — номер строки.
                    ForEach(Array((r.items ?? []).enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "—").font(.subheadline).foregroundColor(Brand.text)
                                // Количество тем же форматтером, что в списке позиций:
                                // «0,375», а не «0.375» с точкой.
                                let qtyLine = Money.rub(item.price) + " × " + (item.qty.map { QtyFmt.qty($0) } ?? "1")
                                Text(qtyLine)
                                    .font(.caption).foregroundColor(Brand.muted)
                                if let ret = item.returnQty, ret > 0 {
                                    Text("возврат: " + QtyFmt.qty(ret))
                                        .font(.caption2).foregroundColor(Brand.red)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(Money.rub(item.sum)).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                        }
                    }
                }
                .listRowBackground(Brand.card)

                Section {
                    if let d = r.discount, d > 0 {
                        // Со знаком минус, как скидка в карточке заказа и «Возвраты» в шапке.
                        InfoRow(label: "Скидка", value: "−" + Money.rub(d))
                    }
                    InfoRow(label: "Итого", value: Money.rub(r.total))
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Чек")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        .task { await vm.load(id: receiptId) }
        .listState(vm.state, isEmpty: vm.receipt == nil,
                   emptyIcon: "receipt", emptyTitle: "Чек не найден", emptySubtitle: nil,
                   retry: { Task { await vm.load(id: receiptId) } })
    }
}
