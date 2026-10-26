import Foundation

// ============================================================================
//  «Курьеры Yumurta» (волны А77–А78) — общий пул курьеров площадки.
//  Сервер: routes/courier_pool.php (/api/v1/seller/pool/*), логика и формы
//  ответов — core/CourierPool.php (sellerView, quote, sellerCouriers,
//  ledgerView). Конверт кабинета {ok, data, error, code, errors}.
//  Все поля необязательные: старый сервер их не шлёт — раздел скрыт.
//  Деньги приходят строками "0.00" — только @LenientDecimal.
//  Даты — ISO 8601 (date('c')), а не «Y-m-d H:i:s», — см. PoolFmt.
// ============================================================================

/// Что можно сделать с вызовом сейчас (sellerView → can).
struct PoolCan: Decodable, Hashable {
    @LenientBool var cancel: Bool?
    @LenientBool var changeFee: Bool?
    @LenientBool var retry: Bool?
    @LenientBool var unassign: Bool?
    @LenientBool var rate: Bool?
    @LenientBool var problem: Bool?
    @LenientBool var confirmQr: Bool?
    /// А80: выбранный водитель межгорода не подтвердил — «Выбрать другого водителя» (новый вызов).
    @LenientBool var chooseDriver: Bool?
    /// А81: «Пожаловаться на курьера» — жалобы ещё нет, курьер есть, вызову меньше 30 дней.
    @LenientBool var complain: Bool?
    /// А87 (П-44 №2): показывать ли «Не пришла» (после отметки — false, «Пришла» остаётся).
    /// nil — старый сервер поля не шлёт: кнопка — как раньше, вместе с «Пришла» (confirm_qr).
    @LenientBool var qrMissing: Bool?

    enum CodingKeys: String, CodingKey {
        case cancel, retry, unassign, rate, problem, complain
        case changeFee = "change_fee"
        case confirmQr = "confirm_qr"
        case chooseDriver = "choose_driver"
        case qrMissing = "qr_missing"
    }
}

/// Курьер, который везёт заказ (sellerView → courier).
struct PoolCourierInfo: Decodable, Hashable {
    @LenientInt var userId: Int?
    @LenientString var name: String?
    @LenientString var phone: String?
    @LenientString var car: String?
    @LenientString var carModel: String?
    @LenientString var carColor: String?
    @LenientString var carPlate: String?
    /// Средняя оценка с одним знаком (4.5) или null.
    @LenientDouble var rating: Double?
    @LenientInt var deliveriesCount: Int?
    @LenientBool var hasPhoto: Bool?
    @LenientInt var etaMinutes: Int?
    @LenientString var locationAt: String?
    /// Сальдо пары: «+» — курьер должен заведению.
    @LenientDecimal var balance: Decimal?
    /// А80: кузов машины курьера («Кузов M»).
    @LenientString var vehicleLabel: String?

    enum CodingKeys: String, CodingKey {
        case name, phone, car, rating, balance
        case vehicleLabel = "vehicle_label"
        case userId = "user_id"
        case carModel = "car_model"
        case carColor = "car_color"
        case carPlate = "car_plate"
        case deliveriesCount = "deliveries_count"
        case hasPhoto = "has_photo"
        case etaMinutes = "eta_minutes"
        case locationAt = "location_at"
    }

    /// «Kia Rio, белая» без номера — номер показываем отдельно и крупно.
    var carText: String {
        let parts = [carModel, carColor].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
        return car ?? ""
    }
}

/// Вызов курьера глазами заведения (CourierPool::sellerView).
struct PoolCall: Decodable, Identifiable, Hashable {
    @LenientInt var id: Int?
    @LenientString var status: String?
    @LenientString var statusLabel: String?
    @LenientInt var orderId: Int?
    @LenientInt var orderNumber: Int?
    @LenientString var title: String?
    @LenientString var pickupAddress: String?
    @LenientString var pickupAt: String?
    @LenientString var dropAddress: String?
    @LenientString var dropHint: String?
    @LenientString var clientName: String?
    @LenientString var clientPhone: String?
    @LenientString var comment: String?
    @LenientInt var itemsCount: Int?
    @LenientDecimal var goodsAmount: Decimal?
    @LenientString var paymentMode: String?      // prepaid | collect
    @LenientDecimal var collectAmount: Decimal?
    @LenientDecimal var fee: Decimal?
    @LenientString var feePayer: String?         // client | shop
    @LenientDouble var distanceKm: Double?
    @LenientInt var attempts: Int?
    @LenientString var createdAt: String?
    @LenientString var expiresAt: String?
    @LenientString var acceptedAt: String?
    @LenientString var arrivedAt: String?
    @LenientString var pickedAt: String?
    @LenientString var deliveredAt: String?
    @LenientString var closedAt: String?
    @LenientString var paidMethod: String?       // cash | qr | null
    @LenientBool var qrConfirmed: Bool?
    @LenientString var cancelReason: String?
    @LenientString var failReason: String?
    @LenientInt var rating: Int?
    @LenientString var ratingComment: String?
    @LenientInt var offeredTo: Int?
    // А80: кузов, вес, грузчики, межгород, выбранный водитель (CourierPool::cargoView).
    @LenientString var vehicleClass: String?     // car | s | m | l | xl | xxl
    @LenientString var vehicleLabel: String?
    @LenientInt var cargoKg: Int?
    @LenientInt var loaders: Int?
    @LenientString var trip: String?             // city | intercity
    @LenientInt var destCityId: Int?
    @LenientString var destCity: String?
    @LenientInt var targetCourierId: Int?
    var can: PoolCan?
    var courier: PoolCourierInfo?
    /// Кому предложили межгород, пока не ответил (sellerView → target).
    var target: PoolTarget?
    /// А81: своя жалоба на курьера (complaintBrief) или nil. Старый сервер не шлёт — строки нет.
    var complaint: PoolComplaintBrief?
    /// А87 (П-44 №2), аддитивно: заведение уже отметило «Не пришла» (и после этого не «Пришла»);
    /// qrMissingAt — когда. Старый сервер не шлёт — nil, всё как раньше.
    @LenientBool var qrMissing: Bool?
    @LenientString var qrMissingAt: String?
    /// Ответ POST …/qr: повторное «Не пришла» (или оплата уже подтверждена) — already: true, это успех.
    @LenientBool var already: Bool?

