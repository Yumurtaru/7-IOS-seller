import SwiftUI

// ============================================================================
//  Безопасность — routes/seller_security.php:
//   • Журнал  GET /api/seller/security/feed?days=&action= (до 300 строк,
//     labels — словарь подписей действий с сервера)
//   • Сводка  GET /api/seller/security/stats?days=
//   • Кассиры GET /api/seller/security/by_cashier?days= (риск-метрики)
//   • Алерты  GET /api/seller/security/alerts (critical/warning подсветка)
//  enabled=false — таблица журнала не установлена (миграция) — говорим прямо.
// ============================================================================

struct SecurityView: View {
    enum Tab: String, CaseIterable {
        case alerts = "Алерты"
        case feed = "Журнал"
        case cashiers = "Кассиры"
        case stats = "Сводка"
    }

    @State private var tab: Tab = .alerts

    var body: some View {
        VStack(spacing: 0) {
            Picker("Раздел", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)

            switch tab {
            case .alerts: SecurityAlertsTab()
            case .feed: SecurityFeedTab()
            case .cashiers: SecurityCashiersTab()
            case .stats: SecurityStatsTab()
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Безопасность")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func severityColor(_ s: String?) -> Color {
        switch s {
        case "critical": return Brand.red
        case "warning": return Brand.amber
        default: return Brand.muted
        }
    }
}

// ── Алерты ───────────────────────────────────────────────────────────────────
@MainActor
final class SecurityAlertsViewModel: ObservableObject {
    @Published var data: SecurityAlerts?
    @Published var state: LoadState = .idle

    func load() async {
        if data == nil { state = .loading }
        do {
            data = try await API.shared.securityAlerts()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private struct SecurityAlertsTab: View {
    @StateObject private var vm = SecurityAlertsViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if vm.data?.enabled == false { AuditDisabledBanner() }
                let alerts = vm.data?.alerts ?? []
                ForEach(alerts) { a in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: SecurityLabels.sfIcon(a.icon))
                            .foregroundColor(SecurityView.severityColor(a.severity))
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(a.title ?? "—")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(Brand.text)
                                Spacer()
                                StatusBadge(text: a.severity == "critical" ? "критично" : "внимание",
                                            color: SecurityView.severityColor(a.severity))
                            }
                            Text(a.detail ?? "")
                                .font(.caption).foregroundColor(Brand.muted)
                            Text(DateFmt.short(a.when))
                                .font(.caption2).foregroundColor(Brand.muted)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.card)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(SecurityView.severityColor(a.severity).opacity(0.4), lineWidth: 1)
                    )
                }
            }
            .padding(16)
        }
        .refreshable { await vm.load() }
        // Журнал не установлен — алертов нет не потому, что всё хорошо: поверх
        // баннера «не активирован» раньше стояло «Аномалий не найдено».
        .listState(vm.state, isEmpty: (vm.data?.alerts ?? []).isEmpty && vm.data?.enabled != false,
                   emptyIcon: "checkmark.shield", emptyTitle: "Аномалий не найдено",
                   emptySubtitle: "Крупные возвраты, ночные операции и частые отмены появятся здесь",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }
}

// ── Журнал ───────────────────────────────────────────────────────────────────
@MainActor
final class SecurityFeedViewModel: ObservableObject {
    @Published var feed: SecurityFeed?
    @Published var state: LoadState = .idle
    @Published var days = 30
    @Published var action = ""      // "" = все действия

    /// Клиентская пагинация: сервер отдаёт до 300 строк разом.
    @Published var visibleCount = 50
    /// А320: следующая страница с сервера (before_id) — идёт / не загрузилась.
    @Published var loadingMore = false
    @Published var moreError: String?

    /// Фильтр, по которому показаны данные. Чипы не отменяют запросы: ответ
    /// по «90 дн.», пришедший после «7 дн.», показывался под «7 дн.», а сбой
    /// после смены фильтра оставлял старые данные под новым чипом без ошибки.
    private var shownKey = ""

    func load() async {
        if feed == nil { state = .loading }
        let key = "\(days)|\(action)"
        do {
            let r = try await API.shared.securityFeed(days: days, action: action.isEmpty ? nil : action)
            guard key == "\(days)|\(action)" else { return }
            feed = r
            shownKey = key
            visibleCount = 50
            moreError = nil
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard key == "\(days)|\(action)" else { return }
            if shownKey != key { feed = nil }
            state = .failed(error.localizedDescription)
        }
    }

    var visible: [AuditEntry] {
        Array((feed?.items ?? []).prefix(visibleCount))
    }
    var hasMore: Bool { (feed?.items?.count ?? 0) > visibleCount || serverHasMore }
    private var serverHasMore: Bool { feed?.hasMore == true && (feed?.nextBeforeId ?? 0) > 0 }

