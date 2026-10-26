import SwiftUI

// ============================================================================
//  Остатки склада — GET /api/seller/stock (?q=&low=1&warehouse_id=).
//  Товары и ингредиенты одним списком, фильтр «ниже минимума», выбор склада,
//  деталь позиции: партии (FEFO, сроки годности) + остатки по складам.
// ============================================================================

@MainActor
final class StockViewModel: ObservableObject {
    @Published var items: [StockItem] = []
    @Published var warehouses: [WarehouseInfo] = []
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var query = ""
    @Published var lowOnly = false
    @Published var warehouseId: Int = 0     // 0 = все склады

    private var searchTask: Task<Void, Never>?

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        do {
            async let stock = API.shared.stock(q: query, low: lowOnly, warehouseId: warehouseId)
            // Склады нужны только для фильтра — их отсутствие не роняет экран.
            if warehouses.isEmpty {
                warehouses = (try? await API.shared.warehouses()) ?? []
            }
            let fresh = try await stock
            guard myGen == loadGen else { return }
            items = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// Дебаунс поиска, чтобы не дёргать сервер на каждую букву.
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.load()
        }
    }
}

struct StockView: View {
    @StateObject private var vm = StockViewModel()

    var body: some View {
        VStack(spacing: 0) {
            filters
            List {
                ForEach(vm.items) { item in
                    NavigationLink {
                        StockPositionDetailView(item: item)
                    } label: {
                        StockRow(item: item)
                    }
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Остатки")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $vm.query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Название, артикул или штрихкод")
        .onChange(of: vm.query) { _ in vm.scheduleSearch() }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "shippingbox", emptyTitle: emptyTitle,
                   emptySubtitle: emptySubtitle,
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }

    /// Без поиска и фильтра сервер отдаёт ВСЕ товары и ингредиенты магазина:
    /// пусто — значит их ещё нет (новый магазин), а не «не найдено».
    private var noFilter: Bool {
        vm.query.trimmingCharacters(in: .whitespaces).isEmpty && !vm.lowOnly && vm.warehouseId == 0
    }

    private var emptyTitle: String {
        noFilter ? "На складе пока ничего нет" : "Позиций не найдено"
    }

    private var emptySubtitle: String? {
        if vm.lowOnly { return "Ниже минимума ничего нет — запасы в порядке" }
        if noFilter { return "Здесь будут товары магазина (и ингредиенты кафе) с остатками. Остатки появятся после прихода: «Ещё → Документы склада»." }
        return nil
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Смена фильтра убирает строки прежнего: при сбое загрузки под
                // чипом другого склада оставались остатки прежнего — кладовщик
                // видел чужие цифры как свои.
                FilterChip(title: "Ниже минимума", selected: vm.lowOnly) {
                    vm.lowOnly.toggle()
                    vm.items = []
                    Task { await vm.load() }
                }
                FilterChip(title: "Все склады", selected: vm.warehouseId == 0) {
                    if vm.warehouseId != 0 { vm.items = [] }
                    vm.warehouseId = 0
                    Task { await vm.load() }
                }
                ForEach(vm.warehouses) { w in
                    FilterChip(title: w.name ?? "Склад", selected: vm.warehouseId == w.warehouseId) {
                        if vm.warehouseId != w.warehouseId { vm.items = [] }
                        vm.warehouseId = w.warehouseId
                        Task { await vm.load() }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
}

struct StockRow: View {
    let item: StockItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind == "ingredient" ? "leaf" : "shippingbox")
                .foregroundColor(item.kind == "ingredient" ? Brand.green : Brand.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name ?? "—")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(Brand.text)
                    .lineLimit(2)
                if let a = item.article, !a.isEmpty {
                    Text("Арт. \(a)").font(.caption).foregroundColor(Brand.muted)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(QtyFmt.qty(item.stockQty) + " " + (item.unit ?? ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(item.isLow ? Brand.red : Brand.text)
                if item.minimum > 0 {
                    Text("мин. \(QtyFmt.qty(item.minimum))")
                        .font(.caption2).foregroundColor(Brand.muted)
                }
                if item.isLow {
                    StatusBadge(text: "мало", color: Brand.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// ── Деталь позиции: партии + остатки по складам ──────────────────────────────
@MainActor
final class StockPositionViewModel: ObservableObject {
    @Published var batches: [StockBatch] = []
    @Published var balances: [WarehouseBalance] = []
    @Published var state: LoadState = .idle

    func load(kind: String, id: Int) async {
        state = .loading
        do {
            async let b = API.shared.positionBatches(kind: kind, id: id)
            async let w = API.shared.positionBalances(kind: kind, id: id)
            batches = try await b
            balances = try await w
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct StockPositionDetailView: View {
    let item: StockItem
    @StateObject private var vm = StockPositionViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerCard
                balancesCard
                batchesCard
            }
            .padding(16)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(item.name ?? "Позиция")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load(kind: item.kind ?? "product", id: item.itemId ?? 0) }
        // Пусто — по данным, а не по состоянию: неудачная первая загрузка
        // показывает полноценную ошибку с «Повторить».
        // Пустое состояние не рисуем поверх карточки: шапка и блок партий есть
        // всегда (у новой позиции текст «Нет партий…» налезал на них).
        .listState(vm.state, isEmpty: vm.state != .loaded && vm.batches.isEmpty && vm.balances.isEmpty,
                   emptyIcon: "shippingbox", emptyTitle: "Загрузка…",
                   retry: { Task { await vm.load(kind: item.kind ?? "product", id: item.itemId ?? 0) } })
        .task { await vm.load(kind: item.kind ?? "product", id: item.itemId ?? 0) }
    }

    private var headerCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "Вид", value: item.kind == "ingredient" ? "Ингредиент" : "Товар")
                InfoRow(label: "Остаток", value: QtyFmt.qty(item.stockQty) + " " + (item.unit ?? ""))
                if item.minimum > 0 {
                    InfoRow(label: "Минимум", value: QtyFmt.qty(item.minimum) + " " + (item.unit ?? ""))
                }
                if let a = item.article, !a.isEmpty { InfoRow(label: "Артикул", value: a) }
                if let b = item.barcode, !b.isEmpty { InfoRow(label: "Штрихкод", value: b) }
                if let p = item.pricePerUnit, p > 0 {
                    InfoRow(label: "Себестоимость ед.", value: Money.rub(p))
                }
            }
        }
    }

    @ViewBuilder
    private var balancesCard: some View {
        if !vm.balances.isEmpty {
            SectionCard(title: "По складам") {
                ForEach(vm.balances) { b in
                    HStack {
                        Text((b.name ?? "Склад") + (b.isDefault == true ? " · основной" : ""))
                            .font(.subheadline)
                            .foregroundColor(Brand.text)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(QtyFmt.qty(b.qty) + " " + (item.unit ?? ""))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.text)
                            if let c = b.avgCost, c > 0 {
                                Text("ср. " + Money.rub(c))
                                    .font(.caption2).foregroundColor(Brand.muted)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private var batchesCard: some View {
        SectionCard(title: "Партии (FEFO)") {
            if vm.batches.isEmpty {
                Text("Партий с остатком нет — приходы без партий или до миграции партионного учёта.")
                    .font(.caption).foregroundColor(Brand.muted)
            } else {
                ForEach(vm.batches) { b in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(QtyFmt.qty(b.qty) + " " + (item.unit ?? ""))
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.text)
                            Spacer()
                            Text(Money.rub(b.cost) + "/ед.")
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        HStack(spacing: 6) {
                            if let w = b.warehouse {
                                Text(w).font(.caption).foregroundColor(Brand.muted)
                            }
                            Spacer()
                            expiryBadge(b)
                        }
                    }
                    .padding(.vertical, 4)
                    if b.id != vm.batches.last?.id { Divider().overlay(Brand.border) }
                }
            }
        }
    }

    @ViewBuilder
    private func expiryBadge(_ b: StockBatch) -> some View {
        if let exp = b.expiresAt, !exp.isEmpty {
            let days = b.daysLeft ?? 0
            let color: Color = days < 0 ? Brand.red : (days <= 3 ? Brand.amber : Brand.muted)
            let text: String = days < 0 ? "просрочено" : "до \(DateFmt.day(exp))"
            StatusBadge(text: text, color: color)
        } else {
            Text("без срока").font(.caption2).foregroundColor(Brand.muted)
        }
    }
}

// ── Числа количеств: 3 знака максимум, без хвостовых нулей ───────────────────
enum QtyFmt {
    private static let qtyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"
        f.decimalSeparator = ","
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 3
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    static func qty(_ v: Decimal?) -> String {
        qtyFormatter.string(from: (v ?? 0) as NSDecimalNumber) ?? "0"
    }

    static func percent(_ v: Decimal?) -> String {
        qty(v) + "%"
    }
}