    enum CodingKeys: String, CodingKey {
        case id, status, title, comment, fee, attempts, rating, can, courier, complaint, already
        case qrMissing = "qr_missing"
        case qrMissingAt = "qr_missing_at"
        case statusLabel = "status_label"
        case orderId = "order_id"
        case orderNumber = "order_number"
        case pickupAddress = "pickup_address"
        case pickupAt = "pickup_at"
        case dropAddress = "drop_address"
        case dropHint = "drop_hint"
        case clientName = "client_name"
        case clientPhone = "client_phone"
        case itemsCount = "items_count"
        case goodsAmount = "goods_amount"
        case paymentMode = "payment_mode"
        case collectAmount = "collect_amount"
        case feePayer = "fee_payer"
        case distanceKm = "distance_km"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case arrivedAt = "arrived_at"
        case pickedAt = "picked_at"
        case deliveredAt = "delivered_at"
        case closedAt = "closed_at"
        case paidMethod = "paid_method"
        case qrConfirmed = "qr_confirmed"
        case cancelReason = "cancel_reason"
        case failReason = "fail_reason"
        case ratingComment = "rating_comment"
        case offeredTo = "offered_to"
        case vehicleClass = "vehicle_class"
        case vehicleLabel = "vehicle_label"
        case cargoKg = "cargo_kg"
        case loaders, trip, target
        case destCityId = "dest_city_id"
        case destCity = "dest_city"
        case targetCourierId = "target_courier_id"
    }

