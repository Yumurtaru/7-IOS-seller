import SwiftUI

// ============================================================================
//  Тарифы объекта: «Невозвратный дешевле», «С завтраком дороже».
// ----------------------------------------------------------------------------
//  Надбавка задаётся процентом или суммой от базовой цены — считает её сервер.
//  Удаление проданного тарифа сервер превращает в отключение: условия уже
//  оплаченных броней меняться не должны, и об этом экран прямо говорит.
// ============================================================================

@MainActor
final class LodgingPlansViewModel: ObservableObject {
    @Published var items: [LodgingRatePlan] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var info: String?

    let unitId: Int
    init(unitId: Int) { self.unitId = unitId }

    func load() async {
        if items.isEmpty { state = .loading }
        error = nil
        do {
            items = try await API.shared.lodgingRatePlans(unitId: unitId)
            state = .loaded
        } catch is CancellationError {
        } catch {
            if items.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    func save(id: Int?, body: [String: Any?]) async -> Bool {
        error = nil
        info = nil
        do {
            if let id = id {
                try await API.shared.updateLodgingRatePlan(id: id, body: body)
            } else {
                _ = try await API.shared.createLodgingRatePlan(unitId: unitId, body: body)
            }
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func setActive(_ plan: LodgingRatePlan, _ active: Bool) async {
        _ = await save(id: plan.id, body: ["is_active": active ? 1 : 0])
    }

    /// Удаление тарифа в пути: строка висит до ответа, второе «Удалить»
    /// получало 404 «Тариф не найден» поверх удачного удаления.
    private var removingIds: Set<Int> = []

    func remove(_ plan: LodgingRatePlan) async {
        guard !removingIds.contains(plan.id) else { return }
        removingIds.insert(plan.id)
        defer { removingIds.remove(plan.id) }
        error = nil
        info = nil
        do {
            let ack = try await API.shared.deleteLodgingRatePlan(id: plan.id)
            await load()
            // По проданному тарифу сервер его выключает, а не удаляет. Сообщение
            // ставим ПОСЛЕ перечитывания: раньше load() стирал его до показа.
            if ack.deleted != true {
                info = ack.message ?? "Тариф отключён: по нему есть брони, их условия менять нельзя"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct LodgingPlansView: View {
    @StateObject private var vm: LodgingPlansViewModel
    /// Один лист на создание и правку: см. LodgingUnitsSheet.
    @State private var editTarget: LodgingPlanTarget?
    /// Тариф без броней сервер удаляет физически — спрашиваем.
    @State private var deleteTarget: LodgingRatePlan?

    init(unitId: Int) { _vm = StateObject(wrappedValue: LodgingPlansViewModel(unitId: unitId)) }

    var body: some View {
        List {
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
            }
            if let ok = vm.info {
                Section { Text(ok).font(.footnote).foregroundColor(Brand.amber) }
            }
            ForEach(vm.items) { plan in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(plan.name ?? "Тариф")
                                .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { (plan.isActive ?? 1) == 1 },
                                set: { v in Task { await vm.setActive(plan, v) } }
                            ))
                            .labelsHidden()
                        }
                        Text(priceText(plan)).font(.footnote).foregroundColor(Brand.text)
                        Text([mealText(plan.meal), cancelText(plan),
                              minNightsText(plan),
                              (plan.prepayPct ?? 0) > 0 ? "предоплата \(LodgingFormat.pct(plan.prepayPct))%" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundColor(Brand.muted)
                        HStack(spacing: 18) {
                            // Ошибка прошлого действия (удаление, тумблер) не должна
                            // висеть в форме, будто сохранение уже отказало.
                            Button { vm.error = nil; editTarget = LodgingPlanTarget(plan: plan) } label: { Label("Изменить", systemImage: "pencil") }
                            Button(role: .destructive) { deleteTarget = plan } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                        // Кнопки в строке List без стиля срабатывают обе от одного
                        // касания: «Изменить» открывало ещё и «Удалить тариф?».
                        .buttonStyle(.borderless)
                        .font(.footnote)
                    }
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "tag", emptyTitle: "Тарифов нет",
                   emptySubtitle: "Гость бронирует по базовой цене. Добавьте тариф, чтобы предложить завтрак или цену без возврата",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Тарифы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { vm.error = nil; editTarget = LodgingPlanTarget(plan: nil) } label: { Image(systemName: "plus") }
            }
        }
        .confirmationDialog(
            "Удалить тариф?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { plan in
            Button("Удалить «\(plan.name ?? "тариф")»", role: .destructive) {
                let p = plan
                deleteTarget = nil
                Task { await vm.remove(p) }
            }
            Button("Отмена", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("Если по тарифу уже есть брони, он не удалится, а только отключится: условия проданных броней меняться не должны.")
        }
        .sheet(item: $editTarget) { target in LodgingPlanSheet(vm: vm, plan: target.plan) }
        .task { await vm.load() }
    }

    private func priceText(_ p: LodgingRatePlan) -> String {
        let v = p.priceValue ?? 0
        switch p.priceMode ?? "base" {
        case "percent":
            let d = NSDecimalNumber(decimal: v).doubleValue
            // «+12,5%», как предоплата строкой ниже: было «+12.50%» с точкой.
            let num = LodgingFormat.pct(abs(d))
            return "Базовая цена \(d >= 0 ? "+" : "−")\(num)%"
        case "absolute":
            return v >= 0 ? "Базовая цена + \(Money.rub(v))" : "Базовая цена − \(Money.rub(-v))"
        default:
            return "По базовой цене объекта"
        }
    }

    /// «от 2 ночей»: после «от» — родительный падеж. Было «от 1 ночь», «от 3 ночи».
    private func minNightsText(_ p: LodgingRatePlan) -> String? {
        let n = p.minNights ?? 0
        guard n > 0 else { return nil }
        let one = n % 10 == 1 && n % 100 != 11
        return "от \(n) " + (one ? "ночи" : "ночей")
    }

    private func mealText(_ meal: String?) -> String? {
        switch meal ?? "none" {
        case "breakfast": return "завтрак"
        case "half": return "завтрак и ужин"
        case "full": return "полный пансион"
        default: return nil
        }
    }

    private func cancelText(_ p: LodgingRatePlan) -> String? {
        switch p.cancelPenalty ?? "" {
        case "none": return "отмена без удержания"
        case "first_night":
            return (p.cancelFreeDays ?? 1) <= 0
                ? "при отмене удерживается первая ночь"
                : "отмена без штрафа за \(p.cancelFreeDays ?? 1) дн., позже — первая ночь"
        // Паритет с Android: «полная стоимость» с днями бесплатной отмены — не
        // невозвратный тариф: до срока отмена бесплатна (так считает сервер).
        case "full":
            return (p.cancelFreeDays ?? 1) <= 0
                ? "невозвратный"
                : "отмена без штрафа за \(p.cancelFreeDays ?? 1) дн., позже — вся сумма"
        default: return nil
        }
    }
}

/// Цель редактора: plan = nil — создание нового тарифа.
struct LodgingPlanTarget: Identifiable {
    let plan: LodgingRatePlan?
    var id: Int { plan?.id ?? 0 }
}

private struct LodgingPlanSheet: View {
    @ObservedObject var vm: LodgingPlansViewModel
    let plan: LodgingRatePlan?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var priceMode = "base"
    @State private var priceValue = ""
    @State private var meal = "none"
    @State private var cancelPenalty = "first_night"
    @State private var cancelFreeDays = "1"
    @State private var minNights = "0"
    @State private var prepayPct = ""
    @State private var isActive = true
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Тариф") {
                    TextField("Название: «Невозвратный», «С завтраком»", text: $name)
                    // П-27.8: сервер не принимает название короче 2 знаков (422) —
                    // кнопка «Сохранить» погашена, объясняем почему.
                    let nameLen = name.trimmingCharacters(in: .whitespaces).count
                    if nameLen == 1 {
                        Text("Название — не короче 2 символов")
                            .font(.caption).foregroundColor(Brand.red)
                    }
                    Toggle("Доступен гостям", isOn: $isActive)
                }
                if Session.shared.can("products.price") {
                Section {
                    Picker("Цена", selection: $priceMode) {
                        Text("Как базовая").tag("base")
                        Text("Процент от базовой").tag("percent")
                        Text("Надбавка суммой").tag("absolute")
                    }
                    if priceMode != "base" {
                        HStack {
                            Text(priceMode == "percent" ? "Процент" : "Сумма, ₽").foregroundColor(Brand.text)
                            Spacer()
                            TextField("", text: $priceValue)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 110)
                        }
                    }
                } header: {
                    Text("Цена")
                } footer: {
                    Text("Со знаком минус тариф дешевле базовой цены: «−10» — скидка 10 % за отказ от возврата.")
                }
                }
                Section("Что входит") {
                    Picker("Питание", selection: $meal) {
                        Text("Без питания").tag("none")
                        Text("Завтрак").tag("breakfast")
                        Text("Завтрак и ужин").tag("half")
                        Text("Полный пансион").tag("full")
                    }
                }
                Section("Отмена и предоплата") {
                    Picker("Удержание при отмене", selection: $cancelPenalty) {
                        Text("Без удержания").tag("none")
                        Text("Первая ночь").tag("first_night")
                        Text("Полная стоимость (невозвратный)").tag("full")
                    }
                    HStack {
                        Text("Отмена без штрафа, дней").foregroundColor(Brand.text)
                        Spacer()
                        TextField("", text: $cancelFreeDays)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                    }
                    HStack {
                        Text("Минимум ночей").foregroundColor(Brand.text)
                        Spacer()
                        TextField("без ограничения", text: $minNights)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 120)
                    }
                    if Session.shared.can("products.price") {
                        HStack {
                            Text("Предоплата, %").foregroundColor(Brand.text)
                            Spacer()
                            TextField("как у объекта", text: $prepayPct)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 120)
                        }
                    }
                }
                Section {
                    if let err = vm.error {
                        Text(err).font(.footnote).foregroundColor(Brand.red)
                    }
                    Button {
                        Task { await save() }
                    } label: {
                        HStack { Spacer(); if isSaving { ProgressView() } else { Text("Сохранить").bold() }; Spacer() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).count < 2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(plan == nil ? "Новый тариф" : "Тариф")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } } }
            .onAppear { fill() }
        }
    }

