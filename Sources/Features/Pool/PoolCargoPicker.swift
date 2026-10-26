import SwiftUI

// ============================================================================
//  «Курьеры Yumurta» (волна А80) — выбор машины в окне «Вызвать курьера
//  Yumurta»: «По городу / Межгород», кузов (Авто, S…XXL), грузчики, вес;
//  межгород — город назначения и водители с ценой по их тарифу.
//  Зеркало сайта: assets/js/cargo-picker.js (общий для посылки и продавца).
//  Подсказки — GET /api/v1/seller/pool/quote (CourierPool::cargoQuote).
//  Старый сервер не шлёт vehicles — выбор машины не показывается вовсе.
// ============================================================================

/// Что выбрано в форме. Пусто/по умолчанию — «легковая по городу», как раньше.
struct PoolCargoState: Equatable {
    var trip = "city"                 // city | intercity
    var vehicleClass = "car"          // car | s | m | l | xl | xxl
    var loaders = 0                   // 0…2
    var cargoKg = ""                  // поле ввода, только цифры
    var destCityId: Int?
    var destCityName = ""
    /// Выбранный водитель межгорода; nil — «Любой водитель».
    var courierId: Int?

    var intercity: Bool { trip == "intercity" }
    var kg: Int? { Int(cargoKg).flatMap { $0 > 0 ? $0 : nil } }
    /// Просят больше, чем «легковая по городу».
    var wantsCargo: Bool { vehicleClass != "car" || trip != "city" || loaders > 0 || kg != nil }

    /// Параметры подсказок (как params() в cargo-picker.js).
    var query: [String: String] {
        var q = ["trip": trip, "vehicle_class": vehicleClass, "loaders": String(loaders)]
        if let kg { q["cargo_kg"] = String(kg) }
        if intercity, let d = destCityId, d > 0 { q["dest_city_id"] = String(d) }
        return q
    }

    /// Ключ подсказок: смена любого из полей — новый запрос quote.
    var queryKey: String {
        query.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
    }

    /// Начальные значения из прежнего вызова («Выбрать другого водителя»).
    init() {}
    init(call: PoolCall) {
        trip = call.trip == "intercity" ? "intercity" : "city"
        let vc = (call.vehicleClass ?? "").lowercased()
        vehicleClass = vc.isEmpty ? "car" : vc
        loaders = min(2, max(0, call.loaders ?? 0))
        if let kg = call.cargoKg, kg > 0 { cargoKg = String(kg) }
        if trip == "intercity", let d = call.destCityId, d > 0 {
            destCityId = d
            destCityName = call.destCity ?? ""
        }
    }
}

/// Поля формы машины, которые сервер проверяет (422 и cargo.errors).
enum PoolCargoFields {
    static let all: Set<String> = ["vehicle_class", "cargo_kg", "loaders", "trip", "dest_city_id", "courier_id"]
}

// ── Секции выбора машины (внутри Form окна вызова) ──────────────────────────
struct PoolCargoPicker: View {
    @Binding var state: PoolCargoState
    let quote: PoolQuote
    /// Идёт запрос подсказок (сменили кузов, вес, город).
    let loading: Bool
    /// Ошибки полей после «Вызвать курьера» (422) — поверх cargo.errors.
    let fieldErrors: [String: String]
    let cities: [PoolCity]
    let citiesLoading: Bool
    let citiesError: String?
    let loadCities: () -> Void
    /// Выбрано «Сейчас» — водителю «в рейсе» поездка сейчас не подойдёт.
    let pickupNow: Bool

    private var vehicles: [PoolVehicle] { quote.vehicles ?? [] }
    private var cargo: PoolCargoQuote? { quote.cargo }
    private var drivers: [PoolDriver] { quote.drivers ?? [] }
    private var vehicle: PoolVehicle? {
        vehicles.first { $0.code == state.vehicleClass } ?? vehicles.first
    }

    /// Подсказки посчитаны для выбранного города (не для прежнего, пока идёт новый запрос).
    private var quoteFresh: Bool { cargo?.destCityId == state.destCityId }

    private func err(_ field: String) -> String? {
        if let e = fieldErrors[field], !e.isEmpty { return e }
        return cargo?.error(field)
    }

    /// Смена кузова, грузчиков, поездки или города снимает выбор водителя
    /// (его цена и «подходит ли машина» считались под прежний груз).
    private func binding<T: Equatable>(_ key: WritableKeyPath<PoolCargoState, T>) -> Binding<T> {
        Binding(get: { state[keyPath: key] }, set: { v in
            guard state[keyPath: key] != v else { return }
            state[keyPath: key] = v
            state.courierId = nil
        })
    }