    // Свой разбор — ради can и courier: их чужой тип не должен ронять вызов.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(LenientInt.self, forKey: .id)
        _status = try c.decode(LenientString.self, forKey: .status)
        _statusLabel = try c.decode(LenientString.self, forKey: .statusLabel)
        _orderId = try c.decode(LenientInt.self, forKey: .orderId)
        _orderNumber = try c.decode(LenientInt.self, forKey: .orderNumber)
        _title = try c.decode(LenientString.self, forKey: .title)
        _pickupAddress = try c.decode(LenientString.self, forKey: .pickupAddress)
        _pickupAt = try c.decode(LenientString.self, forKey: .pickupAt)
        _dropAddress = try c.decode(LenientString.self, forKey: .dropAddress)
        _dropHint = try c.decode(LenientString.self, forKey: .dropHint)
        _clientName = try c.decode(LenientString.self, forKey: .clientName)
        _clientPhone = try c.decode(LenientString.self, forKey: .clientPhone)
        _comment = try c.decode(LenientString.self, forKey: .comment)
        _itemsCount = try c.decode(LenientInt.self, forKey: .itemsCount)
        _goodsAmount = try c.decode(LenientDecimal.self, forKey: .goodsAmount)
        _paymentMode = try c.decode(LenientString.self, forKey: .paymentMode)
        _collectAmount = try c.decode(LenientDecimal.self, forKey: .collectAmount)
        _fee = try c.decode(LenientDecimal.self, forKey: .fee)
        _feePayer = try c.decode(LenientString.self, forKey: .feePayer)
        _distanceKm = try c.decode(LenientDouble.self, forKey: .distanceKm)
        _attempts = try c.decode(LenientInt.self, forKey: .attempts)
        _createdAt = try c.decode(LenientString.self, forKey: .createdAt)
        _expiresAt = try c.decode(LenientString.self, forKey: .expiresAt)
        _acceptedAt = try c.decode(LenientString.self, forKey: .acceptedAt)
        _arrivedAt = try c.decode(LenientString.self, forKey: .arrivedAt)
        _pickedAt = try c.decode(LenientString.self, forKey: .pickedAt)
        _deliveredAt = try c.decode(LenientString.self, forKey: .deliveredAt)
        _closedAt = try c.decode(LenientString.self, forKey: .closedAt)
        _paidMethod = try c.decode(LenientString.self, forKey: .paidMethod)
        _qrConfirmed = try c.decode(LenientBool.self, forKey: .qrConfirmed)
        _cancelReason = try c.decode(LenientString.self, forKey: .cancelReason)
        _failReason = try c.decode(LenientString.self, forKey: .failReason)
        _rating = try c.decode(LenientInt.self, forKey: .rating)
        _ratingComment = try c.decode(LenientString.self, forKey: .ratingComment)
        _offeredTo = try c.decode(LenientInt.self, forKey: .offeredTo)
        _vehicleClass = try c.decode(LenientString.self, forKey: .vehicleClass)
        _vehicleLabel = try c.decode(LenientString.self, forKey: .vehicleLabel)
        _cargoKg = try c.decode(LenientInt.self, forKey: .cargoKg)
        _loaders = try c.decode(LenientInt.self, forKey: .loaders)
        _trip = try c.decode(LenientString.self, forKey: .trip)
        _destCityId = try c.decode(LenientInt.self, forKey: .destCityId)
        _destCity = try c.decode(LenientString.self, forKey: .destCity)
        _targetCourierId = try c.decode(LenientInt.self, forKey: .targetCourierId)
        _qrMissing = try c.decode(LenientBool.self, forKey: .qrMissing)
        _qrMissingAt = try c.decode(LenientString.self, forKey: .qrMissingAt)
        _already = try c.decode(LenientBool.self, forKey: .already)
        target = (try? c.decodeIfPresent(PoolTarget.self, forKey: .target)) ?? nil
        // Чужой тип вложенного объекта не роняет карточку вызова целиком.
        can = (try? c.decodeIfPresent(PoolCan.self, forKey: .can)) ?? nil
        courier = (try? c.decodeIfPresent(PoolCourierInfo.self, forKey: .courier)) ?? nil
        complaint = (try? c.decodeIfPresent(PoolComplaintBrief.self, forKey: .complaint)) ?? nil
    }

    var callId: Int { id ?? 0 }
    /// Вызов ещё живой: ищем курьера, курьер едет в заведение или везёт заказ.
    var isLive: Bool { PoolCall.liveStatuses.contains(status ?? "") }
    static let liveStatuses: Set<String> = ["searching", "accepted", "picked"]

    var statusText: String {
        if let l = statusLabel?.trimmingCharacters(in: .whitespaces), !l.isEmpty { return l }
        return PoolCall.labels[status ?? ""] ?? (status ?? "")
    }

    /// Подписи статусов — копия CourierPool::CALL_LABELS на случай пустого status_label.
    static let labels: [String: String] = [
        "searching": "Ищем курьера", "accepted": "Курьер едет в заведение", "picked": "Курьер везёт заказ",
        "delivered": "Доставлено", "failed": "Не доставлен — заказ возвращается", "cancelled": "Отменён",
        "expired": "Никто не взял",
    ]

    var displayTitle: String {
        if let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty { return t }
        if let n = orderNumber ?? orderId { return "Заказ №\(n)" }
        return "Доставка №\(callId)"
    }

    var isIntercity: Bool { trip == "intercity" }
    /// Водитель выбран заранее (межгород): цена — по его тарифу, «поднять цену» нельзя.
    var hasFixedTarget: Bool { (targetCourierId ?? 0) > 0 }

    /// Машина и маршрут одной строкой (как cargoLine в seller-pool.js):
    /// «Кузов M, 300 кг · грузчики: 1 · межгород → Ростов-на-Дону (≈ 210 км)». Пусто — легковая по городу.
    var cargoSummary: String {
        var p: [String] = []
        let kg = (cargoKg ?? 0) > 0 ? "\(cargoKg ?? 0) кг" : nil
        if let vc = vehicleClass, !vc.isEmpty, vc != "car" {
            let label = (vehicleLabel?.isEmpty == false ? vehicleLabel : nil) ?? vc.uppercased()
            p.append(label + (kg.map { ", " + $0 } ?? ""))
        } else if let kg {
            p.append(kg)
        }
        if let l = loaders, l > 0 { p.append("грузчики: \(l)") }
        if isIntercity {
            var s = "межгород → " + (destCity ?? "")
            if let km = distanceKm, km > 0 { s += " (≈ \(Int(km.rounded())) км)" }
            p.append(s)
        }
        return p.joined(separator: " · ")
    }
}