    /// «Показать ещё»: сначала уже загруженные строки, потом следующие 300 с сервера.
    func showMore() async {
        if (feed?.items?.count ?? 0) > visibleCount { visibleCount += 50; return }
        guard serverHasMore, !loadingMore, let before = feed?.nextBeforeId else { return }
        let key = "\(days)|\(action)"
        guard key == shownKey else { return }
        loadingMore = true
        defer { loadingMore = false }
        moreError = nil
        do {
            let r = try await API.shared.securityFeed(days: days, action: action.isEmpty ? nil : action, beforeId: before)
            guard key == "\(days)|\(action)", key == shownKey else { return }
            let known = Set((feed?.items ?? []).compactMap(\.entryId))
            let fresh = (r.items ?? []).filter { e in e.entryId.map { !known.contains($0) } ?? false }
            feed?.items = (feed?.items ?? []) + fresh
            feed?.hasMore = r.hasMore
            feed?.nextBeforeId = r.nextBeforeId
            if let l = r.labels, !l.isEmpty { feed?.labels = (feed?.labels ?? [:]).merging(l) { a, _ in a } }
            visibleCount += 50
        } catch is CancellationError {
        } catch {
            moreError = error.localizedDescription
        }
    }
    func label(_ action: String?) -> String {
        guard let a = action else { return "—" }
        return feed?.labels?[a] ?? a
    }
}

private struct SecurityFeedTab: View {
    @StateObject private var vm = SecurityFeedViewModel()
    private let windows = [7, 30, 90]