    var body: some View {
        Group {
            if quote.intercityEnabled == true {
                Section {
                    Picker("Поездка", selection: binding(\.trip)) {
                        Text("По городу").tag("city")
                        Text("Межгород").tag("intercity")
                    }
                    .pickerStyle(.segmented)
                    if let e = err("trip") { errorText(e) }
                }
            }
            vehicleSection
            if state.intercity { destSection }
            if state.intercity, state.destCityId != nil, quoteFresh, err("dest_city_id") == nil, err("cargo_kg") == nil {
                driversSection
            }
        }
    }

    // ── Кузов, грузчики, вес ────────────────────────────────────────────────
    private var vehicleSection: some View {
        Section {
            if let v = vehicle {
                VStack(spacing: 6) {
                    PoolBodyIllustration(vehicle: v)
                        .frame(height: 128)
                    if let h = v.hint, !h.isEmpty {
                        Text(h).font(.footnote).foregroundColor(Brand.muted).multilineTextAlignment(.center)
                    }
                    Text("Максимум \(v.maxKg ?? 0) кг" + (v.body?.text.map { " · кузов " + $0 } ?? ""))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.text)
                    if !state.intercity, let p = v.cityPrice, p > 0 {
                        Text("По городу — от " + Money.rub(p)).font(.caption).foregroundColor(Brand.muted)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            Picker("Кузов", selection: binding(\.vehicleClass)) {
                ForEach(vehicles, id: \.self) { v in
                    Text(v.short).tag(v.code ?? "")
                }
            }
            .pickerStyle(.segmented)
            if let e = err("vehicle_class") { errorText(e) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Грузчики").font(.subheadline.weight(.semibold))
                    Text(state.loaders > 0 ? "по " + Money.rub(quote.loaderPrice) + " за грузчика" : "Помощь не нужна")
                        .font(.caption).foregroundColor(Brand.muted)
                }
                Spacer(minLength: 8)
                Picker("Грузчики", selection: binding(\.loaders)) {
                    Text("Нет").tag(0)
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
            }
            if let e = err("loaders") { errorText(e) }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Вес груза, кг").font(.subheadline.weight(.semibold))
                    Text("если знаете").font(.caption).foregroundColor(Brand.muted)
                }
                Spacer(minLength: 8)
                TextField("—", text: kgBinding)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
            }
            if let e = err("cargo_kg") { errorText(e) }
            if cargo?.available == false && state.wantsCargo {
                errorText("Грузовые машины и межгород временно недоступны")
            }
        } header: {
            HStack {
                Text("Машина")
                if loading { Spacer(); ProgressView().controlSize(.small) }
            }
        }
    }

    /// Вес — только цифры, до 5 знаков (как в cargo-picker.js).
    private var kgBinding: Binding<String> {
        Binding(get: { state.cargoKg }, set: { v in
            let digits = String(v.filter { $0.isASCII && $0.isNumber }.prefix(5))
            guard digits != state.cargoKg else { return }
            state.cargoKg = digits
            state.courierId = nil
        })
    }

    // ── Межгород: куда ──────────────────────────────────────────────────────
    private var destSection: some View {
        Section("Куда — город") {
            if citiesLoading && cities.isEmpty {
                HStack { Text("Загружаем города…").foregroundColor(Brand.muted); Spacer(); ProgressView() }
            } else if let e = citiesError, cities.isEmpty {
                errorText(e)
                Button("Повторить") { loadCities() }
            } else {
                NavigationLink {
                    PoolCityPickerView(cities: cities, originCityId: quote.cityId ?? 0,
                                       selectedId: state.destCityId) { city, title in
                        guard state.destCityId != city.id else { return }
                        state.destCityId = city.id
                        state.destCityName = title
                        state.courierId = nil
                    }
                } label: {
                    HStack {
                        Text("Город")
                        Spacer()
                        Text(state.destCityName.isEmpty ? "Выберите город" : state.destCityName)
                            .foregroundColor(state.destCityName.isEmpty ? Brand.muted : Brand.text)
                            .lineLimit(1)
                    }
                }
            }
            if state.destCityId != nil, let e = err("dest_city_id") { errorText(e) }
            if state.destCityId != nil, quoteFresh, let km = cargo?.distanceKm, km > 0, err("dest_city_id") == nil {
                Text("≈ \(Int(km.rounded())) км по дороге").font(.subheadline).foregroundColor(Brand.text)
            }
        }
    }