/// А81: своя жалоба по вызову (CourierPool::complaintBrief). status: open | closed;
/// status_label — «Рассматривает администратор» / «Рассмотрена: …».
struct PoolComplaintBrief: Decodable, Hashable {
    @LenientInt var id: Int?
    @LenientString var status: String?
    @LenientString var statusLabel: String?
    @LenientString var reason: String?
    @LenientString var reasonLabel: String?
    @LenientString var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, status, reason
        case statusLabel = "status_label"
        case reasonLabel = "reason_label"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(LenientInt.self, forKey: .id)
        _status = try c.decode(LenientString.self, forKey: .status)
        _statusLabel = try c.decode(LenientString.self, forKey: .statusLabel)
        _reason = try c.decode(LenientString.self, forKey: .reason)
        _reasonLabel = try c.decode(LenientString.self, forKey: .reasonLabel)
        _createdAt = try c.decode(LenientString.self, forKey: .createdAt)
    }

    /// «Грубил — Рассматривает администратор» (строка «Жалоба: …» в карточке, как в вебе).
    var line: String {
        [reasonLabel, statusLabel].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

/// А81: GET /api/v1/pool/rules (v1-конверт, без входа; CourierPool::rulesBlock) —
/// правило сервиса и причины жалоб. Продавцу нужны текст и complaint_reasons.courier
/// (жалоба НА КУРЬЕРА); details и required — для курьера, не читаем.
struct PoolRules: Decodable {
    @LenientString var version: String?
    @LenientString var text: String?
    /// Причины жалобы на курьера: код → подпись, по порядку (см. courierOrder).
    let courierReasons: [(code: String, label: String)]

    enum CodingKeys: String, CodingKey {
        case version, text
        case complaintReasons = "complaint_reasons"
    }

    private struct Reasons: Decodable {
        let courier: [String: PoolTextList]?
    }

    /// Порядок причин как на сервере (CourierPool::COMPLAINT_REASONS['courier']):
    /// словарь Swift порядок не хранит. Новые коды — перед «Другое».
    static let courierOrder = ["passenger", "rude", "unsafe", "extra_money"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _version = try c.decode(LenientString.self, forKey: .version)
        _text = try c.decode(LenientString.self, forKey: .text)
        let raw = ((try? c.decodeIfPresent(Reasons.self, forKey: .complaintReasons)) ?? nil)?.courier ?? [:]
        let pairs = raw.compactMap { k, v -> (code: String, label: String)? in
            let l = (v.items.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return k.isEmpty || l.isEmpty ? nil : (k, l)
        }
        func rank(_ k: String) -> Int {
            if k == "other" { return Int.max }
            return PoolRules.courierOrder.firstIndex(of: k) ?? PoolRules.courierOrder.count
        }
        courierReasons = pairs.sorted { a, b in
            let ra = rank(a.code), rb = rank(b.code)
            return ra != rb ? ra < rb : a.code < b.code
        }
    }
}

/// А80: размеры кузова, см (Д×Ш×В).
struct PoolBody: Decodable, Hashable {
    @LenientInt var l: Int?
    @LenientInt var w: Int?
    @LenientInt var h: Int?

    enum CodingKeys: String, CodingKey { case l, w, h }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _l = try c.decode(LenientInt.self, forKey: .l)
        _w = try c.decode(LenientInt.self, forKey: .w)
        _h = try c.decode(LenientInt.self, forKey: .h)
    }

    init(l: Int?, w: Int?, h: Int?) {
        _l = LenientInt(wrappedValue: l)
        _w = LenientInt(wrappedValue: w)
        _h = LenientInt(wrappedValue: h)
    }

    var isValid: Bool { (l ?? 0) > 0 && (w ?? 0) > 0 && (h ?? 0) > 0 }
    /// «260×130×150 см»
    var text: String? { isValid ? "\(l ?? 0)×\(w ?? 0)×\(h ?? 0) см" : nil }
}

/// Водитель, которому предложили межгород (sellerView → target): имя, машина, рейтинг.
struct PoolTarget: Decodable, Hashable {
    @LenientInt var courierId: Int?
    @LenientString var name: String?
    @LenientString var car: String?
    @LenientDouble var rating: Double?
    @LenientString var vehicleLabel: String?
    @LenientInt var maxKg: Int?

    enum CodingKeys: String, CodingKey {
        case name, car, rating
        case courierId = "courier_id"
        case vehicleLabel = "vehicle_label"
        case maxKg = "max_kg"
    }
}

/// Поле pool_call карточки заказа: null — вызовов не было. Если сервер пришлёт
/// что-то неожиданное, карточка заказа всё равно откроется (call = nil).
struct PoolCallBox: Decodable {
    let call: PoolCall?
    init(from decoder: Decoder) throws {
        call = try? PoolCall(from: decoder)
    }
}

// ── Окно «Вызвать курьера» (CourierPool::quote) ─────────────────────────────
struct PoolQuote: Decodable {
    @LenientBool var enabled: Bool?
    @LenientDecimal var minFee: Decimal?
    @LenientDecimal var maxFee: Decimal?
    @LenientInt var searchMinutes: Int?
    @LenientInt var couriersOnline: Int?
    @LenientBool var qrSet: Bool?
    /// А81: правило сервиса («только грузы и посылки…») — плашка в окне вызова. nil — плашки нет.
    @LenientString var rule: String?
    var defaults: PoolQuoteDefaults?
    var order: PoolQuoteOrder?
    // А80 (CourierPool::cargoQuote). Старый сервер не шлёт — выбора машины нет.
    @LenientInt var cityId: Int?
    var vehicles: [PoolVehicle]?
    @LenientBool var intercityEnabled: Bool?
    @LenientDecimal var loaderPrice: Decimal?
    var cargo: PoolCargoQuote?
    var drivers: [PoolDriver]?
    /// А101: вызов «на потом» — {from_min, lead_min, max_hours, remind}. nil — старый сервер
    /// (или не объект): «Когда забрать» и подсказки как были.
    var scheduledSearch: PoolSchedSearch?

    enum CodingKeys: String, CodingKey {
        case enabled, defaults, order, vehicles, cargo, drivers, rule
        case scheduledSearch = "scheduled_search"
        case minFee = "min_fee"
        case maxFee = "max_fee"
        case searchMinutes = "search_minutes"
        case couriersOnline = "couriers_online"
        case qrSet = "qr_set"
        case cityId = "city_id"
        case intercityEnabled = "intercity_enabled"
        case loaderPrice = "loader_price"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _enabled = try c.decode(LenientBool.self, forKey: .enabled)
        _minFee = try c.decode(LenientDecimal.self, forKey: .minFee)
        _maxFee = try c.decode(LenientDecimal.self, forKey: .maxFee)
        _searchMinutes = try c.decode(LenientInt.self, forKey: .searchMinutes)
        _couriersOnline = try c.decode(LenientInt.self, forKey: .couriersOnline)
        _qrSet = try c.decode(LenientBool.self, forKey: .qrSet)
        _rule = try c.decode(LenientString.self, forKey: .rule)
        defaults = (try? c.decodeIfPresent(PoolQuoteDefaults.self, forKey: .defaults)) ?? nil
        order = (try? c.decodeIfPresent(PoolQuoteOrder.self, forKey: .order)) ?? nil
        _cityId = try c.decode(LenientInt.self, forKey: .cityId)
        _intercityEnabled = try c.decode(LenientBool.self, forKey: .intercityEnabled)
        _loaderPrice = try c.decode(LenientDecimal.self, forKey: .loaderPrice)
        // Списки — поштучно: чужой элемент не роняет окно вызова.
        vehicles = (try? c.decodeIfPresent([PoolLossy<PoolVehicle>].self, forKey: .vehicles))?
            .compactMap { $0.value }.filter { !($0.code ?? "").isEmpty }
        cargo = (try? c.decodeIfPresent(PoolCargoQuote.self, forKey: .cargo)) ?? nil
        drivers = (try? c.decodeIfPresent([PoolLossy<PoolDriver>].self, forKey: .drivers))?
            .compactMap { $0.value }.filter { ($0.courierId ?? 0) > 0 }
        // Кривое поле (массив, false, строка) не роняет окно вызова — просто «как было».
        scheduledSearch = (try? c.decodeIfPresent(PoolSchedSearch.self, forKey: .scheduledSearch)) ?? nil
    }

    /// Сервер умеет кузова, грузчиков и межгород (А80).
    var cargoSupported: Bool { !(vehicles ?? []).isEmpty }
}

/// А101: правила поиска «на потом» (CourierPool::schedQuote). Значения по умолчанию — как
/// в веб-кабинете (seller-pool.js whenHint): from_min 0 → 30, max_hours 0 → 24, нет lead_min → 0,
/// напоминания выключены только явным false.
struct PoolSchedSearch: Decodable {
    @LenientInt var fromMin: Int?
    @LenientInt var leadMin: Int?
    @LenientInt var maxHours: Int?
    @LenientBool var remind: Bool?

    enum CodingKeys: String, CodingKey {
        case remind
        case fromMin = "from_min"
        case leadMin = "lead_min"
        case maxHours = "max_hours"
    }

    init(fromMin: Int? = nil, leadMin: Int? = nil, maxHours: Int? = nil, remind: Bool? = nil) {
        _fromMin = LenientInt(wrappedValue: fromMin)
        _leadMin = LenientInt(wrappedValue: leadMin)
        _maxHours = LenientInt(wrappedValue: maxHours)
        _remind = LenientBool(wrappedValue: remind)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _fromMin = try c.decode(LenientInt.self, forKey: .fromMin)
        _leadMin = try c.decode(LenientInt.self, forKey: .leadMin)
        _maxHours = try c.decode(LenientInt.self, forKey: .maxHours)
        _remind = try c.decode(LenientBool.self, forKey: .remind)
    }

    var from: Int { fromMin.flatMap { $0 != 0 ? $0 : nil } ?? 30 }
    var lead: Int { leadMin ?? 0 }
    var hours: Int { maxHours.flatMap { $0 != 0 ? $0 : nil } ?? 24 }
    var remindOn: Bool { remind != false }
}

/// Элемент списка, который при чужом типе становится nil, а не роняет весь список.
struct PoolLossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Кузов для экрана вызова (CourierPool::vehicleList).
struct PoolVehicle: Decodable, Hashable {
    @LenientString var code: String?
    @LenientString var label: String?
    @LenientString var hint: String?
    @LenientInt var maxKg: Int?
    var body: PoolBody?
    @LenientDecimal var cityPrice: Decimal?

    enum CodingKeys: String, CodingKey {
        case code, label, hint, body
        case maxKg = "max_kg"
        case cityPrice = "city_price"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _code = try c.decode(LenientString.self, forKey: .code)
        _label = try c.decode(LenientString.self, forKey: .label)
        _hint = try c.decode(LenientString.self, forKey: .hint)
        _maxKg = try c.decode(LenientInt.self, forKey: .maxKg)
        body = (try? c.decodeIfPresent(PoolBody.self, forKey: .body)) ?? nil
        _cityPrice = try c.decode(LenientDecimal.self, forKey: .cityPrice)
    }

    /// Подпись на сегменте: «Авто», «S» … «XXL».
    var short: String {
        let c = code ?? ""
        return c == "car" ? "Авто" : c.uppercased()
    }
}

/// Груз в подсказках (quote → cargo). errors — ошибки ввода, пока форма не готова (не 422).
struct PoolCargoQuote: Decodable {
    @LenientBool var available: Bool?
    @LenientString var vehicleClass: String?
    @LenientInt var cargoKg: Int?
    @LenientInt var loaders: Int?
    @LenientString var trip: String?
    @LenientInt var destCityId: Int?
    @LenientString var destCity: String?
    @LenientDouble var distanceKm: Double?
    @LenientDecimal var suggestedFee: Decimal?
    @LenientDecimal var maxFee: Decimal?
    var errors: [String: [String]] = [:]

    enum CodingKeys: String, CodingKey {
        case available, loaders, trip, errors
        case vehicleClass = "vehicle_class"
        case cargoKg = "cargo_kg"
        case destCityId = "dest_city_id"
        case destCity = "dest_city"
        case distanceKm = "distance_km"
        case suggestedFee = "suggested_fee"
        case maxFee = "max_fee"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _available = try c.decode(LenientBool.self, forKey: .available)
        _vehicleClass = try c.decode(LenientString.self, forKey: .vehicleClass)
        _cargoKg = try c.decode(LenientInt.self, forKey: .cargoKg)
        _loaders = try c.decode(LenientInt.self, forKey: .loaders)
        _trip = try c.decode(LenientString.self, forKey: .trip)
        _destCityId = try c.decode(LenientInt.self, forKey: .destCityId)
        _destCity = try c.decode(LenientString.self, forKey: .destCity)
        _distanceKm = try c.decode(LenientDouble.self, forKey: .distanceKm)
        _suggestedFee = try c.decode(LenientDecimal.self, forKey: .suggestedFee)
        _maxFee = try c.decode(LenientDecimal.self, forKey: .maxFee)
        // {} или {поле: ["текст"]} (бывает и строкой); пустой массив PHP [] — тоже «нет ошибок».
        errors = ((try? c.decodeIfPresent([String: PoolTextList].self, forKey: .errors)) ?? nil)?
            .compactMapValues { $0.items.isEmpty ? nil : $0.items } ?? [:]
    }

    func error(_ field: String) -> String? { errors[field]?.first }
}

/// Текст или список текстов.
struct PoolTextList: Decodable {
    let items: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { items = [s] }
        else if let a = try? c.decode([String].self) { items = a }
        else { items = [] }
    }
}