    var body: some View {
        VStack(spacing: 0) {
            filters
            List {
                if vm.feed?.enabled == false {
                    AuditDisabledBanner().listRowBackground(Brand.card)
                }
                ForEach(vm.visible) { e in
                    entryRow(e).listRowBackground(Brand.card)
                }
                if vm.hasMore {
                    Button {
                        Task { await vm.showMore() }
                    } label: {
                        if vm.loadingMore { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(vm.moreError.map { "Не загрузилось: \($0) · Повторить" } ?? "Показать ещё") }
                    }
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(vm.moreError == nil ? Brand.accent : Brand.red)
                        .frame(maxWidth: .infinity)
                        .disabled(vm.loadingMore)
                        .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .refreshable { await vm.load() }
        // Как у алертов: при неустановленном журнале баннер говорит сам за себя,
        // «Журнал пуст» поверх него вводило в заблуждение.
        .listState(vm.state, isEmpty: vm.visible.isEmpty && vm.feed?.enabled != false,
                   emptyIcon: "doc.text.magnifyingglass", emptyTitle: "Журнал пуст",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(windows, id: \.self) { d in
                    FilterChip(title: "\(d) дн.", selected: vm.days == d) {
                        vm.days = d
                        Task { await vm.load() }
                    }
                }
                FilterChip(title: "Все действия", selected: vm.action.isEmpty) {
                    vm.action = ""
                    Task { await vm.load() }
                }
                // Словарь подписей приходит с сервера — фильтры собираем из него.
                ForEach(sortedActions, id: \.0) { code, title in
                    FilterChip(title: title, selected: vm.action == code) {
                        vm.action = code
                        Task { await vm.load() }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    private var sortedActions: [(String, String)] {
        (vm.feed?.labels ?? [:]).sorted { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    private func entryRow(_ e: AuditEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle()
                    .fill(SecurityView.severityColor(e.severity))
                    .frame(width: 8, height: 8)
                Text(vm.label(e.action))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Spacer()
                if let amount = e.amount, amount != 0 {
                    Text(Money.rub(amount))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(SecurityView.severityColor(e.severity))
                }
            }
            HStack {
                Text(e.actorName ?? actorTypeLabel(e.actorType))
                    .font(.caption).foregroundColor(Brand.muted)
                Spacer()
                Text(DateFmt.short(e.createdAt))
                    .font(.caption2).foregroundColor(Brand.muted)
            }
            if let note = e.meta["note"], !note.isEmpty {
                Text(note).font(.caption).foregroundColor(Brand.muted).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func actorTypeLabel(_ t: String?) -> String {
        switch t {
        case "seller": return "Владелец"
        case "staff": return "Сотрудник"
        case "station": return "Касса/станция"
        case "courier": return "Курьер"
        default: return t ?? "—"
        }
    }
}

// ── Риск-метрики по кассирам ─────────────────────────────────────────────────
@MainActor
final class SecurityCashiersViewModel: ObservableObject {
    @Published var report: CashierRiskReport?
    @Published var state: LoadState = .idle
    @Published var days = 30

    private var shownDays: Int?

    func load() async {
        if report == nil { state = .loading }
        let asked = days
        do {
            let r = try await API.shared.securityByCashier(days: asked)
            guard asked == days else { return }   // ответ по прежнему периоду
            report = r
            shownDays = asked
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard asked == days else { return }
            if shownDays != asked { report = nil }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct SecurityCashiersTab: View {
    @StateObject private var vm = SecurityCashiersViewModel()
    private let windows = [7, 30, 90]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(windows, id: \.self) { d in
                        FilterChip(title: "\(d) дн.", selected: vm.days == d) {
                            vm.days = d
                            Task { await vm.load() }
                        }
                    }
                    Spacer()
                }
                // По порядку, а не по имени: у двух кассиров с одинаковым именем
                // id совпадал (карточка рисовалась дважды), а без имени id был
                // новым UUID на каждую перерисовку.
                ForEach(Array((vm.report?.rows ?? []).enumerated()), id: \.offset) { _, r in
                    SectionCard(title: r.actorName ?? "Без имени") {
                        VStack(alignment: .leading, spacing: 5) {
                            if let c = r.critical, c > 0 {
                                StatusBadge(text: "критичных действий: \(c)", color: Brand.red)
                            }
                            InfoRow(label: "Возвраты", value: "\(r.refunds ?? 0) · " + Money.rub(r.refundSum))
                            InfoRow(label: "Отмены заказов", value: "\(r.cancels ?? 0)" + ((r.voidPaid ?? 0) > 0 ? " (оплаченных: \(r.voidPaid ?? 0))" : ""))
                            InfoRow(label: "Скидки на кассе", value: "\(r.discounts ?? 0)")
                            InfoRow(label: "Правки чека (кол-во/удаление)", value: "\(r.qtyCuts ?? 0)")
                            InfoRow(label: "Ящик без продажи", value: "\(r.noSale ?? 0)")
                            InfoRow(label: "Всего действий", value: "\(r.total ?? 0)")
                            if let last = r.lastAt {
                                InfoRow(label: "Последнее действие", value: DateFmt.short(last))
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: (vm.report?.rows ?? []).isEmpty,
                   emptyIcon: "person.badge.shield.checkmark", emptyTitle: "Данных по кассирам нет",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }
}

// ── Сводка ───────────────────────────────────────────────────────────────────
@MainActor
final class SecurityStatsViewModel: ObservableObject {
    @Published var stats: SecurityStats?
    @Published var labels: [String: String] = [:]
    @Published var state: LoadState = .idle
    // Паритет с Android и соседними вкладками: по умолчанию 30 дней. С 7 «Сводка»
    // при открытии считала другой период, чем «Журнал» и «Кассиры».
    @Published var days = 30

    private var shownDays: Int?

    func load() async {
        if stats == nil { state = .loading }
        let asked = days
        do {
            let r = try await API.shared.securityStats(days: asked)
            guard asked == days else { return }   // ответ по прежнему периоду
            stats = r
            shownDays = asked
            if labels.isEmpty, let feed = try? await API.shared.securityFeed(days: 1, action: nil) {
                labels = feed.labels ?? [:]
            }
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard asked == days else { return }
            if shownDays != asked { stats = nil }
            state = .failed(error.localizedDescription)
        }
    }
}

private struct SecurityStatsTab: View {
    @StateObject private var vm = SecurityStatsViewModel()
    private let windows = [7, 30, 90]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(windows, id: \.self) { d in
                        FilterChip(title: "\(d) дн.", selected: vm.days == d) {
                            vm.days = d
                            Task { await vm.load() }
                        }
                    }
                    Spacer()
                }
                if let s = vm.stats {
                    SectionCard {
                        InfoRow(label: "Всего действий за период", value: "\(s.total ?? 0)")
                    }
                    if let rows = s.byAction, !rows.isEmpty {
                        SectionCard(title: "По действиям") {
                            ForEach(rows) { r in
                                HStack {
                                    Text(vm.labels[r.action ?? ""] ?? r.action ?? "—")
                                        .font(.subheadline).foregroundColor(Brand.text)
                                    Spacer()
                                    Text("\(r.cnt ?? 0)" + ((r.amount ?? 0) != 0 ? " · " + Money.rub(r.amount) : ""))
                                        .font(.subheadline.weight(.medium)).foregroundColor(Brand.text)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.stats == nil || (vm.stats?.byAction ?? []).isEmpty,
                   emptyIcon: "chart.bar.doc.horizontal", emptyTitle: "Действий за период нет",
                   retry: { Task { await vm.load() } })
        .task { await vm.load() }
    }
}

// ── Баннер «журнал не установлен» ────────────────────────────────────────────
private struct AuditDisabledBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Brand.amber)
            Text("Журнал действий не активирован на сервере (нужна миграция staff_audit_log).")
                .font(.caption).foregroundColor(Brand.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.amber.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
