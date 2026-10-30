import SwiftUI

// ============================================================================
//  Акции — GET /api/seller/promotions (promotions.* + метрики redemptions/
//  total_discount/total_points), тумблер POST .../toggle, архив POST .../archive,
//  восстановление POST .../restore. Конструктор — PromotionEditView.
// ============================================================================

@MainActor
final class PromotionsViewModel: ObservableObject {
    @Published var items: [Promotion] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    /// Акция, которую сейчас переключаем. Сервер ПЕРЕКЛЮЧАЕТ состояние, а
    /// тумблер до перечитывания отскакивал назад — второе нажатие возвращало
    /// акцию как было.
    @Published var togglingId: Int?
    @Published var showArchived = false

    var visible: [Promotion] {
        items.filter { ($0.archived == true) == showArchived }
    }

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.promotions()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func toggle(_ promo: Promotion) async {
        guard togglingId == nil else { return }
        togglingId = promo.promotionId
        defer { togglingId = nil }
        error = nil
        do {
            _ = try await API.shared.togglePromotion(id: promo.promotionId)
            await load()
        } catch {
            // Сервер ПЕРЕКЛЮЧАЕТ, а не ставит состояние: после обрыва связи акция
            // могла уже переключиться, а тумблер показывал прежнее — повторное
            // нажатие возвращало её обратно. Перечитываем настоящее состояние.
            self.error = error.localizedDescription
            await load()
        }
    }

    func archive(_ promo: Promotion) async {
        // Двойное «В архив»/«Восстановить» слало два запроса: второй приходил
        // уже к архивной акции и показывал ошибку поверх удачного действия.
        guard togglingId == nil else { return }
        togglingId = promo.promotionId
        defer { togglingId = nil }
        error = nil
        do {
            try await API.shared.archivePromotion(id: promo.promotionId)
            await load()
        } catch {
            // Уже в архиве (сайт, другой телефон) или обрыв после записи —
            // перечитываем, чтобы акция стояла в своей вкладке.
            self.error = error.localizedDescription
            await load()
        }
    }

    func restore(_ promo: Promotion) async {
        guard togglingId == nil else { return }
        togglingId = promo.promotionId
        defer { togglingId = nil }
        error = nil
        do {
            try await API.shared.restorePromotion(id: promo.promotionId)
            await load()
        } catch {
            self.error = error.localizedDescription
            await load()   // то же, что у архива: показать настоящее состояние
        }
    }
}

struct PromotionsView: View {
    @StateObject private var vm = PromotionsViewModel()
    @State private var editTarget: PromotionEditTarget?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $vm.showArchived) {
                Text("Активные").tag(false)
                Text("Архив").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            List {
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                        .listRowBackground(Brand.card)
                }
                ForEach(vm.visible) { promo in
                    PromotionRow(promo: promo, vm: vm) {
                        editTarget = PromotionEditTarget(id: promo.promotionId)
                    }
                    .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.visible.isEmpty,
                       emptyIcon: "megaphone",
                       emptyTitle: vm.showArchived ? "Архив пуст" : "Акций пока нет",
                       emptySubtitle: vm.showArchived ? nil : "Создайте первую акцию — скидки, подарки, баллы",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Акции")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editTarget = PromotionEditTarget(id: nil) } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $editTarget) { target in
            PromotionEditView(promotionId: target.id, onSaved: { Task { await vm.load() } })
        }
        .task { await vm.load() }
    }
}

/// Цель редактора: nil = создание новой акции (Optional<Int> — валидный Hashable ID).
struct PromotionEditTarget: Identifiable {
    let id: Int?
}

struct PromotionRow: View {
    let promo: Promotion
    @ObservedObject var vm: PromotionsViewModel
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(promo.name ?? "Акция")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.text)
                Spacer()
                if promo.archived != true {
                    Toggle("", isOn: Binding(
                        get: { promo.isActive == true },
                        set: { _ in Task { await vm.toggle(promo) } }
                    ))
                    .labelsHidden()
                    .tint(Brand.green)
                    // А396: остановить действующую акцию — право «Удалять акции» (иначе 403).
                    .disabled(vm.togglingId != nil || (promo.isActive == true && !Session.shared.can("promotions.delete")))
                }
            }
            if promo.archived != true && promo.isActive == true && !Session.shared.can("promotions.delete") {
                Text("Остановить действующую акцию может владелец или сотрудник с правом «Удалять акции».")
                    .font(.caption2).foregroundColor(Brand.muted)
            }
            if let desc = promo.description, !desc.isEmpty {
                Text(desc).font(.caption).foregroundColor(Brand.muted).lineLimit(2)
            }
            // Почему акция не срабатывает (seller_promotions.php, GET promotions:
            // issues) — как на сайте. Без этого «мёртвая» акция выглядела рабочей.
            if let iss = promo.issues, !iss.isEmpty {
                ForEach(iss, id: \.self) { Text($0).font(.caption).foregroundColor(Brand.red) }
            }
            HStack(spacing: 8) {
                // «1 применений» → «1 применение».
                StatusBadge(text: Self.redemptionsText(promo.redemptions ?? 0), color: Brand.accent)
                if let discount = promo.totalDiscount, discount > 0 {
                    StatusBadge(text: "скидки \(Money.rub(discount))", color: Brand.amber)
                }
                if let points = promo.totalPoints, points > 0 {
                    StatusBadge(text: "баллы \(Money.rub(points))", color: Brand.green)
                }
            }
            if promo.startsAt != nil || promo.endsAt != nil {
                Text(periodText)
                    .font(.caption2).foregroundColor(Brand.muted)
            }
            HStack(spacing: 12) {
                Button("Изменить", action: onEdit)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(Brand.accent)
                if promo.archived == true {
                    Button("Восстановить") { Task { await vm.restore(promo) } }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Brand.green)
                        .disabled(vm.togglingId != nil)
                } else if Session.shared.can("promotions.delete") {
                    // Архивация и удаление промокодов — одно право внутри «Акций».
                    Button("В архив") { Task { await vm.archive(promo) } }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(Brand.muted)
                        .disabled(vm.togglingId != nil)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static func redemptionsText(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "\(n) применений" }
        if m10 == 1 { return "\(n) применение" }
        if m10 >= 2 && m10 <= 4 { return "\(n) применения" }
        return "\(n) применений"
    }

    private var periodText: String {
        let from = promo.startsAt.map { "с \(DateFmt.short($0))" }
        let to = promo.endsAt.map { "до \(DateFmt.short($0))" }
        return [from, to].compactMap { $0 }.joined(separator: " ")
    }
}