    // ── Межгород: водители ──────────────────────────────────────────────────
    private var driversSection: some View {
        Section {
            Button {
                state.courierId = nil
            } label: {
                choiceRow(selected: state.courierId == nil) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Любой водитель").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                        Text("Разошлём всем, кто ездит по межгороду, — по вашей цене")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                } price: {
                    if let s = cargo?.suggestedFee, s > 0 { Text(PoolCargoFmt.rub(s)) }
                }
            }
            .buttonStyle(.plain)
            ForEach(drivers) { d in
                Button {
                    state.courierId = d.courierId
                } label: {
                    driverRow(d)
                }
                .buttonStyle(.plain)
            }
            if drivers.isEmpty && !loading {
                Text("Водителей межгорода с подходящей машиной в вашем городе пока нет — отправьте «Любому водителю».")
                    .font(.footnote).foregroundColor(Brand.muted)
            }
            if let e = err("courier_id") { errorText(e) }
            if pickupNow, let id = state.courierId, drivers.first(where: { $0.courierId == id })?.busy == true {
                Text("Водитель сейчас в рейсе: поездку «сейчас» он не возьмёт — укажите время заранее.")
                    .font(.footnote).foregroundColor(Brand.amber)
            }
        } header: {
            Text("Водители — цена по их тарифу")
        }
    }

    private func driverRow(_ d: PoolDriver) -> some View {
        choiceRow(selected: state.courierId == d.courierId) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(d.name ?? "Водитель").font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                    if let r = PoolFmt.rating(d.rating) {
                        Text(r + ((d.ratingCount ?? 0) > 0 ? " (\(d.ratingCount ?? 0))" : ""))
                            .font(.caption).foregroundColor(Brand.amber)
                    }
                    if d.busy == true {
                        tag("сейчас в рейсе", Brand.amber)
                    } else if d.online == true {
                        tag("на линии", Brand.green)
                    }
                }
                Text(machineLine(d)).font(.caption).foregroundColor(Brand.text)
                Text(tariffLine(d)).font(.caption).foregroundColor(Brand.muted)
            }
        } price: {
            Text(PoolCargoFmt.rub(d.total))
        }
    }

    /// «Кузов M · до 700 кг · 260×130×150 см · грузчиков до 1»
    private func machineLine(_ d: PoolDriver) -> String {
        var p: [String] = []
        if let l = d.vehicleLabel, !l.isEmpty { p.append(l) }
        if let kg = d.maxKg, kg > 0 { p.append("до \(kg) кг") }
        if let b = d.body?.text { p.append(b) }
        if let n = d.loaders, n > 0 { p.append("грузчиков до \(n)") }
        return p.joined(separator: " · ")
    }

    /// «Газель, белая · 30 ₽/км, от 3 000 ₽ · доставок 12»
    private func tariffLine(_ d: PoolDriver) -> String {
        var p: [String] = []
        if let c = d.car, !c.isEmpty { p.append(c) }
        var t = PoolCargoFmt.rub(d.kmPrice) + "/км"
        if let m = d.intercityMin, m > 0 { t += ", от " + PoolCargoFmt.rub(m) }
        p.append(t)
        p.append("доставок \(d.deliveriesCount ?? 0)")
        return p.joined(separator: " · ")
    }

    private func choiceRow<L: View, P: View>(selected: Bool, @ViewBuilder label: () -> L,
                                             @ViewBuilder price: () -> P) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 20))
                .foregroundColor(selected ? Brand.accent : Brand.muted)
            label()
            Spacer(minLength: 6)
            price()
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(Brand.text)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundColor(color == Brand.amber ? Brand.text : color)
            .clipShape(Capsule())
    }

    private func errorText(_ s: String) -> some View {
        Text(s).font(.footnote).foregroundColor(Brand.red)
    }
}

enum PoolCargoFmt {
    /// Цена поездки целыми рублями («7 750 ₽»), как money() в cargo-picker.js.
    static func rub(_ v: Decimal?) -> String {
        Money.rub(whole(v ?? 0))
    }

    static func whole(_ v: Decimal) -> Decimal {
        var src = v
        var out = Decimal()
        NSDecimalRound(&out, &src, 0, .plain)
        return out
    }
}

