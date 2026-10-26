import Foundation

// ============================================================================
//  Столы и станции — управление, а не только просмотр.
//
//  Столы: routes/tables.php, обычный путь /api/seller/tables.
//  Станции: routes/stations.php, путь версии 1 — /api/v1/seller/stations.
//  Разные префиксы не опечатка: станции живут в v1-ветке с самого начала,
//  и переименовывать их нельзя — по этим адресам ходит касса.
//
//  Право на оба раздела — «Настройки» (settings), как размечено на сервере.
// ============================================================================

/// Каталог прав станции — точная копия stationAllPerms()/stationPermLabels()
/// из routes/stations.php. Сервер всё равно отфильтрует лишнее (intersect),
/// но показывать надо ровно то, что он примет для этого типа станции.
enum StationPerms {
    // Сверено с stationAllPerms()/stationDefaultPerms() в routes/stations.php:
    // у «Помощника повара» (chef) права есть, у киоска и сборщика есть
    // edit_order, а writeoff_alcohol сервер убрал. Раньше приложение при любом
    // сохранении присылало только свой старый список — и станция chef теряла
    // «Отметку готовности», а edit_order снимался.
    static let byType: [String: [String]] = [
        "kiosk": ["sell", "pay_cash", "pay_card", "reprint", "refund", "cancel_order",
                  "discount", "open_drawer", "x_report", "z_report", "price_override", "cook_unpaid",
                  "edit_order"],
        "kitchen": ["view_orders", "mark_ready", "stop_list"],
        "bar": ["view_orders", "mark_ready", "stop_list"],
        "picker": ["view_orders", "mark_collected", "report_shortage", "edit_order"],
        "queue": [],
        "chef": ["view_orders", "mark_ready"],
    ]

    static let labels: [String: String] = [
        "sell": "Продажа", "pay_cash": "Оплата наличными", "pay_card": "Оплата картой",
        "reprint": "Повтор чека", "refund": "Возврат", "cancel_order": "Отмена заказа",
        "discount": "Скидки", "open_drawer": "Открыть денежный ящик", "x_report": "X-отчёт",
        "z_report": "Z-отчёт (закрытие смены)", "price_override": "Изменение цены",
        "cook_unpaid": "Готовить без оплаты", "view_orders": "Просмотр заказов",
        "mark_ready": "Отметка готовности", "stop_list": "Стоп-лист",
        "mark_collected": "Отметка сборки",
        "report_shortage": "Сообщить о недостаче",
        "edit_order": "Правка состава заказа",
    ]

    /// Безопасный минимум — тот же, что ставит сервер, если прав не прислали
    /// (stationDefaultPerms: у киоска ещё edit_order и cook_unpaid).
    static let defaults: [String: [String]] = [
        "kiosk": ["sell", "pay_cash", "pay_card", "reprint", "edit_order", "cook_unpaid"],
        "kitchen": ["view_orders", "mark_ready"],
        "bar": ["view_orders", "mark_ready"],
        "picker": ["view_orders", "mark_collected", "edit_order"],
        "queue": [],
        "chef": ["view_orders", "mark_ready"],
    ]

    static let types = ["kiosk", "kitchen", "bar", "picker", "queue", "chef"]

    static func label(_ code: String) -> String { labels[code] ?? code }
}

/// POST станции → {id, login, url}: url — адрес экрана станции на сайте.
struct StationCreateAck: Decodable {
    @LenientInt var id: Int?
    let login: String?
    let url: String?
}

struct StationBlockAck: Decodable {
    @LenientBool var isActive: Bool?
    enum CodingKeys: String, CodingKey { case isActive = "is_active" }
}

extension API {

    // ── Столы ────────────────────────────────────────────────────────────
    func createTable(number: String, seats: Int, zone: String?) async throws -> Int {
        let ack = try await post("api/seller/tables",
                                 body: ["number": number, "seats": seats,
                                        "zone": (zone?.isEmpty ?? true) ? nil : zone],
                                 as: IdAck.self)
        return ack.id ?? 0
    }

    /// Сервер меняет только присланные поля (isset), поэтому шлём всё сразу —
    /// иначе «сохранить» молча теряло бы то, чего в теле не было.
    func updateTable(id: Int, number: String, seats: Int, zone: String?, isActive: Bool) async throws {
        _ = try await put("api/seller/tables/\(id)",
                          body: ["number": number, "seats": seats,
                                 "zone": zone ?? "", "is_active": isActive ? 1 : 0],
                          as: Phase2BoolAck.self)
    }

    func deleteTable(id: Int) async throws {
        _ = try await delete("api/seller/tables/\(id)", as: Phase2BoolAck.self)
    }

    // ── Станции ──────────────────────────────────────────────────────────
    func createStation(type: String, login: String, password: String, displayName: String?,
                       stationNumber: String?, permissions: [String], pin: String?) async throws -> StationCreateAck {
        try await post("api/v1/seller/stations", body: [
            "type": type,
            "login": login,
            "password": password,
            "display_name": (displayName?.isEmpty ?? true) ? nil : displayName,
            "station_number": (stationNumber?.isEmpty ?? true) ? nil : stationNumber,
            "permissions": permissions,
            "pin_code": pin ?? "",
        ], as: StationCreateAck.self)
    }

    /// Тип и логин менять нельзя — сервер их не принимает: по логину станция
    /// входит, а тип определяет набор прав. Пустой пароль означает «не менять».
    /// ПИН: nil — ключ не уходит, сервер ПИН не трогает (раньше уходила пустая
    /// строка при любой правке, и переименование киоска снимало с него ПИН);
    /// clearPin — явное «Убрать ПИН».
    func updateStation(id: Int, displayName: String?, password: String?,
                       permissions: [String], pin: String?, clearPin: Bool = false) async throws {
        var body: [String: Any?] = [
            "display_name": displayName ?? "",
            "permissions": permissions,
        ]
        if clearPin {
            body["pin_code"] = ""
            body["pin_clear"] = 1
        } else if let pin {
            body["pin_code"] = pin
        }
        if let password, !password.isEmpty { body["password"] = password }
        _ = try await put("api/v1/seller/stations/\(id)", body: body, as: Phase2BoolAck.self)
    }

    /// Блокировка гасит активные сессии станции — она выйдет из системы.
    func setStationBlocked(id: Int, unblock: Bool) async throws -> Bool {
        let ack = try await post("api/v1/seller/stations/\(id)/block",
                                 body: ["unblock": unblock ? 1 : 0], as: StationBlockAck.self)
        return ack.isActive ?? unblock
    }

    func resetStationSessions(id: Int) async throws {
        _ = try await delete("api/v1/seller/stations/\(id)/sessions", as: Phase2BoolAck.self)
    }

    /// Сервер разрешает удалять только заблокированный или ни разу не входивший
    /// аккаунт — иначе 422 с понятным текстом, показываем его как есть.
    func deleteStation(id: Int) async throws {
        _ = try await delete("api/v1/seller/stations/\(id)", as: Phase2BoolAck.self)
    }

}