/// Водитель межгорода с ценой по его тарифу (CourierPool::intercityDrivers).
struct PoolDriver: Decodable, Hashable, Identifiable {
    @LenientInt var courierId: Int?
    @LenientString var name: String?
    @LenientDouble var rating: Double?
    @LenientInt var ratingCount: Int?
    @LenientInt var deliveriesCount: Int?
    @LenientBool var online: Bool?
    /// «Сейчас в рейсе»: поездку «сейчас» не возьмёт, заранее — возьмёт.
    @LenientBool var busy: Bool?
    @LenientString var car: String?
    @LenientString var vehicleClass: String?
    @LenientString var vehicleLabel: String?
    @LenientInt var maxKg: Int?
    var body: PoolBody?
    @LenientInt var loaders: Int?
    @LenientDecimal var kmPrice: Decimal?
    @LenientDecimal var intercityMin: Decimal?
    @LenientDecimal var total: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, rating, online, busy, car, body, loaders, total
        case courierId = "courier_id"
        case ratingCount = "rating_count"
        case deliveriesCount = "deliveries_count"
        case vehicleClass = "vehicle_class"
        case vehicleLabel = "vehicle_label"
        case maxKg = "max_kg"
        case kmPrice = "km_price"
        case intercityMin = "intercity_min"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _courierId = try c.decode(LenientInt.self, forKey: .courierId)
        _name = try c.decode(LenientString.self, forKey: .name)
        _rating = try c.decode(LenientDouble.self, forKey: .rating)
        _ratingCount = try c.decode(LenientInt.self, forKey: .ratingCount)
        _deliveriesCount = try c.decode(LenientInt.self, forKey: .deliveriesCount)
        _online = try c.decode(LenientBool.self, forKey: .online)
        _busy = try c.decode(LenientBool.self, forKey: .busy)
        _car = try c.decode(LenientString.self, forKey: .car)
        _vehicleClass = try c.decode(LenientString.self, forKey: .vehicleClass)
        _vehicleLabel = try c.decode(LenientString.self, forKey: .vehicleLabel)
        _maxKg = try c.decode(LenientInt.self, forKey: .maxKg)
        body = (try? c.decodeIfPresent(PoolBody.self, forKey: .body)) ?? nil
        _loaders = try c.decode(LenientInt.self, forKey: .loaders)
        _kmPrice = try c.decode(LenientDecimal.self, forKey: .kmPrice)
        _intercityMin = try c.decode(LenientDecimal.self, forKey: .intercityMin)
        _total = try c.decode(LenientDecimal.self, forKey: .total)
    }

    var id: Int { courierId ?? 0 }
}

