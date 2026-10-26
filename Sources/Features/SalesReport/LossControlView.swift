import SwiftUI

// ============================================================================
//  «Контроль потерь» (волна А82) — GET /api/seller/loss-control?period=…&rule=:
//  индекс риска 0–100, показатели, динамика, сотрудники и кассы с нетипично
//  частыми операциями и лента подозрительных операций с советом, что проверить.
//  Тексты — как в кабинете (seller/loss-control.php, seller-sales-report.js).
//  Право — «Безопасность» (security).
// ============================================================================

@MainActor
final class LossControlViewModel: ObservableObject {
    @Published var data: LossControl?
    @Published var state: LoadState = .idle
    @Published private(set) var loading = false
    /// По умолчанию 30 дней, как на сайте.
    @Published var sel = SRPeriodSel(code: "30days") {
        didSet {
            guard sel != oldValue else { return }
            if let f = sel.from, let t = sel.to, t < f { sel.to = f }
            // Новый период — фильтр операций сбрасываем (как на сайте). Свой период
            // без обеих дат ещё не выбран: фильтр оставляем к показанным данным.
            if sel.query != nil { rule = "" }
            Task { await load() }
        }
    }
    /// "" — все операции; иначе код правила (параметр rule).
    @Published private(set) var rule = ""
    /// Лента до 300 операций — показываем порциями.
    @Published var visible = 50

    /// Номер запроса: ответ по прежнему периоду или фильтру не рисуем.
    private var gen = 0
    /// Параметры (период + rule), по которым показаны data.
    private var shownQuery: [String: String]?

    func setRule(_ r: String) {
        guard r != rule else { return }
        rule = r
        Task { await load() }
    }

    func load() async {
        gen += 1
        let my = gen
        guard var q = sel.query else {
            // Свой период: ждём обе даты; запоздалый ответ прежнего периода не рисуем.
            loading = false
            if data == nil { state = .idle }
            return
        }
        if !rule.isEmpty { q["rule"] = rule }
        if data == nil { state = .loading }
        loading = true
        let r = await SR.fetch { try await API.shared.lossControl(q) }
        guard my == gen else { return }
        loading = false
        switch r {
        case .ok(let d):
            data = d
            shownQuery = q
            visible = 50
            state = .loaded
            SalesReportFeature.shared.note(loss: true, shop: Session.shared.activeShopId)
        case .hidden(let text), .failed(let text):
            // Прежние цифры другого периода/фильтра под новым чипом не оставляем (как Android).
            if q != shownQuery { data = nil; shownQuery = nil }
            state = .failed(text)
        case .cancelled:
            break
        }
    }
}

struct LossControlView: View {
    @EnvironmentObject var session: Session
    @StateObject private var vm = LossControlViewModel()

    /// Порядок правил — как в таблице API (словарь JSON порядка не хранит).
    private static let ruleOrder = ["big_refund", "no_receipt", "void_paid", "after_prebill", "pin", "shortage",
                                    "manual_discount", "drawer_often", "free_price", "night", "offline", "surplus",
                                    "unpaid_issued", "paid_reduced", "big_cash_out", "outlier"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SRPeriodBar(sel: $vm.sel)
                // А88: статья базы знаний «Контроль потерь».
                HelpLink(path: "help/kontrol-poter")
                if let d = vm.data {
                    if d.enabled == false {
                        SectionCard {
                            Text("Журнал безопасности не включён — операции кассы не записываются.")
                                .font(.subheadline).foregroundColor(Brand.text)
                        }
                    } else {
                        content(d)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Контроль потерь")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if vm.loading && vm.data != nil { ProgressView() }
            }
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "checkmark.shield", emptyTitle: "Подозрительных операций нет — хороший знак.",
                   retry: { Task { await vm.load() } })
        .task { if vm.state != .loaded { await vm.load() } }
    }