// ── Кузов схемой: рисуем сами (коробка с размерами, кабина, колёса) ────────
struct PoolBodyIllustration: View {
    let vehicle: PoolVehicle

    var body: some View {
        Canvas { ctx, size in
            if (vehicle.code ?? "car") == "car" {
                drawCar(ctx, size)
            } else {
                drawTruck(ctx, size)
            }
        }
        .accessibilityLabel(Text(accessibility))
    }

    private var accessibility: String {
        var s = vehicle.label ?? ""
        if let t = vehicle.body?.text { s += ", кузов " + t }
        return s + ", максимум \(vehicle.maxKg ?? 0) кг"
    }

    private func drawCar(_ ctx: GraphicsContext, _ size: CGSize) {
        // Простой силуэт: кузов, крыша со стёклами, два колеса.
        let w = min(size.width, 300), x0 = (size.width - w) / 2
        let s = w / 300, base = size.height - 26
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x0 + x * s, y: base - y * s) }
        var body = Path()
        body.move(to: p(40, 10))
        body.addLine(to: p(40, 34))
        body.addQuadCurve(to: p(62, 46), control: p(42, 46))
        body.addLine(to: p(100, 50))
        body.addLine(to: p(128, 78))
        body.addLine(to: p(196, 78))
        body.addLine(to: p(226, 50))
        body.addLine(to: p(252, 46))
        body.addQuadCurve(to: p(262, 30), control: p(262, 44))
        body.addLine(to: p(262, 10))
        body.closeSubpath()
        ctx.fill(body, with: .color(Brand.accent.opacity(0.14)))
        ctx.stroke(body, with: .color(Brand.accent), lineWidth: 1.6)
        var glass = Path()
        glass.move(to: p(112, 52)); glass.addLine(to: p(132, 72)); glass.addLine(to: p(158, 72)); glass.addLine(to: p(158, 52)); glass.closeSubpath()
        glass.move(to: p(166, 52)); glass.addLine(to: p(166, 72)); glass.addLine(to: p(192, 72)); glass.addLine(to: p(212, 52)); glass.closeSubpath()
        ctx.stroke(glass, with: .color(Brand.accent), lineWidth: 1.2)
        wheel(ctx, center: p(88, 10), r: 12 * s)
        wheel(ctx, center: p(214, 10), r: 12 * s)
        ctx.draw(Text("багажник и салон · до \(vehicle.maxKg ?? 50) кг").font(.caption).foregroundColor(Brand.muted),
                 at: CGPoint(x: size.width / 2, y: size.height - 8))
    }

    private func drawTruck(_ ctx: GraphicsContext, _ size: CGSize) {
        let b = vehicle.body
        let L = CGFloat(b?.l ?? 170), W = CGFloat(b?.w ?? 100), H = CGFloat(b?.h ?? 90)
        // Масштаб от размеров кузова: XXL длиннее и выше S, но всё влезает в рамку.
        let l = max(70, min(170, L * 0.34)), h = max(30, min(74, H * 0.36)), d = max(10, min(20, W * 0.09))
        let cab: CGFloat = 46
        let total = l + d + cab + 4
        let x0 = max(30, (size.width - total) / 2 + 10)
        let base = size.height - 22
        let y0 = base - h, xe = x0 + l
        let line = Brand.accent
        // Перед (бок кузова), крыша и торец — три грани коробки.
        let front = Path(CGRect(x: x0, y: y0, width: l, height: h))
        var top = Path()
        top.move(to: CGPoint(x: x0, y: y0)); top.addLine(to: CGPoint(x: x0 + d, y: y0 - d))
        top.addLine(to: CGPoint(x: xe + d, y: y0 - d)); top.addLine(to: CGPoint(x: xe, y: y0)); top.closeSubpath()
        var side = Path()
        side.move(to: CGPoint(x: xe, y: y0)); side.addLine(to: CGPoint(x: xe + d, y: y0 - d))
        side.addLine(to: CGPoint(x: xe + d, y: base - d)); side.addLine(to: CGPoint(x: xe, y: base)); side.closeSubpath()
        ctx.fill(front, with: .color(line.opacity(0.14)))
        ctx.fill(top, with: .color(line.opacity(0.24)))
        ctx.fill(side, with: .color(line.opacity(0.32)))
        for p in [front, top, side] { ctx.stroke(p, with: .color(line), lineWidth: 1.5) }
        // Кабина справа.
        let cx = xe + d + 3
        var cabin = Path()
        cabin.move(to: CGPoint(x: cx, y: base)); cabin.addLine(to: CGPoint(x: cx, y: base - 42))
        cabin.addLine(to: CGPoint(x: cx + 26, y: base - 42)); cabin.addLine(to: CGPoint(x: cx + cab - 4, y: base - 18))
        cabin.addLine(to: CGPoint(x: cx + cab - 4, y: base)); cabin.closeSubpath()
        ctx.fill(cabin, with: .color(Brand.card))
        ctx.stroke(cabin, with: .color(line), lineWidth: 1.5)
        var window = Path()
        window.move(to: CGPoint(x: cx + 6, y: base - 36)); window.addLine(to: CGPoint(x: cx + 24, y: base - 36))
        window.addLine(to: CGPoint(x: cx + 34, y: base - 22)); window.addLine(to: CGPoint(x: cx + 6, y: base - 22)); window.closeSubpath()
        ctx.stroke(window, with: .color(line), lineWidth: 1.2)
        // Земля и колёса.
        var ground = Path()
        ground.move(to: CGPoint(x: x0 - 6, y: base)); ground.addLine(to: CGPoint(x: cx + cab + 2, y: base))
        ctx.stroke(ground, with: .color(line), lineWidth: 1.5)
        wheel(ctx, center: CGPoint(x: x0 + 24, y: base + 5), r: 9)
        wheel(ctx, center: CGPoint(x: cx + 22, y: base + 5), r: 9)
        // Подписи: длина сверху, высота слева, ширина у торца.
        let dims = Color.secondary
        if b?.isValid == true {
            ctx.draw(Text("\(Int(L)) см").font(.caption2.weight(.semibold)).foregroundColor(dims),
                     at: CGPoint(x: x0 + l / 2 + d / 2, y: y0 - d - 9))
            ctx.draw(Text("\(Int(H))").font(.caption2.weight(.semibold)).foregroundColor(dims),
                     at: CGPoint(x: x0 - 6, y: y0 + h / 2), anchor: .trailing)
            ctx.draw(Text("\(Int(W))").font(.caption2.weight(.semibold)).foregroundColor(dims),
                     at: CGPoint(x: xe + d + 4, y: y0 - d - 2), anchor: .bottomLeading)
        }
    }

    private func wheel(_ ctx: GraphicsContext, center: CGPoint, r: CGFloat) {
        let c = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        ctx.fill(c, with: .color(Brand.card))
        ctx.stroke(c, with: .color(Brand.accent), lineWidth: 1.5)
    }
}

