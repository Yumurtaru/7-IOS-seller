import SwiftUI

// ============================================================================
//  Отчёты склада — 4 вкладки:
//   • Оценка   — GET /warehouse/valuation (остаток × себестоимость, розница, маржа)
//   • Обороты  — GET /warehouse/analytics?days= (оборачиваемость, ABC, неликвиды)
//   • Списания — GET /warehouse/writeoff-analytics?days= (причины + топ позиций)
//   • Закупить — GET /warehouse/reorder?lead=&days= (дефицит + прогноз спроса)
// ============================================================================

struct WarehouseReportsView: View {
    enum Tab: String, CaseIterable {
        case valuation = "Оценка"
        case turnover = "Обороты"
        case writeoff = "Списания"
        case reorder = "Закупить"
    }

    @State private var tab: Tab = .valuation

    var body: some View {
        VStack(spacing: 0) {
            Picker("Отчёт", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)

            switch tab {
            case .valuation: ValuationTab()
            case .turnover: TurnoverTab()
            case .writeoff: WriteoffTab()
            case .reorder: ReorderTab()
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Отчёты склада")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// ── Оценка запасов ────────────────────────────────────────────────────────────
@MainActor
final class ValuationViewModel: ObservableObject {
    @Published var report: ValuationReport?
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var query = ""
    private var searchTask: Task<Void, Never>?

    // А60/П-23.10: позиции постранично (page/limit), «Показать ещё» по has_more.
    // Итоги (totals) сервер считает по всему складу — берём их с первой страницы.
    @Published var rows: [ValuationRow] = [] {
        // Отбор и сортировка — один раз при смене строк, а не в body: раньше
        // до 2000+ позиций сортировались заново на каждую букву в поле поиска.
        didSet {
            shownRows = rows.filter { ($0.value ?? 0) != 0 }
                .sorted { ($0.value ?? 0) > ($1.value ?? 0) }
        }
    }
    /// Позиции для списка: ненулевые, по убыванию стоимости.
    private(set) var shownRows: [ValuationRow] = []
    @Published var hasMore = false
    @Published var loadingMore = false
    @Published var moreError: String?
    /// Старый сервер страниц не знает и на page=2 отдаёт то же самое — тогда,
    /// как раньше, просим уточнить поиском.
    @Published var pagingUnsupported = false
    private var page = 1
    // 2000 — максимум сервера. В режиме страниц порядок «товары, потом ингредиенты»:
    // с маленькой страницей дорогие ингредиенты кафе не попадали в первую.
    private static let pageSize = 2000

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if report == nil { state = .loading }
        do {
            let fresh = try await API.shared.warehouseValuation(q: query, page: 1, limit: Self.pageSize)
            guard myGen == loadGen else { return }
            report = fresh
            rows = fresh.items ?? []
            hasMore = fresh.hasMore == true
            page = 1
            pagingUnsupported = false
            moreError = nil
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard hasMore, !loadingMore else { return }   // двойной тап — одна страница
        loadingMore = true
        defer { loadingMore = false }
        moreError = nil
        let myGen = loadGen
        let next = page + 1
        do {
            let fresh = try await API.shared.warehouseValuation(q: query, page: next, limit: Self.pageSize)
            guard myGen == loadGen else { return }
            let got = fresh.items ?? []
            // Пустая страница — конец списка.
            if got.isEmpty { hasMore = false; return }
            let have = Set(rows.map(\.id))
            let added = got.filter { !have.contains($0.id) }
            if added.isEmpty { hasMore = false; pagingUnsupported = true; return }
            rows += added
            page = next
            hasMore = fresh.hasMore == true
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            moreError = error.localizedDescription
        }
    }

    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }
}

private struct ValuationTab: View {
    @StateObject private var vm = ValuationViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                TextField("Поиск по названию", text: $vm.query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vm.query) { _ in vm.scheduleSearch() }
                if let r = vm.report {
                    SectionCard {
                        InfoRow(label: "По себестоимости", value: Money.rub(r.total))
                        InfoRow(label: "По розничным ценам", value: Money.rub(r.totals?.retailValue))
                        InfoRow(label: "Потенциальная наценка", value: Money.rub(r.totals?.margin))
                        InfoRow(label: "Позиций", value: "\(r.totals?.qtyPositions ?? (r.items ?? []).count)")
                    }
                    // Список позиций сервер урезает — говорим об этом, иначе
                    // кажется, что остальных позиций на складе нет.
                    if vm.pagingUnsupported {
                        // «из 21 позиций» → «из 21 позиции»: форма слова по числу.
                        let all = r.totalPositions ?? r.totals?.qtyPositions ?? 0
                        let allText = "\(all) " + RuPlural.word(all, "позиции", "позиций", "позиций")
                        Text("Показано \(vm.rows.count) из " + allText + " — уточните поиском.")
                            .font(.caption).foregroundColor(Brand.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    rowsCard(vm.shownRows)
                    // А60/П-23.10: следующая страница позиций.
                    if vm.hasMore {
                        Button {
                            Task { await vm.loadMore() }
                        } label: {
                            HStack(spacing: 8) {
                                Text("Показать ещё").font(.subheadline.weight(.semibold))
                                if vm.loadingMore { ProgressView() }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .disabled(vm.loadingMore)
                    }
                    if let e = vm.moreError {
                        Text(e).font(.caption).foregroundColor(Brand.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: (vm.report?.items ?? []).isEmpty,
                   emptyIcon: "rublesign.circle", emptyTitle: "Позиций нет",
                   // Новый склад: объясняем, откуда возьмётся стоимость.
                   emptySubtitle: vm.query.isEmpty ? "Стоимость склада посчитается после первого прихода товара" : nil,
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }

    private func rowsCard(_ rows: [ValuationRow]) -> some View {
        SectionCard(title: "Позиции (по стоимости)") {
            // Ленивый стек: строки рисуются по мере прокрутки. Обычный VStack
            // строил все 2000 строк сразу — экран открывался и печатал с задержкой.
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name ?? "—")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text).lineLimit(2)
                            Text(QtyFmt.qty(r.qty) + " " + (r.unit ?? "") + " · ср. " + Money.rub(r.avgCost))
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        Text(Money.rub(r.value))
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(Brand.text)
                    }
                    .padding(.vertical, 4)
                    if r.id != rows.last?.id { Divider().overlay(Brand.border) }
                }
            }
        }
    }
}

// ── Обороты по документам ────────────────────────────────────────────────────
@MainActor
final class TurnoverViewModel: ObservableObject {
    @Published var data: WarehouseAnalytics?
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var days = 30

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if data == nil { state = .loading }
        do {
            let fresh = try await API.shared.warehouseAnalytics(days: days)
            guard myGen == loadGen else { return }
            data = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct TurnoverTab: View {
    @StateObject private var vm = TurnoverViewModel()
    private let windows = [7, 30, 90]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(windows, id: \.self) { d in
                        FilterChip(title: "\(d) дн.", selected: vm.days == d) {
                            // Другой период — прежние цифры убираем: при сбое загрузки
                            // «Выручка за период» 30 дней читалась под чипом «7 дн.».
                            if vm.days != d { vm.data = nil }
                            vm.days = d
                            Task { await vm.load() }
                        }
                    }
                    Spacer()
                }
                if let d = vm.data {
                    SectionCard {
                        InfoRow(label: "Выручка за период", value: Money.rub(d.summary?.revenue))
                        InfoRow(label: "Прибыль за период", value: Money.rub(d.summary?.profit))
                        InfoRow(label: "Позиций / группа A", value: "\(d.summary?.positions ?? 0) / \(d.summary?.aCount ?? 0)")
                        InfoRow(label: "Неликвиды (нет продаж)", value: "\(d.summary?.deadCount ?? 0)")
                    }
                    rowsCard(title: "Лидеры продаж (ABC)",
                             Array((d.items ?? []).filter { ($0.revenue ?? 0) > 0 }.prefix(30)))
                    rowsCard(title: "Неликвиды",
                             Array((d.items ?? []).filter { $0.dead == true }.prefix(30)))
                }
            }
            .padding(16)
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "arrow.left.arrow.right", emptyTitle: "Нет данных",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }

    private func subtitle(_ r: TurnoverRow) -> String {
        var parts: [String] = []
        parts.append("остаток " + QtyFmt.qty(r.stockQty) + " " + (r.unit ?? ""))
        parts.append("продано " + QtyFmt.qty(r.soldQty))
        if let c = r.daysCover { parts.append("хватит на " + QtyFmt.qty(c) + " дн.") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func rowsCard(title: String, _ rows: [TurnoverRow]) -> some View {
        if !rows.isEmpty {
            SectionCard(title: title) {
                ForEach(rows) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Text(r.abc ?? "—")
                            .font(.caption.weight(.bold))
                            .foregroundColor(r.abc == "A" ? Brand.green : (r.abc == "D" ? Brand.red : Brand.muted))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.name ?? "—")
                                .font(.subheadline).foregroundColor(Brand.text).lineLimit(2)
                            Text(subtitle(r))
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        Text(Money.rub(r.revenue))
                            .font(.subheadline.weight(.medium)).foregroundColor(Brand.text)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// ── Аналитика списаний ───────────────────────────────────────────────────────
@MainActor
final class WriteoffViewModel: ObservableObject {
    @Published var data: WriteoffAnalytics?
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var days = 30

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if data == nil { state = .loading }
        do {
            let fresh = try await API.shared.writeoffAnalytics(days: days)
            guard myGen == loadGen else { return }
            data = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct WriteoffTab: View {
    @StateObject private var vm = WriteoffViewModel()
    private let windows = [7, 30, 90]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(windows, id: \.self) { d in
                        FilterChip(title: "\(d) дн.", selected: vm.days == d) {
                            if vm.days != d { vm.data = nil }   // не показываем сумму прежнего периода
                            vm.days = d
                            Task { await vm.load() }
                        }
                    }
                    Spacer()
                }
                if let d = vm.data {
                    SectionCard {
                        InfoRow(label: "Списано за период", value: Money.rub(d.total))
                    }
                    reasonsCard(d.byReason ?? [], total: d.total ?? 0)
                    topCard(d.topItems ?? [])
                }
            }
            .padding(16)
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "trash", emptyTitle: "Списаний нет",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }

    @ViewBuilder
    private func reasonsCard(_ rows: [WriteoffReason], total: Decimal) -> some View {
        if !rows.isEmpty {
            SectionCard(title: "По причинам") {
                ForEach(rows) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(WarehouseLabels.writeoffReason(r.reason))
                                .font(.subheadline).foregroundColor(Brand.text)
                            Spacer()
                            Text(Money.rub(r.amount))
                                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.red)
                        }
                        // Простая полоса доли причины — без сторонних чартов.
                        GeometryReader { geo in
                            let share = total > 0 ? (r.amount ?? 0) / total : 0
                            let width = geo.size.width * CGFloat(truncating: share as NSDecimalNumber)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Brand.chip)
                                Capsule().fill(Brand.red.opacity(0.7)).frame(width: max(width, 2))
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func topCard(_ rows: [WriteoffTopItem]) -> some View {
        if !rows.isEmpty {
            SectionCard(title: "Топ списанных позиций") {
                // По номеру строки: товар и ингредиент с одинаковым названием и
                // единицей давали одинаковый id, и строки рисовались неверно.
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack {
                        Text(r.name ?? "—")
                            .font(.subheadline).foregroundColor(Brand.text).lineLimit(1)
                        Spacer()
                        Text(QtyFmt.qty(r.qty) + " " + (r.unit ?? "") + " · " + Money.rub(r.amount))
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// ── Что закупить ─────────────────────────────────────────────────────────────
@MainActor
final class ReorderViewModel: ObservableObject {
    @Published var report: ReorderReport?
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var lead = 7

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if report == nil { state = .loading }
        do {
            let fresh = try await API.shared.warehouseReorder(lead: lead, days: 30)
            guard myGen == loadGen else { return }
            report = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct ReorderTab: View {
    @StateObject private var vm = ReorderViewModel()
    private let leads = [3, 7, 14]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(leads, id: \.self) { l in
                        FilterChip(title: "Поставка \(l) дн.", selected: vm.lead == l) {
                            // Рекомендации зависят от срока поставки: при сбое загрузки
                            // количества «закупить» прежнего срока не оставляем под новым.
                            if vm.lead != l { vm.report = nil }
                            vm.lead = l
                            Task { await vm.load() }
                        }
                    }
                    Spacer()
                }
                if let items = vm.report?.items, !items.isEmpty {
                    SectionCard(title: "Рекомендации (\(vm.report?.count ?? items.count))") {
                        ForEach(items) { r in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(r.name ?? "—")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(Brand.text).lineLimit(2)
                                    Spacer()
                                    // АY (сайт А616): отрицательный остаток — отдельной меткой.
                                    if r.negative == true {
                                        StatusBadge(text: "Ушло в минус", color: Brand.red)
                                    } else if r.belowMin == true {
                                        StatusBadge(text: "ниже минимума", color: Brand.red)
                                    }
                                }
                                HStack {
                                    Text("Остаток \(QtyFmt.qty(r.stockQty)) " + (r.unit ?? ""))
                                        .font(.caption).foregroundColor(Brand.muted)
                                    Spacer()
                                    Text("Закупить ~\(QtyFmt.qty(r.recommend)) " + (r.unit ?? ""))
                                        .font(.caption.weight(.semibold)).foregroundColor(Brand.accent)
                                }
                                // АY: уже заказано и не принято — учтено в «Закупить».
                                if let t = r.inTransit, t > 0 {
                                    Text("В пути: \(QtyFmt.qty(t)) " + (r.unit ?? ""))
                                        .font(.caption).foregroundColor(Brand.amber)
                                }
                                if let s = r.supplier, !s.isEmpty {
                                    Text("Последний поставщик: " + s)
                                        .font(.caption2).foregroundColor(Brand.muted)
                                }
                            }
                            .padding(.vertical, 4)
                            if r.id != items.last?.id { Divider().overlay(Brand.border) }
                        }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: (vm.report?.items ?? []).isEmpty,
                   emptyIcon: "cart.badge.plus", emptyTitle: "Закупать нечего",
                   emptySubtitle: "Дефицита по минимумам и прогнозу спроса нет",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }
}