/// Город для «Межгород — куда» (GET /api/v1/cities).
struct PoolCity: Decodable, Hashable, Identifiable {
    @LenientInt var cityId: Int?
    @LenientString var name: String?
    @LenientString var region: String?

    enum CodingKeys: String, CodingKey {
        case name, region
        case cityId = "id"
    }

    var id: Int { cityId ?? 0 }
}

struct PoolQuoteDefaults: Decodable {
    @LenientDecimal var goodsAmount: Decimal?
    @LenientDecimal var fee: Decimal?
    @LenientString var feePayer: String?
    @LenientString var paymentMode: String?
    @LenientDecimal var collectAmount: Decimal?
    @LenientString var dropAddress: String?
    @LenientDouble var distanceKm: Double?
    @LenientDecimal var freeFrom: Decimal?

    enum CodingKeys: String, CodingKey {
        case fee
        case goodsAmount = "goods_amount"
        case feePayer = "fee_payer"
        case paymentMode = "payment_mode"
        case collectAmount = "collect_amount"
        case dropAddress = "drop_address"
        case distanceKm = "distance_km"
        case freeFrom = "free_from"
    }
}

struct PoolQuoteOrder: Decodable {
    @LenientInt var id: Int?
    @LenientInt var dailyNumber: Int?
    @LenientInt var activeCallId: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case dailyNumber = "daily_number"
        case activeCallId = "active_call_id"
    }
}

// ── Расчёты с курьерами (sellerCouriers, ledgerView) ────────────────────────
struct PoolLedgerEntry: Decodable, Identifiable, Hashable {
    @LenientInt var id: Int?
    @LenientInt var courierId: Int?
    @LenientInt var callId: Int?
    @LenientString var kind: String?
    @LenientString var kindLabel: String?
    /// Сумма записи как в базе: «+» — курьер должен заведению больше.
    @LenientDecimal var amount: Decimal?
    /// Для экрана заведения: «+» — курьер должен вам больше.
    @LenientDecimal var amountForMe: Decimal?
    @LenientString var status: String?           // active | pending | rejected | void
    @LenientString var side: String?
    @LenientString var note: String?
    @LenientString var createdAt: String?
    @LenientBool var needsMyDecision: Bool?