// ── Город назначения (межгород) ─────────────────────────────────────────────
struct PoolCityPickerView: View {
    let cities: [PoolCity]
    let originCityId: Int
    let selectedId: Int?
    /// Выбранный город и подпись (с областью, если название повторяется).
    let onPick: (PoolCity, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private struct Row: Identifiable {
        let city: PoolCity
        let title: String
        var id: Int { city.id }
    }

    /// Город отправления — не в списке; одинаковые названия — с областью в скобках.
    private var rows: [Row] {
        let raw = cities.filter { $0.id != originCityId }
        var count: [String: Int] = [:]
        for c in raw { count[c.name ?? "", default: 0] += 1 }
        return raw.map { c in
            let n = c.name ?? ""
            let r = c.region ?? ""
            return Row(city: c, title: (count[n] ?? 0) > 1 && !r.isEmpty ? n + " (" + r + ")" : n)
        }
    }

    private var filtered: [Row] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return rows }
        // Сначала — начинающиеся с введённого, потом — содержащие.
        let starts = rows.filter { $0.title.lowercased().hasPrefix(q) }
        let contains = rows.filter { !$0.title.lowercased().hasPrefix(q) && $0.title.lowercased().contains(q) }
        return starts + contains
    }

    var body: some View {
        List {
            ForEach(filtered) { row in
                Button {
                    onPick(row.city, row.title)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).foregroundColor(Brand.text)
                            if let r = row.city.region, !r.isEmpty, !row.title.contains(r) {
                                Text(r).font(.caption).foregroundColor(Brand.muted)
                            }
                        }
                        Spacer()
                        if row.city.id == selectedId {
                            Image(systemName: "checkmark").foregroundColor(Brand.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if filtered.isEmpty {
                Text("Город не найден — проверьте название").foregroundColor(Brand.muted)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Начните вводить город")
        .navigationTitle("Куда — город")
        .navigationBarTitleDisplayMode(.inline)
    }
}
