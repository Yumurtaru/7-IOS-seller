import SwiftUI

// ============================================================================
//  «Отчёт по продажам» (волна А82) — GET /api/seller/sales-report:
//  деньги по способам оплаты (наличные, карта, QR, онлайн), дни, часы, каналы,
//  кассы, скидки, возвраты, сравнение с прошлым периодом и выгрузка в Excel
//  (GET /api/seller/sales-report/export?format=xlsx — те же параметры).
//  Тексты — как в кабинете (seller/sales-report.php, seller-sales-report.js).
//  Право — «Аналитика и отчёты» (analytics).
// ============================================================================

@MainActor
final class SalesReportViewModel: ObservableObject {
    @Published var data: SalesReport?
    @Published var state: LoadState = .idle
    @Published private(set) var loading = false
    @Published var sel = SRPeriodSel(code: "7days") {
        didSet {
            guard sel != oldValue else { return }
            if let f = sel.from, let t = sel.to, t < f { sel.to = f }
            Task { await load() }
        }
    }
    /// nil — все кассы.
    @Published var stationId: Int? {
        didSet { if stationId != oldValue { Task { await load() } } }
    }
    /// Список касс для фильтра — из первого ответа, где их больше одной (как на сайте).
    @Published private(set) var stationChoices: [SalesStation] = []

    @Published var exportBusy = false
    @Published var exportError: String?
    @Published var shareFile: ShareFile?

    /// Номер запроса: ответ по прежнему периоду, пришедший позже нового, не рисуем.
    private var gen = 0
    /// Параметры, по которым показаны data: сбой на другом периоде/кассе не
    /// должен оставлять прежние цифры под новым чипом.
    private var shownQuery: [String: String]?

    /// nil — свой период без обеих дат: запрос не шлём.
    var query: [String: String]? {
        guard var q = sel.query else { return nil }
        if let s = stationId { q["station_id"] = String(s) }
        return q
    }

    func load() async {
        gen += 1
        let my = gen
        guard let q = query else {
            // Ждём вторую дату; ответ по прежнему периоду, если он ещё идёт, не рисуем.
            loading = false
            if data == nil { state = .idle }
            return
        }
        if data == nil { state = .loading }
        loading = true
        let r = await SR.fetch { try await API.shared.salesReport(q) }
        guard my == gen else { return }
        loading = false
        switch r {
        case .ok(let d):
            data = d
            shownQuery = q
            state = .loaded
            if stationChoices.isEmpty && d.stations.count > 1 { stationChoices = d.stations }
            SalesReportFeature.shared.note(sales: true, shop: Session.shared.activeShopId)
        case .hidden(let text), .failed(let text):
            // Прежние цифры другого периода под новым чипом не оставляем (как Android).
            if q != shownQuery { data = nil; shownQuery = nil }
            state = .failed(text)
        case .cancelled:
            break
        }
    }

    func exportXlsx() async {
        guard !exportBusy, let q = query else { return }
        exportBusy = true
        defer { exportBusy = false }
        exportError = nil
        do {
            shareFile = ShareFile(url: try await API.shared.exportSalesReportXlsx(q))
        } catch is CancellationError {
        } catch {
            exportError = error.localizedDescription
        }
    }
}

struct SalesReportView: View {
    @EnvironmentObject var session: Session
    @StateObject private var vm = SalesReportViewModel()
    @ObservedObject private var feature = SalesReportFeature.shared