    private func fill() {
        guard let p = plan else { return }
        name = p.name ?? ""
        priceMode = p.priceMode ?? "base"
        if let v = p.priceValue, v != 0 { priceValue = NSDecimalNumber(decimal: v).stringValue }
        meal = p.meal ?? "none"
        cancelPenalty = p.cancelPenalty ?? "first_night"
        cancelFreeDays = String(p.cancelFreeDays ?? 1)
        minNights = String(p.minNights ?? 0)
        prepayPct = (p.prepayPct ?? 0) == 0 ? "" : LodgingFormat.pct(p.prepayPct)
        isActive = (p.isActive ?? 1) == 1
    }

    @MainActor private func save() async {
        guard !isSaving else { return }   // двойной тап создавал два тарифа
        // «1 500» раньше уходило строкой с пробелом (сервер читал 1),
        // мусор в предоплате и минимуме ночей — молча.
        let rawValue = priceValue.filter { !$0.isWhitespace }.replacingOccurrences(of: "−", with: "-")
        let neg = rawValue.hasPrefix("-")
        let parsedValue = Money.strict(neg ? String(rawValue.dropFirst()) : rawValue).map { (neg ? "-" : "") + "\($0)" }
        if priceMode != "base" && !rawValue.isEmpty && parsedValue == nil { vm.error = "Надбавка — число, например 500 или -10"; return }
        let ppRaw = prepayPct.trimmingCharacters(in: .whitespaces)
        if !ppRaw.isEmpty && Money.strict(ppRaw) == nil { vm.error = "Предоплата — число"; return }
        // Паритет с Android: больше 100 % и 365 дней сервер молча урезает
        // (seller_lodging.php, lodgingPlanFromInput) — говорим до сохранения.
        if let pp = Money.strict(ppRaw), pp > 100 { vm.error = "Предоплата — от 0 до 100 %"; return }
        if let fd = Int(cancelFreeDays.filter { !$0.isWhitespace }), fd > 365 {
            vm.error = "Бесплатная отмена — не больше 365 дней"; return
        }
        for (raw, label) in [(cancelFreeDays, "Отмена без штрафа"), (minNights, "Минимум ночей")] {
            let t = raw.filter { !$0.isWhitespace }
            if !t.isEmpty && (Int(t) ?? -1) < 0 { vm.error = "\(label) — целое число"; return }
        }
        isSaving = true
        defer { isSaving = false }
        var body: [String: Any?] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "price_mode": priceMode,
            "meal": meal,
            "cancel_penalty": cancelPenalty,
            "is_active": isActive ? 1 : 0,
        ]
        // «Как базовая» — надбавки нет: ноль, иначе сервер посчитал бы старую.
        body["price_value"] = priceMode == "base" ? "0" : (parsedValue ?? "0")
        if let v = Int(cancelFreeDays.filter { !$0.isWhitespace }) { body["cancel_free_days"] = v }
        // Пустое поле — «без ограничения» = 0. Раньше ключ просто не
        // отправлялся, и сервер оставлял прежний минимум.
        let mn = minNights.filter { !$0.isWhitespace }
        if let v = Int(mn) { body["min_nights"] = v } else if mn.isEmpty { body["min_nights"] = 0 }
        body["prepay_pct"] = Money.strict(ppRaw).map { "\($0)" } ?? "0"
        // Надбавка и предоплата — деньги: сервер закрывает их правом «Цены»
        // (и отвечает 403 на всё сохранение). Без права шлём только название,
        // питание и условия отмены — переименовать тариф сотрудник может.
        if !Session.shared.can("products.price") {
            for k in ["price_mode", "price_value", "prepay_pct"] { body.removeValue(forKey: k) }
        }
        if await vm.save(id: plan?.id, body: body) { dismiss() }
    }
}