    @ViewBuilder
    private func content(_ d: LossControl) -> some View {
        indexCard(d)
        trendCard(d)
        if d.truncated == true {
            Text("Операций за период очень много: поштучно разобраны последние \(SR.number(Double(d.rowsLimit ?? 0))). Итоги ниже — точные; для разбора по людям выберите период короче.")
                .font(.footnote)
                .foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SR.warning.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        kpiGrid(d)
        actorsCard(d)
        incidentsCard(d)
        rulesCard(d)
    }

    // ── Индекс риска ─────────────────────────────────────────────────────────
    private func indexCard(_ d: LossControl) -> some View {
        SectionCard {
            HStack {
                Spacer()
                SRGauge(index: d.index, level: d.level, width: 200)
                Spacer()
            }
            Text(d.levelLabel ?? "")
                .font(.title3.weight(.heavy))
                .foregroundColor(SR.levelColor(d.level))
            (Text("Критичных: ") + Text("\(d.counts?.critical ?? 0)").fontWeight(.bold)
                + Text(" · требуют внимания: ") + Text("\(d.counts?.warning ?? 0)").fontWeight(.bold))
                .font(.subheadline)
                .foregroundColor(Brand.text)
            Text("Индекс риска 0–100: критичная операция — 10 баллов, требующая внимания — 3 (за период длиннее месяца — в пересчёте на 30 дней). Каждая — не обвинение, а повод проверить: чек, видео, смену.")
                .font(.caption)
                .foregroundColor(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── Динамика (критично + внимание стопкой) ───────────────────────────────
    private func trendCard(_ d: LossControl) -> some View {
        let crit = d.trend.reduce(0) { $0 + ($1.critical ?? 0) }
        let warn = d.trend.reduce(0) { $0 + ($1.warning ?? 0) }
        return SectionCard(title: "Динамика") {
            if d.trend.isEmpty {
                Text("Нет данных за период.").font(.subheadline).foregroundColor(Brand.muted)
            } else {
                SRBars(columns: d.trend.map { (t: LossTrend) -> SRBarColumn in
                    let label = SR.dShort(t.date)
                    return SRBarColumn(label: label,
                                       parts: [(Double(t.critical ?? 0), SR.critical), (Double(t.warning ?? 0), SR.warning)],
                                       accessibility: label + ": Критично \(t.critical ?? 0) · Внимание \(t.warning ?? 0)")
                }, height: 120)
                // Итоги за период — текстом в легенде (паритет с Android).
                SRLegend(items: [("Критично \(crit)", SR.critical), ("Внимание \(warn)", SR.warning)])
            }
        }
    }

    // ── Показатели ───────────────────────────────────────────────────────────
    private func kpiGrid(_ d: LossControl) -> some View {
        let k = d.kpi
        let afterPrebill = Text("после предчека: ") + Text("\(k?.afterPrebill ?? 0)").fontWeight(.bold)
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            SRMetricTile(label: "Возвраты", value: SR.rub(k?.refundsSum),
                         sub: Text("\(k?.refundsCount ?? 0) шт. · " + SR.number(k?.refundsPct ?? 0) + "% выручки"))
            SRMetricTile(label: "Отмены оплаченных", value: "\(k?.voidsCount ?? 0)",
                         sub: Text(SR.rub(k?.voidsSum)))
            SRMetricTile(label: "Удаления позиций", value: "\(k?.itemCuts ?? 0)", sub: afterPrebill)
            SRMetricTile(label: "Ручные скидки", value: "\(k?.manualDiscounts ?? 0)",
                         sub: Text(SR.rub(k?.manualDiscountsSum)))
            SRMetricTile(label: "Ящик без продажи", value: "\(k?.drawerNoSale ?? 0)",
                         sub: Text("изъятия: \(k?.cashOutCount ?? 0) на " + SR.rub(k?.cashOutSum)))
            SRMetricTile(label: "Без чека", value: "\(k?.noReceipt ?? 0)",
                         sub: Text(SR.rub(k?.noReceiptSum)))
            SRMetricTile(label: "Недостачи смен", value: SR.rub(k?.shortageSum),
                         sub: Text("излишки " + SR.rub(k?.surplusSum) + " · смен \(k?.shiftsClosed ?? 0)"))
            SRMetricTile(label: "Обход прав", value: "\((k?.overrides ?? 0) + (k?.offlineApprovals ?? 0))",
                         sub: Text("без связи: \(k?.offlineApprovals ?? 0) · подбор PIN: \(k?.pinAttacks ?? 0)"))
        }
    }

    // ── Сотрудники и кассы ───────────────────────────────────────────────────
    private static let kinds = ["cashier": "кассир", "station": "касса", "staff": "кабинет", "owner": "владелец"]
    /// Колонки таблицы кабинета: категория, заголовок, показывать ли сумму.
    private static let cells: [(String, String, Bool)] = [
        ("refund", "Возвраты", true), ("void", "Отмены оплач.", true), ("item_cut", "Удаления", false),
        ("discount", "Скидки", true), ("drawer", "Ящик", false), ("price", "Цена вручную", false),
        ("cash_out", "Изъятия", true),
    ]

    private func actorsCard(_ d: LossControl) -> some View {
        SectionCard(title: "Сотрудники и кассы") {
            if d.actors.isEmpty {
                Text("За период денежных операций в журнале нет.")
                    .font(.subheadline).foregroundColor(Brand.muted)
            } else {
                ForEach(Array(d.actors.enumerated()), id: \.offset) { i, a in
                    if i > 0 { Divider().overlay(Brand.border) }
                    actorBlock(a)
                }
                // Сервер отдаёт не больше actors_limit (100) с наибольшим риском (А86, П-39 №2).
                if let total = d.actorsTotal, total > d.actors.count {
                    shownOfTotal(d.actors.count, total, hint: "выберите период короче.")
                }
                Text("Жёлтым — в 2,5 раза больше, чем обычно у остальных (не меньше 3 операций). Кассир — по имени, которое касса пишет в журнал; владелец в сравнении не участвует.")
                    .font(.caption2)
                    .foregroundColor(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actorBlock(_ a: LossActor) -> some View {
        let flags = Set(a.flags ?? [])
        let sub = joinedNonEmpty([Self.kinds[a.kind ?? ""], a.lastAt.map { DateFmt.short($0) }], separator: " · ")
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name ?? "—").font(.subheadline.weight(.bold)).foregroundColor(Brand.text)
                    if !sub.isEmpty {
                        Text(sub).font(.caption).foregroundColor(Brand.muted)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("Риск").font(.caption).foregroundColor(Brand.muted)
                    if let p = a.riskPoints, p > 0 {
                        StatusBadge(text: "\(p)", color: p >= 20 ? SR.critical : SR.warningBadge)
                    } else {
                        Text("—").font(.caption).foregroundColor(Brand.muted)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 6)], spacing: 6) {
                ForEach(Array(Self.cells.enumerated()), id: \.offset) { _, cell in
                    actorCell(a, code: cell.0, title: cell.1, money: cell.2, hot: flags.contains(cell.0))
                }
            }
        }
    }

    private func actorCell(_ a: LossActor, code: String, title: String, money: Bool, hot: Bool) -> some View {
        let n = a.counts?[code] ?? 0
        let sum = a.sums[code] ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundColor(Brand.muted).lineLimit(1).minimumScaleFactor(0.8)
            Text(n > 0 ? "\(n)" : "—")
                .font(.subheadline.weight(hot ? .heavy : .medium))
                .foregroundColor(Brand.text)
            if money && sum > 0 {
                Text(SR.rub(sum)).font(.caption2).foregroundColor(Brand.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
            // «после предчека» — красным, в колонке удалений.
            if code == "item_cut", let ap = a.afterPrebill, ap > 0 {
                Text("после предчека: \(ap)").font(.caption2).foregroundColor(SR.critical)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hot ? SR.warning.opacity(0.25) : Brand.chip.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // ── Подозрительные операции ──────────────────────────────────────────────
    private func ruleRank(_ code: String) -> Int { Self.ruleOrder.firstIndex(of: code) ?? Self.ruleOrder.count }

    private func incidentsCard(_ d: LossControl) -> some View {
        // С операциями владельца — столько строк покажет фильтр (в старых ответах — by_rule).
        let br = d.byRuleAll ?? d.byRule ?? [:]
        let chips = br.keys.sorted { a, b in
            let ca = br[a] ?? 0, cb = br[b] ?? 0
            if ca != cb { return ca > cb }
            let ra = ruleRank(a), rb = ruleRank(b)
            return ra != rb ? ra < rb : a < b
        }
        let all = (d.counts?.total ?? 0) + (d.counts?.owner ?? 0)
        let shown = Array(d.incidents.prefix(vm.visible))
        return SectionCard(title: "Подозрительные операции") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "Все · \(all)", selected: vm.rule.isEmpty) { vm.setRule("") }
                    ForEach(chips, id: \.self) { c in
                        FilterChip(title: (d.rules[c]?.title ?? c) + " · \(br[c] ?? 0)", selected: vm.rule == c) {
                            vm.setRule(c)
                        }
                    }
                }
            }
            if d.incidents.isEmpty {
                Text("Подозрительных операций нет — хороший знак.")
                    .font(.subheadline).foregroundColor(Brand.muted)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, inc in
                        if i > 0 { Divider().overlay(Brand.border) }
                        incidentRow(inc)
                    }
                }
                if d.incidents.count > vm.visible {
                    Button("Показать ещё") { vm.visible += 50 }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                } else if let total = d.incidentsTotal, total > d.incidents.count {
                    // Всё, что прислал сервер, уже на экране, а он отдаёт не больше incidents_limit (300).
                    // Формулировка — как на сайте (seller-sales-report.js, А86). Старый сервер — nil, подписи нет.
                    shownOfTotal(d.incidents.count, total, hint: "выберите правило или период короче.")
                }
            }
        }
    }

    /// «Показаны первые 300 из N — …»: список на сервере обрезан (А86, П-39 №2).
    private func shownOfTotal(_ shown: Int, _ total: Int, hint: String) -> some View {
        Text("Показаны первые \(shown) из \(total) — " + hint)
            .font(.caption2)
            .foregroundColor(Brand.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func incidentRow(_ i: LossIncident) -> some View {
        let sev = SR.severity(i.severity)
        var head = Text(i.title ?? "—").fontWeight(.bold)
        if let actor = i.actor, !actor.isEmpty { head = head + Text(" · " + actor) }
        if let amount = i.amount { head = head + Text(" · ") + Text(Money.rub(amount)).fontWeight(.bold) }
        var meta = DateFmt.short(i.at)
        if let r = i.receiptNumber, !r.isEmpty { meta += " · чек №" + r }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                StatusBadge(text: sev.0, color: sev.1)
                head.font(.subheadline).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = i.detail, !detail.isEmpty {
                Text(detail).font(.subheadline).foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if i.owner == true {
                    StatusBadge(text: "владелец · в индекс не входит", color: Brand.muted)
                }
                Text(meta).font(.caption).foregroundColor(Brand.muted)
            }
            // Переход в заказ — только с правом «Заказы» (иначе экран 403).
            if let oid = i.orderId, oid > 0, session.can("orders") {
                NavigationLink { OrderDetailView(orderId: oid) } label: {
                    Label("заказ", systemImage: "bag").font(.caption.weight(.semibold))
                }
                .foregroundColor(Brand.accent)
            }
            if let advice = i.advice, !advice.isEmpty {
                Text(advice).font(.caption).foregroundColor(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ── Что и как здесь ищется ───────────────────────────────────────────────
    @ViewBuilder
    private func rulesCard(_ d: LossControl) -> some View {
        let codes = d.rules.keys.sorted { a, b in
            let ra = ruleRank(a), rb = ruleRank(b)
            return ra != rb ? ra < rb : a < b
        }
        if !codes.isEmpty {
            SectionCard {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(codes, id: \.self) { c in
                            (Text(d.rules[c]?.title ?? c).fontWeight(.bold).foregroundColor(Brand.text)
                                + Text(" — " + (d.rules[c]?.advice ?? "")))
                                .font(.footnote)
                                .foregroundColor(Brand.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Что и как здесь ищется").font(.subheadline).foregroundColor(Brand.text)
                }
                .tint(Brand.accent)
            }
        }
    }
}