    enum CodingKeys: String, CodingKey {
        case id, kind, amount, status, side, note
        case courierId = "courier_id"
        case callId = "call_id"
        case kindLabel = "kind_label"
        case amountForMe = "amount_for_me"
        case createdAt = "created_at"
        case needsMyDecision = "needs_my_decision"
    }
}

struct PoolQrPending: Decodable, Hashable {
    @LenientInt var callId: Int?
    @LenientDecimal var amount: Decimal?
    @LenientString var deliveredAt: String?
    // А86 (П-43 №3), аддитивно — у старого сервера полей нет (nil), тогда всё как раньше:
    // missing — заведение уже отметило «не пришла» (missingAt — когда);
    // countsAsDebt — сумма снова в долгу курьера: «не пришла» или срок удержания прошёл.
    @LenientBool var missing: Bool?
    @LenientString var missingAt: String?
    @LenientBool var countsAsDebt: Bool?
    /// А87 (П-44 №4): когда сумма пойдёт в долг курьера, если её не подтвердить (доставка +
    /// hold_hours); nil — уже в долге («не пришла» или срок прошёл) или старый сервер.
    @LenientString var debtAt: String?

    enum CodingKeys: String, CodingKey {
        case amount, missing
        case callId = "call_id"
        case deliveredAt = "delivered_at"
        case missingAt = "missing_at"
        case countsAsDebt = "counts_as_debt"
        case debtAt = "debt_at"
    }
}

struct PoolCourierBalance: Decodable, Identifiable {
    @LenientInt var userId: Int?
    @LenientString var name: String?
    @LenientString var phone: String?
    @LenientString var car: String?
    @LenientString var status: String?
    @LenientDouble var rating: Double?
    @LenientInt var deliveriesHere: Int?
    @LenientDecimal var balance: Decimal?
    @LenientDecimal var courierOwes: Decimal?
    @LenientDecimal var shopOwes: Decimal?
    @LenientString var since: String?
    var pending: [PoolLedgerEntry]?
    var qrPending: [PoolQrPending]?
    /// А91: сколько заведение ещё должно курьеру «за доставку» с учётом «Отдали за доставку»,
    /// которые ждут курьера (CourierPool::settleRoom). "0.00" — кнопку «Отдали за доставку»
    /// прячем; nil — старый сервер поля не шлёт: всё как раньше. «Получили деньги от курьера»
    /// (cash_received) не ограничен — cash_max продавцу не нужен.
    @LenientDecimal var feeMax: Decimal?

    enum CodingKeys: String, CodingKey {
        case name, phone, car, status, rating, balance, since, pending
        case userId = "user_id"
        case deliveriesHere = "deliveries_here"
        case courierOwes = "courier_owes"
        case shopOwes = "shop_owes"
        case qrPending = "qr_pending"
        case feeMax = "fee_max"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _userId = try c.decode(LenientInt.self, forKey: .userId)
        _name = try c.decode(LenientString.self, forKey: .name)
        _phone = try c.decode(LenientString.self, forKey: .phone)
        _car = try c.decode(LenientString.self, forKey: .car)
        _status = try c.decode(LenientString.self, forKey: .status)
        _rating = try c.decode(LenientDouble.self, forKey: .rating)
        _deliveriesHere = try c.decode(LenientInt.self, forKey: .deliveriesHere)
        _balance = try c.decode(LenientDecimal.self, forKey: .balance)
        _courierOwes = try c.decode(LenientDecimal.self, forKey: .courierOwes)
        _shopOwes = try c.decode(LenientDecimal.self, forKey: .shopOwes)
        _since = try c.decode(LenientString.self, forKey: .since)
        _feeMax = try c.decode(LenientDecimal.self, forKey: .feeMax)
        pending = (try? c.decodeIfPresent([PoolLedgerEntry].self, forKey: .pending)) ?? nil
        qrPending = (try? c.decodeIfPresent([PoolQrPending].self, forKey: .qrPending)) ?? nil
    }

    var id: Int { userId ?? 0 }
}

/// Ответ settlements / settlements/{id}/confirm|reject: {entry}.
struct PoolSettleResult: Decodable {
    var entry: PoolLedgerEntry?
}

/// Ответ POST/DELETE /api/v1/seller/pool/qr: {qr_set}.
struct PoolQrAck: Decodable {
    @LenientBool var qrSet: Bool?
    enum CodingKeys: String, CodingKey { case qrSet = "qr_set" }
}

// ── Подписи и форматирование ────────────────────────────────────────────────
enum PoolFmt {
    /// Причины «Проблемы с доставкой» — CourierPool::PROBLEM_REASONS.
    static let problemReasons: [(code: String, label: String)] = [
        ("damaged", "Заказ испорчен"), ("not_delivered", "Не довёз"), ("late", "Сильно опоздал"),
        ("money", "Не сдал деньги"), ("rude", "Грубость"), ("other", "Другое"),
    ]

    static let ledgerStatus: [String: String] = ["pending": "ждёт", "rejected": "отклонено", "void": "снято"]