    private let methodOrder = ["cash", "card", "sbp", "online", "pending"]
    private let methodTitles = ["cash": "Наличные", "card": "Карта", "sbp": "QR", "online": "Онлайн", "pending": "Ждёт оплаты"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SRPeriodBar(sel: $vm.sel)
                // А88: статья базы знаний «Отчёт по продажам».
                HelpLink(path: "help/otchet-po-prodazham")
                if vm.stationChoices.count > 1 { stationMenu }
                if let d = vm.data {
                    header(d)
                    tiles(d)
                    daysChartCard(d)
                    methodsCard(d)
                    hoursCard(d)
                    discountsCard(d)
                    channelsCard(d)
                    stationsCard(d)
                    daysTableCard(d)
                    Text("Выручка — без чаевых и за вычетом возвратов, как на дашборде и в «Аналитике». Способ оплаты — как реально взяли деньги: чек кассы (в том числе смешанная оплата) или способ, который выбрал клиент. «Ждёт оплаты» — оплата при получении, ещё не внесённая. * Продажи по часам, каналам и кассам — до возвратов. Наличные здесь — по чекам периода; сверка ящика — в закрытии смены (там внесения, изъятия и время оплаты).")
                        .font(.caption2)
                        .foregroundColor(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Отчёт по продажам")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await vm.exportXlsx() }
                } label: {
                    if vm.exportBusy {
                        ProgressView()
                    } else {
                        Label("Excel", systemImage: "tablecells").labelStyle(.titleAndIcon)
                    }
                }
                .disabled(vm.exportBusy || vm.data == nil || vm.query == nil)
            }
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "banknote", emptyTitle: "Нет данных за период.",
                   retry: { Task { await vm.load() } })
        .task { if vm.state != .loaded { await vm.load() } }
        .sheet(item: $vm.shareFile) { file in
            ShareSheet(items: [file.url])
        }
        .errorAlert($vm.exportError)
    }

    // ── Фильтр кассы ─────────────────────────────────────────────────────────
    private var stationMenu: some View {
        let current = vm.stationChoices.first { $0.stationId != nil && $0.stationId == vm.stationId }
        return Menu {
            Button("Все кассы") { vm.stationId = nil }
            ForEach(Array(vm.stationChoices.enumerated()), id: \.offset) { _, st in
                if let id = st.stationId {
                    Button(st.name ?? "Касса") { vm.stationId = id }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                Text(vm.stationId == nil ? "Все кассы" : (current?.name ?? "Касса"))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.caption)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Brand.chip)
            .foregroundColor(Brand.text)
            .clipShape(Capsule())
        }
    }

    // ── Подпись периода ──────────────────────────────────────────────────────
    private func header(_ d: SalesReport) -> some View {
        let p = d.period
        var line = joinedNonEmpty([p?.label, "\(DateFmt.day(p?.from)) — \(DateFmt.day(p?.to))"], separator: " · ")
        if let days = p?.days {
            line += ". Сравнение — с предыдущими \(days) дн." + (d.compare?.sameTime == true ? " до того же часа" : "")
        }
        return HStack(spacing: 8) {
            Text(line)
                .font(.footnote)
                .foregroundColor(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if vm.loading { ProgressView() }
        }
    }

    // ── Плитки ───────────────────────────────────────────────────────────────
    private func joined(_ parts: [Text?]) -> Text? {
        let present = parts.compactMap { $0 }
        guard var out = present.first else { return nil }
        for t in present.dropFirst() { out = out + Text(" ") + t }
        return out
    }

    private func tiles(_ d: SalesReport) -> some View {
        let s = d.summary
        let c = d.compare
        var returnsSub = "\(s?.returnsCount ?? 0) шт. по чекам периода · оформлено за период " + SR.rub(s?.returnsCreatedInPeriod)
        if (s?.returnsBonus ?? 0) > 0 { returnsSub += " · баллами " + SR.rub(s?.returnsBonus) }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            SRMetricTile(label: "Выручка", value: SR.rub(s?.revenue),
                         sub: joined([SR.pctText(c?.revenuePct), Text("было " + SR.rub(c?.prevRevenue))]))
            SRMetricTile(label: "Чеков", value: "\(s?.orders ?? 0)",
                         sub: SR.pctText(c?.ordersPct))
            SRMetricTile(label: "Средний чек", value: SR.rub(s?.avgCheck),
                         sub: joined([SR.pctText(c?.avgCheckPct), Text("до возвратов")]))
            SRMetricTile(label: "Наличные", value: SR.rub(s?.cash),
                         sub: joined([Text("по чекам за вычетом наличных возвратов: " + SR.rub(s?.cashNet)), SR.pctText(c?.cashPct)]))
            SRMetricTile(label: "Безналичные", value: SR.rub(s?.cashless),
                         sub: joined([Text("карта, QR, онлайн"), SR.pctText(c?.cashlessPct)]))
            SRMetricTile(label: "Возвраты", value: SR.rub(s?.returns), sub: Text(returnsSub))
        }
    }

    // ── По дням и способам оплаты (стопка) ───────────────────────────────────
    @ViewBuilder
    private func daysChartCard(_ d: SalesReport) -> some View {
        SectionCard(title: "По дням и способам оплаты") {
            if d.byDay.isEmpty {
                Text("Нет данных за период.").font(.subheadline).foregroundColor(Brand.muted)
            } else {
                SRBars(columns: d.byDay.map { day in
                    SRBarColumn(label: SR.dShort(day.date),
                                parts: methodOrder.map { (SR.double(day.amount($0)), SR.methodColor($0)) },
                                accessibility: SR.dShort(day.date) + ": " + SR.rub(day.revenue))
                }, height: 170)
                // Итоги периода по способам — текстом в легенде (паритет с Android).
                SRLegend(items: methodOrder.map { code in
                    let total = d.byDay.reduce(Decimal(0)) { $0 + $1.amount(code) }
                    return ((methodTitles[code] ?? code) + " " + SR.rub(total), SR.methodColor(code))
                })
            }
        }
    }

    // ── Способы оплаты: кольцо + список ──────────────────────────────────────
    private func methodsCard(_ d: SalesReport) -> some View {
        let paid = d.methods.filter { ($0.amount ?? 0) > 0 }
        let rows = d.methods.filter { ($0.amount ?? 0) > 0 || $0.code == "cash" || $0.code == "card" }
        return SectionCard(title: "Способы оплаты") {
            if !paid.isEmpty {
                HStack {
                    Spacer()
                    SRDonut(parts: paid.map { (SR.double($0.amount), SR.methodColor($0.code)) })
                        .frame(width: 170, height: 170)
                    Spacer()
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, m in
                if i > 0 { Divider().overlay(Brand.border) }
                HStack(alignment: .top, spacing: 8) {
                    SRSwatch(color: SR.methodColor(m.code)).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.label ?? m.code ?? "—").font(.subheadline).foregroundColor(Brand.text)
                        Text(methodSub(m)).font(.caption).foregroundColor(Brand.muted)
                    }
                    Spacer(minLength: 8)
                    Text(Money.rub(m.amount))
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Brand.text)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func methodSub(_ m: SalesMethod) -> String {
        var s = "\(m.orders ?? 0) чек. · " + SR.number(m.share ?? 0) + "%"
        if (m.refunds ?? 0) > 0 { s += " · возвраты " + SR.rub(m.refunds) }
        return s
    }

    // ── По часам ─────────────────────────────────────────────────────────────
    private func hoursCard(_ d: SalesReport) -> some View {
        let active = d.byHour.filter { ($0.sales ?? 0) > 0 }
        return SectionCard(title: "По часам") {
            if d.byHour.isEmpty {
                Text("Нет данных за период.").font(.subheadline).foregroundColor(Brand.muted)
            } else {
                SRBars(columns: d.byHour.map { (h: SalesHour) -> SRBarColumn in
                    let label = "\(h.hour ?? 0):00"
                    return SRBarColumn(label: label, parts: [(SR.double(h.sales), SR.hours)],
                                       accessibility: label + ": " + SR.rub(h.sales))
                }, height: 130, maxLabels: 6)
                // Суммы текстом — только часы с продажами.
                if !active.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)],
                              alignment: .leading, spacing: 4) {
                        ForEach(Array(active.enumerated()), id: \.offset) { _, h in
                            Text("\(h.hour ?? 0):00 — " + SR.rub(h.sales))
                                .font(.caption2)
                                .foregroundColor(Brand.text)
                        }
                    }
                }
            }
            Text("Когда идут продажи — под это стоит планировать смены и заготовки.")
                .font(.caption2).foregroundColor(Brand.muted)
        }
    }

    // ── Скидки и прочее ──────────────────────────────────────────────────────
    private func discountsCard(_ d: SalesReport) -> some View {
        let s = d.summary
        let rows: [(String, Decimal?, String?)] = [
            ("Скидки всего", s?.discountTotal, nil),
            ("— по акциям и промокодам", s?.discountPromo, nil),
            ("— ручные (кассир)", s?.discountManual, "\(s?.discountManualOrders ?? 0) чек."),
            ("Оплачено баллами", s?.pointsSpent, nil),
            ("Оплачено сертификатами", s?.giftcardsRedeemed, "всё заведение"),
            ("Ждёт оплаты", s?.pending, nil),
            ("Чаевые", s?.tips, nil),
            ("Доставка", s?.delivery, nil),
            ("Сервисный сбор", s?.serviceFee, nil),
        ]
        let showLossLink = (s?.discountManual ?? 0) > 0 && session.can("security") && feature.loss
        return SectionCard(title: "Скидки и прочее") {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(alignment: .firstTextBaseline) {
                    (Text(r.0).foregroundColor(Brand.text)
                        + Text(r.2.map { " " + $0 } ?? "").font(.caption2).foregroundColor(Brand.muted))
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    Text(Money.rub(r.1)).font(.subheadline).foregroundColor(Brand.text)
                }
            }
            if showLossLink {
                NavigationLink { LossControlView() } label: {
                    Text("Крупные ручные скидки — в «Контроле потерь» →")
                        .font(.caption)
                        .foregroundColor(Brand.accent)
                }
            }
        }
    }

    // ── Каналы и кассы ───────────────────────────────────────────────────────
    private func amountRow(_ title: String, _ sales: Decimal?, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                Text(sub).font(.caption).foregroundColor(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(SR.rub(sales)).font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                Text("Продажи*").font(.caption2).foregroundColor(Brand.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func channelsCard(_ d: SalesReport) -> some View {
        SectionCard(title: "Каналы продаж") {
            if d.channels.isEmpty {
                Text("Нет данных за период.").font(.subheadline).foregroundColor(Brand.muted)
            }
            ForEach(Array(d.channels.enumerated()), id: \.offset) { i, x in
                if i > 0 { Divider().overlay(Brand.border) }
                amountRow(x.label ?? x.code ?? "—", x.sales,
                          "Чеков \(x.orders ?? 0) · Наличные " + SR.rub(x.cash) + " · Безнал " + SR.rub(x.cashless)
                          + " · Ср. чек " + SR.rub(x.avgCheck))
            }
        }
    }

    private func stationsCard(_ d: SalesReport) -> some View {
        SectionCard(title: "Кассы") {
            if d.stations.isEmpty {
                Text("Чеков с касс за период нет.").font(.subheadline).foregroundColor(Brand.muted)
            }
            ForEach(Array(d.stations.enumerated()), id: \.offset) { i, x in
                if i > 0 { Divider().overlay(Brand.border) }
                amountRow(x.name ?? "Касса", x.sales,
                          "Чеков \(x.orders ?? 0) · Нал " + SR.rub(x.cash) + " · Карта " + SR.rub(x.card)
                          + " · QR " + SR.rub(x.sbp))
            }
        }
    }

    // ── По дням (таблица кабинета — строками, свежие сверху) ─────────────────
    private func daysTableCard(_ d: SalesReport) -> some View {
        let days = Array(d.byDay.reversed())
        return SectionCard(title: "По дням") {
            if days.isEmpty {
                Text("Нет данных за период.").font(.subheadline).foregroundColor(Brand.muted)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, x in
                    if i > 0 { Divider().overlay(Brand.border) }
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DateFmt.day(x.date)).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                            Text(daySub(x)).font(.caption).foregroundColor(Brand.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Text(SR.rub(x.revenue)).font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func daySub(_ x: SalesDay) -> String {
        var parts = ["Чеков \(x.orders ?? 0)"]
        let cols: [(String, Decimal?)] = [("Наличные", x.cash), ("Карта", x.card), ("QR", x.sbp),
                                          ("Онлайн", x.online), ("Ждёт", x.pending)]
        for (title, v) in cols where (v ?? 0) > 0 { parts.append(title + " " + SR.rub(v)) }
        parts.append("Возвраты " + ((x.returns ?? 0) > 0 ? SR.rub(x.returns) : "—"))
        return parts.joined(separator: " · ")
    }
}
