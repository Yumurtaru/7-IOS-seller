import SwiftUI

// ============================================================================
//  Доставка — GET/POST /api/seller/settings/delivery (способы получения)
//  + зоны: POST /api/seller/zones, PUT/DELETE /api/seller/zones/{id}.
//  Полигоны НЕ рисуем (анти-скоуп): карта и контур зоны — «Открыть в
//  веб-кабинете» (SFSafariViewController). Правим параметры списком.
//  ФАКТ КОНТРАКТА: PUT зоны меняет только присланные ключи (dzZoneData(…, true)
//  в seller_settings.php) — при правке параметров полигон не шлём вовсе, и
//  контур, нарисованный в вебе, остаётся как есть.
// ============================================================================

@MainActor
final class DeliverySettingsViewModel: ObservableObject {
    @Published var data: DeliverySettings?
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var saving = false

    func load() async {
        if data == nil { state = .loading }
        do {
            data = try await API.shared.deliverySettings()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Обновляет один способ (сервер принимает частичный список methods).
    func saveMethod(type: String, enabled: Bool, pickupAddress: String?, pickupComment: String?,
                    dineInTableRequired: Bool) async {
        error = nil
        saving = true
        defer { saving = false }
        var m: [String: Any] = ["type": type, "is_enabled": enabled ? 1 : 0]
        // pickup_lat/lng не трогаем с телефона — их ставит веб-редактор карты.
        if let a = pickupAddress { m["pickup_address"] = a }
        if let c = pickupComment { m["pickup_comment"] = c }
        if let cur = data?.methods?.first(where: { $0.type == type }) {
            if m["pickup_address"] == nil, let a = cur.pickupAddress { m["pickup_address"] = a }
            if m["pickup_comment"] == nil, let c = cur.pickupComment { m["pickup_comment"] = c }
            if let lat = cur.pickupLat { m["pickup_lat"] = "\(lat)" }
            if let lng = cur.pickupLng { m["pickup_lng"] = "\(lng)" }
            // Фиксированная доставка (цена, «бесплатно от», минимум, время,
            // «только по городу») настраивается в вебе. Возвращаем её как пришла:
            // переключатель способа в приложении не должен её сбрасывать.
            if let v = cur.flatPrice { m["flat_price"] = "\(v)" }
            if let v = cur.flatFreeFrom { m["flat_free_from"] = "\(v)" }
            if let v = cur.flatMinOrder { m["flat_min_order"] = "\(v)" }
            if let v = cur.flatTimeMin { m["flat_time_min"] = v }
            if let v = cur.flatTimeMax { m["flat_time_max"] = v }
            if let v = cur.flatCityOnly { m["flat_city_only"] = v ? 1 : 0 }
        }
        m["dine_in_table_required"] = dineInTableRequired ? 1 : 0
        do {
            try await API.shared.saveDeliveryMethods([m])
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveZone(_ zone: DeliveryZone?, fields: [String: Any?]) async -> Bool {
        error = nil
        do {
            if let z = zone {
                // Полигон при правке не шлём: сервер берёт только присланные ключи,
                // а копия из загруженного когда-то списка затирала контур, который
                // за это время перерисовали в вебе.
                try await API.shared.updateZone(id: z.id, fields: fields)
            } else {
                var body = fields
                body["polygon"] = [Any]()   // контур новой зоны рисуется в вебе
                _ = try await API.shared.createZone(fields: body)
            }
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteZone(_ zone: DeliveryZone) async {
        error = nil
        do {
            try await API.shared.deleteZone(id: zone.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct DeliverySettingsView: View {
    @StateObject private var vm = DeliverySettingsViewModel()
    @State private var editingZone: ZoneEditTarget?
    @State private var webEditor: PayLink?
    /// Зона к удалению — с подтверждением: полный свайп раньше сразу удалял
    /// зону вместе с полигоном, нарисованным в веб-кабинете.
    @State private var zoneToDelete: DeliveryZone?
    /// паритет с Android: адрес и комментарий самовывоза правятся в приложении
    /// (раньше на iPhone их было только видно).
    @State private var pickupEditing = false
    @State private var pickupAddrDraft = ""
    @State private var pickupNoteDraft = ""

    var body: some View {
        List {
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                    .listRowBackground(Brand.card)
            }
            methodsSection
            zonesSection
            webSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Доставка")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "bicycle", emptyTitle: "Нет данных",
                   retry: { Task { await vm.load() } })
        .sheet(item: $editingZone) { target in
            ZoneEditSheet(vm: vm, zone: target.zone)
        }
        // После веб-кабинета перечитываем зоны: там рисуют контур, а правка зоны
        // здесь отправляет полигон, загруженный ДО этого, — и стирала новый контур.
        .sheet(item: $webEditor, onDismiss: { Task { await vm.load() } }) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .task { await vm.load() }
        .alert("Удалить зону?", isPresented: Binding(
            get: { zoneToDelete != nil },
            set: { if !$0 { zoneToDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let z = zoneToDelete { Task { await vm.deleteZone(z) } }
                zoneToDelete = nil
            }
            Button("Отмена", role: .cancel) { zoneToDelete = nil }
        } message: {
            Text("Зона и её границы на карте будут удалены.")
        }
        .alert("Самовывоз", isPresented: $pickupEditing) {
            TextField("Адрес самовывоза", text: $pickupAddrDraft)
            TextField("Комментарий (как найти)", text: $pickupNoteDraft)
            Button("Сохранить") { savePickup() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Адрес увидит клиент при оформлении самовывоза.")
        }
    }

    private func savePickup() {
        let addr = pickupAddrDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = pickupNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let table = vm.data?.methods?.first(where: { $0.type == "pickup" })?.dineInTableRequired ?? false
        Task {
            await vm.saveMethod(type: "pickup", enabled: true, pickupAddress: addr,
                                pickupComment: note, dineInTableRequired: table)
        }
    }

    // ── Способы получения ────────────────────────────────────────────────────
    @ViewBuilder
    private var methodsSection: some View {
        Section("Способы получения") {
            ForEach(allMethods) { m in
                Toggle(isOn: Binding(
                    get: { m.isEnabled ?? false },
                    set: { on in
                        Task {
                            await vm.saveMethod(type: m.type ?? "", enabled: on,
                                                pickupAddress: nil, pickupComment: nil,
                                                dineInTableRequired: m.dineInTableRequired ?? false)
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(methodLabel(m.type)).font(.subheadline.weight(.semibold))
                        if m.type == "pickup", let a = m.pickupAddress, !a.isEmpty {
                            Text(a).font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                }
                .tint(Brand.green)
                .disabled(vm.saving)
                if m.type == "pickup", m.isEnabled == true {
                    Button {
                        pickupAddrDraft = m.pickupAddress ?? ""
                        pickupNoteDraft = m.pickupComment ?? ""
                        pickupEditing = true
                    } label: {
                        Label("Адрес и комментарий самовывоза", systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                    }
                    .disabled(vm.saving)
                }
                // паритет с Android: «номер стола обязателен» для заказа в зале.
                if m.type == "dine_in", m.isEnabled == true {
                    Toggle("Номер стола обязателен", isOn: Binding(
                        get: { m.dineInTableRequired ?? false },
                        set: { v in
                            Task {
                                await vm.saveMethod(type: "dine_in", enabled: true, pickupAddress: nil,
                                                    pickupComment: nil, dineInTableRequired: v)
                            }
                        }
                    ))
                    .font(.subheadline)
                    .tint(Brand.green)
                    .disabled(vm.saving)
                }
            }
        }
        .listRowBackground(Brand.card)
    }

    /// Полный список трёх способов: сервер отдаёт только заведённые строки.
    private var allMethods: [DeliveryMethod] {
        let existing = vm.data?.methods ?? []
        return ["delivery", "pickup", "dine_in"].map { type in
            existing.first(where: { $0.type == type }) ?? placeholderMethod(type)
        }
    }

    private func placeholderMethod(_ type: String) -> DeliveryMethod {
        // Пустой JSON → все поля nil, только type подставляем.
        let json = "{\"type\":\"\(type)\"}".data(using: .utf8)!
        return (try? JSONDecoder().decode(DeliveryMethod.self, from: json))
            ?? (try! JSONDecoder().decode(DeliveryMethod.self, from: "{}".data(using: .utf8)!))
    }

    private func methodLabel(_ t: String?) -> String {
        switch t {
        case "delivery": return "Доставка"
        case "pickup": return "Самовывоз"
        case "dine_in": return "В зале"
        default: return t ?? "—"
        }
    }

    // ── Зоны доставки ────────────────────────────────────────────────────────
    @ViewBuilder
    private var zonesSection: some View {
        Section("Зоны доставки") {
            let zones = vm.data?.zones ?? []
            if zones.isEmpty {
                Text("Зоны не настроены — клиенты за пределами зон не смогут заказать доставку.")
                    .font(.caption).foregroundColor(Brand.muted)
            }
            ForEach(zones) { z in
                Button {
                    editingZone = ZoneEditTarget(zone: z)
                } label: {
                    HStack {
                        Circle()
                            .fill(z.isExcluded == true ? Brand.red : Brand.green)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(z.name ?? "Зона")
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(Brand.text)
                            Text(zoneSubtitle(z))
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                        Spacer()
                        if z.isActive == false {
                            StatusBadge(text: "выкл", color: Brand.muted)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        zoneToDelete = z
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
            Button {
                editingZone = ZoneEditTarget(zone: nil)
            } label: {
                Label("Добавить зону (контур — в вебе)", systemImage: "plus")
            }
        }
        .listRowBackground(Brand.card)
    }

    private func zoneSubtitle(_ z: DeliveryZone) -> String {
        // «0 ₽» у бесплатной доставки и цена у исключающей зоны (там не
        // доставляем вовсе) читались как ошибка — пишем словами.
        let price: String
        if z.isExcluded == true {
            price = "не доставляем"
        } else if (z.deliveryPrice ?? 0) > 0 {
            price = Money.rub(z.deliveryPrice)
        } else {
            price = "бесплатно"
        }
        var parts: [String] = [price]
        // При бесплатной/исключённой зоне «бесплатно от …» лишнее («бесплатно · бесплатно от»).
        let paid = (z.deliveryPrice ?? 0) > 0 && z.isExcluded != true
        if paid, let f = z.freeFrom, f > 0 { parts.append("бесплатно от " + Money.rub(f)) }
        if let mn = z.minOrder, mn > 0 { parts.append("мин. заказ " + Money.rub(mn)) }
        if let t1 = z.deliveryTimeMin, let t2 = z.deliveryTimeMax { parts.append("\(t1)–\(t2) мин") }
        parts.append("точек контура: \(z.polygonPointsCount)")
        return parts.joined(separator: " · ")
    }

    private var webSection: some View {
        Section {
            Button {
                if let url = URL(string: "https://yumurta.ru/seller/settings.php") {
                    webEditor = PayLink(url: url)
                }
            } label: {
                Label("Карта и контуры зон — в веб-кабинете", systemImage: "map")
            }
        } footer: {
            Text("Рисование и правка полигонов доступны в веб-кабинете. Здесь меняются стоимость, минимальный заказ, время и активность зоны — контур при этом сохраняется.")
        }
        .listRowBackground(Brand.card)
    }
}

struct ZoneEditTarget: Identifiable {
    let id = UUID()
    let zone: DeliveryZone?
}

// ── Правка параметров зоны ───────────────────────────────────────────────────
struct ZoneEditSheet: View {
    @ObservedObject var vm: DeliverySettingsViewModel
    let zone: DeliveryZone?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var priceText = "0"
    @State private var minOrderText = "0"
    @State private var freeFromText = "0"
    @State private var timeMinText = ""
    @State private var timeMaxText = ""
    @State private var priorityText = "0"
    @State private var isActive = true
    @State private var isExcluded = false
    @State private var isSubmitting = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Зона") {
                    TextField("Название", text: $name)
                    Toggle("Активна", isOn: $isActive).tint(Brand.green)
                    Toggle("Исключающая (не доставляем)", isOn: $isExcluded).tint(Brand.red)
                }
                Section("Условия доставки") {
                    LabeledContent("Стоимость, ₽") {
                        TextField("0", text: $priceText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Мин. заказ, ₽") {
                        TextField("0", text: $minOrderText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Бесплатно от, ₽") {
                        TextField("0", text: $freeFromText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Время от, мин") {
                        TextField("—", text: $timeMinText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Время до, мин") {
                        TextField("—", text: $timeMaxText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Приоритет") {
                        TextField("0", text: $priorityText)
                            .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
                if zone == nil {
                    Section {
                        Text("Контур новой зоны нужно нарисовать в веб-кабинете — до этого зона не будет действовать на карте.")
                            .font(.caption).foregroundColor(Brand.amber)
                    }
                }
                if let err = localError {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer(); if isSubmitting { ProgressView() } else { Text("Сохранить").bold() }; Spacer() }
                    }
                    .disabled(isSubmitting)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(zone == nil ? "Новая зона" : "Зона доставки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
            .onAppear {
                if let z = zone {
                    name = z.name ?? ""
                    priceText = "\(z.deliveryPrice ?? 0)"
                    minOrderText = "\(z.minOrder ?? 0)"
                    freeFromText = "\(z.freeFrom ?? 0)"
                    timeMinText = z.deliveryTimeMin.map(String.init) ?? ""
                    timeMaxText = z.deliveryTimeMax.map(String.init) ?? ""
                    priorityText = "\(z.priority ?? 0)"
                    isActive = z.isActive ?? true
                    isExcluded = z.isExcluded ?? false
                }
            }
        }
    }

    @MainActor private func submit() async {
        // Двойной тап «Сохранить» у новой зоны создавал две одинаковые зоны:
        // кнопка гаснет только со следующей перерисовкой.
        guard !isSubmitting else { return }
        isSubmitting = true
        localError = nil
        // Строгий разбор денег: «1 500» раньше уходило текстом и становилось 1 ₽
        // доставки для всех клиентов. Пусто — пустая строка, как раньше.
        func dec(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return "" }
            return Money.strict(t).map { "\($0)" }
        }
        for (raw, label) in [(priceText, "Цена доставки"), (minOrderText, "Минимальный заказ"), (freeFromText, "Бесплатно от")] {
            if dec(raw) == nil { localError = "\(label) — число, например 150"; isSubmitting = false; return }
        }
        for (raw, label) in [(timeMinText, "Время от"), (timeMaxText, "Время до"), (priorityText, "Приоритет")] {
            let t = raw.filter { !$0.isWhitespace }
            if !t.isEmpty && Int(t) == nil { localError = "\(label) — целое число"; isSubmitting = false; return }
        }
        // «от 60 до 30 минут» и отрицательное время раньше уходили как есть, и
        // клиент видел в оформлении перевёрнутый срок доставки.
        if let a = Int(timeMinText.filter { !$0.isWhitespace }), a < 0 {
            localError = "Время от — не меньше 0 минут"; isSubmitting = false; return
        }
        if let a = Int(timeMinText.filter { !$0.isWhitespace }),
           let b = Int(timeMaxText.filter { !$0.isWhitespace }), b < a {
            localError = "Время «до» должно быть не меньше времени «от»"; isSubmitting = false; return
        }
        var fields: [String: Any?] = [
            "name": name.isEmpty ? "Зона" : name,
            "delivery_price": dec(priceText),
            "min_order": dec(minOrderText),
            "free_from": dec(freeFromText),
            "is_active": isActive ? 1 : 0,
            "is_excluded": isExcluded ? 1 : 0,
            "priority": Int(priorityText.filter { !$0.isWhitespace }) ?? 0,
        ]
        // Пустое время при правке — явное «не указано»: nil выпадал, и старое оставалось.
        // П-20.1: сервер понимает «не указано» как "" (проверено на стенде), null не обещан.
        let tMin = Int(timeMinText.filter { !$0.isWhitespace })
        let tMax = Int(timeMaxText.filter { !$0.isWhitespace })
        if let v = tMin { fields["delivery_time_min"] = v } else if zone != nil { fields["delivery_time_min"] = "" }
        if let v = tMax { fields["delivery_time_max"] = v } else if zone != nil { fields["delivery_time_max"] = "" }
        // Правка: приоритет и «не доставляем» шлём, только если их поменяли в этом
        // окне. Сервер не трогает непришедшие ключи, а неизменённые значения из
        // старого списка перетирали то, что за это время поменяли в вебе.
        if let z = zone {
            if isExcluded == (z.isExcluded ?? false) { fields.removeValue(forKey: "is_excluded") }
            if (Int(priorityText.filter { !$0.isWhitespace }) ?? 0) == (z.priority ?? 0) { fields.removeValue(forKey: "priority") }
        }
        let ok = await vm.saveZone(zone, fields: fields)
        isSubmitting = false
        if ok { dismiss() } else { localError = vm.error }
    }
}