    /// Статус курьера — CourierPool::STATUS_LABELS.
    static func courierStatus(_ s: String?) -> String {
        let labels = ["pending": "На проверке", "approved": "Одобрен", "rejected": "Отклонён", "blocked": "Заблокирован"]
        return labels[s ?? ""] ?? (s ?? "")
    }

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let timeOut: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let shortOut: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "d MMM, HH:mm"
        return f
    }()

    /// Сервер шлёт date('c') — «2026-10-20T14:05:00+03:00»; на всякий случай
    /// понимаем и прежний формат «Y-m-d H:i:s».
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFull.date(from: s) ?? DateFmt.parse(s)
    }

    /// withDate (А80, межгород заказывают заранее): не сегодня — с датой («21 окт, 17:33»).
    static func time(_ s: String?, withDate: Bool = false) -> String {
        guard let d = date(s) else { return s ?? "" }
        if withDate && !Calendar.current.isDateInToday(d) { return shortOut.string(from: d) }
        return timeOut.string(from: d)
    }

    static func short(_ s: String?) -> String {
        guard let d = date(s) else { return s ?? "" }
        return shortOut.string(from: d)
    }

    // ── А101: вызов «на потом» — ищем курьера до времени забора ─────────────────

    /// Момент → «ЧЧ:ММ» (сегодня в поясе tz) или «ДД.ММ ЧЧ:ММ» (другой день).
    static func untilText(_ d: Date, now: Date = Date(), tz: TimeZone = .autoupdatingCurrent) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = cal.isDate(d, inSameDayAs: now) ? "HH:mm" : "dd.MM HH:mm"
        return f.string(from: d)
    }

    /// Карточка вызова в поиске: до конца поиска (expires_at) больше 60 мин — «Ищем курьера до ЧЧ:ММ»
    /// («до ДД.ММ ЧЧ:ММ», если не сегодня). 60 мин и меньше или время не разобрали — nil: как было.
    static func searchUntil(_ expiresAt: String?, now: Date = Date(), tz: TimeZone = .autoupdatingCurrent) -> String? {
        guard let d = date(expiresAt), d.timeIntervalSince(now) > 3600 else { return nil }
        return "Ищем курьера до " + untilText(d, now: now, tz: tz)
    }

    /// Подсказка под «Когда забрать» (whenHint в seller-pool.js). nil — подсказки нет
    /// (старый сервер без scheduled_search или «Сейчас»). driverChosen — выбран водитель межгорода.
    static func whenHint(sched: PoolSchedSearch?, pickupIn: Int, searchMinutes: Int?, driverChosen: Bool,
                         now: Date = Date(), tz: TimeZone = .autoupdatingCurrent) -> String? {
        guard let sch = sched else { return nil }
        if driverChosen { return "Предложение получит только выбранный водитель — ждём его ответа." }
        let sm = searchMinutes.flatMap { $0 > 0 ? $0 : nil } ?? 5
        if pickupIn <= sch.from { return pickupIn > 0 ? "Ищем курьера \(sm) мин." : nil }
        let lead = sch.lead
        // Иначе — минимум search_minutes, не «за N мин до забора».
        let byPickup = pickupIn - lead > sm
        let until = now.addingTimeInterval(Double(max(pickupIn - lead, sm)) * 60)
        let cap = now.addingTimeInterval(Double(sch.hours) * 3600)
        let u = min(until, cap)
        // Поиск упёрся в потолок max_hours (забор позже) — напоминания сервер не пришлёт: он напоминает,
        // только пока поиск идёт (expires_at > now) и до забора не больше часа (CourierPool::tick).
        let rem = !sch.remindOn || until > cap ? "" : (pickupIn >= 50 ? "курьерам напомним за час и за 30 мин" : "курьерам напомним за 30 мин")
        return "Ищем курьера до " + untilText(u, now: now, tz: tz)
            + (until < cap && byPickup ? " — за \(lead) мин до забора" : "")
            + (rem.isEmpty ? "." : "; " + rem + ".")
    }

    /// Сообщение после «Не пришла» (А87): повтор — already: true, это успех без второго push
    /// курьеру. Оплату уже подтвердили — «Оплата уже подтверждена».
    static func qrNoMessage(_ c: PoolCall) -> String {
        guard c.already == true else { return "Курьер уведомлён" }
        return c.qrConfirmed == true ? "Оплата уже подтверждена" : "Уже отмечено: не пришла"
    }

    /// Сумма без копеек для поля ввода: 150.00 → «150», 150.5 → «150,5».
    static func input(_ v: Decimal?) -> String {
        guard let v, v > 0 else { return "" }
        let n = NSDecimalNumber(decimal: v)
        if v == Decimal(n.intValue) { return String(n.intValue) }
        return "\(v)".replacingOccurrences(of: ".", with: ",")
    }

    /// Деньги из поля ввода для сервера: «1 500,5» → "1500.5"; пусто → nil.
    static func money(_ s: String) -> String? {
        let t = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        return t.isEmpty ? nil : t
    }

    static func km(_ v: Double?) -> String? {
        guard let v, v > 0 else { return nil }
        return String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",") + " км"
    }

    static func rating(_ v: Double?) -> String? {
        guard let v, v > 0 else { return nil }
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
        return "★ " + s
    }

    /// Ссылка tel: только из цифр и «+».
    static func telURL(_ phone: String?) -> URL? {
        guard let p = phone?.filter({ "+0123456789".contains($0) }), !p.isEmpty else { return nil }
        return URL(string: "tel://" + p)
    }
}
