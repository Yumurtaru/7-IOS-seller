import Foundation

// ============================================================================
//  Массовая правка товаров (волна М1 сайта): POST/GET /api/seller/products/bulk-edit,
//  POST /api/seller/products/bulk-edit/{batch_id}/undo.
//
//  Продавец декодирует БЕЗ convertFromSnakeCase: имена полей — явные CodingKeys.
//  Всё необязательное: старый сервер ручки не знает, поле может прийти строкой.
//  old/new — BulkValue: тип зависит от field (деньги — строка "0.00", число, список меток, null).
// ============================================================================

enum BulkValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case list([String])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let b = try? c.decode(Bool.self) {
            self = .number(b ? 1 : 0)
        } else if let a = try? c.decode([String].self) {
            self = .list(a)
        } else {
            self = .null
        }
    }
}

struct BulkEditChange: Decodable, Hashable {
    @LenientString var field: String?
    @LenientString var label: String?
    var old: BulkValue?
    var new: BulkValue?

    enum CodingKeys: String, CodingKey { case field, label, old, new }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _field = try c.decode(LenientString.self, forKey: .field)
        _label = try c.decode(LenientString.self, forKey: .label)
        old = try? c.decodeIfPresent(BulkValue.self, forKey: .old)
        new = try? c.decodeIfPresent(BulkValue.self, forKey: .new)
    }
}

struct BulkEditItem: Decodable, Hashable, Identifiable {
    @LenientInt var id: Int?
    @LenientString var name: String?
    var changes: [BulkEditChange]

    enum CodingKeys: String, CodingKey { case id, name, changes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(LenientInt.self, forKey: .id)
        _name = try c.decode(LenientString.self, forKey: .name)
        changes = (try? c.decodeIfPresent([BulkEditChange].self, forKey: .changes)) ?? []
    }
}

struct BulkEditNote: Decodable, Hashable {
    @LenientInt var id: Int?
    @LenientString var name: String?
    @LenientString var reason: String?
    @LenientString var code: String?
    @LenientString var text: String?

    enum CodingKeys: String, CodingKey { case id, name, reason, code, text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(LenientInt.self, forKey: .id)
        _name = try c.decode(LenientString.self, forKey: .name)
        _reason = try c.decode(LenientString.self, forKey: .reason)
        _code = try c.decode(LenientString.self, forKey: .code)
        _text = try c.decode(LenientString.self, forKey: .text)
    }
}

struct BulkEditResult: Decodable {
    @LenientBool var dryRun: Bool?
    @LenientInt var batchId: Int?
    @LenientInt var requested: Int?
    @LenientInt var matched: Int?
    @LenientInt var changed: Int?
    @LenientInt var unchanged: Int?
    @LenientInt var notFound: Int?
    @LenientInt var itemsTotal: Int?
    var items: [BulkEditItem]
    var skipped: [BulkEditNote]
    var warnings: [BulkEditNote]
    @LenientString var message: String?

    enum CodingKeys: String, CodingKey {
        case requested, matched, changed, unchanged, items, skipped, warnings, message
        case dryRun = "dry_run"
        case batchId = "batch_id"
        case notFound = "not_found"
        case itemsTotal = "items_total"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _dryRun = try c.decode(LenientBool.self, forKey: .dryRun)
        _batchId = try c.decode(LenientInt.self, forKey: .batchId)
        _requested = try c.decode(LenientInt.self, forKey: .requested)
        _matched = try c.decode(LenientInt.self, forKey: .matched)
        _changed = try c.decode(LenientInt.self, forKey: .changed)
        _unchanged = try c.decode(LenientInt.self, forKey: .unchanged)
        _notFound = try c.decode(LenientInt.self, forKey: .notFound)
        _itemsTotal = try c.decode(LenientInt.self, forKey: .itemsTotal)
        items = (try? c.decodeIfPresent([BulkEditItem].self, forKey: .items)) ?? []
        skipped = (try? c.decodeIfPresent([BulkEditNote].self, forKey: .skipped)) ?? []
        warnings = (try? c.decodeIfPresent([BulkEditNote].self, forKey: .warnings)) ?? []
        _message = try c.decode(LenientString.self, forKey: .message)
    }
}

struct BulkEditKept: Decodable, Hashable {
    @LenientInt var id: Int?
    @LenientString var name: String?
    var fields: [String]

    enum CodingKeys: String, CodingKey { case id, name, fields }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(LenientInt.self, forKey: .id)
        _name = try c.decode(LenientString.self, forKey: .name)
        fields = (try? c.decodeIfPresent([String].self, forKey: .fields)) ?? []
    }
}

struct BulkEditUndo: Decodable {
    @LenientBool var undone: Bool?
    @LenientInt var restored: Int?
    var kept: [BulkEditKept]
    @LenientString var message: String?

    enum CodingKeys: String, CodingKey { case undone, restored, kept, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _undone = try c.decode(LenientBool.self, forKey: .undone)
        _restored = try c.decode(LenientInt.self, forKey: .restored)
        kept = (try? c.decodeIfPresent([BulkEditKept].self, forKey: .kept)) ?? []
        _message = try c.decode(LenientString.self, forKey: .message)
    }
}

struct BulkEditBatch: Decodable, Identifiable {
    @LenientInt var batchId: Int?
    @LenientString var summary: String?
    @LenientInt var itemsCount: Int?
    @LenientString var createdAt: String?
    @LenientString var userName: String?
    @LenientString var undoneAt: String?
    @LenientBool var canUndo: Bool?

    var id: Int { batchId ?? 0 }

    enum CodingKeys: String, CodingKey {
        case summary
        case batchId = "id"
        case itemsCount = "items_count"
        case createdAt = "created_at"
        case userName = "user_name"
        case undoneAt = "undone_at"
        case canUndo = "can_undo"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _batchId = try c.decode(LenientInt.self, forKey: .batchId)
        _summary = try c.decode(LenientString.self, forKey: .summary)
        _itemsCount = try c.decode(LenientInt.self, forKey: .itemsCount)
        _createdAt = try c.decode(LenientString.self, forKey: .createdAt)
        _userName = try c.decode(LenientString.self, forKey: .userName)
        _undoneAt = try c.decode(LenientString.self, forKey: .undoneAt)
        _canUndo = try c.decode(LenientBool.self, forKey: .canUndo)
    }
}

struct BulkEditHistory: Decodable {
    var items: [BulkEditBatch]

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([BulkEditBatch].self, forKey: .items)) ?? []
    }
}

// ── Форма «Изменить…» и разбор её в changes запроса ─────────────────────────

/// Пустая строка = «не менять» (ключ в changes не попадёт).
struct BulkForm: Equatable {
    var priceMode = ""            // "" | percent | delta | set
    var priceValue = ""
    var rounding = "none"         // none | integer | 0.10 | 0.50 | end9
    var oldMode = ""              // "" | clear | from_price | set
    var oldValue = ""
    var retail = ""               // "" | 1 | 0
    var categoryTouched = false
    var categoryId = 0            // 0 = без категории
    var unit = ""
    var unitClear = false
    var fractional = ""           // "" | 1 | 0 | cat (как в категории)
    var step = ""
    var stepCat = false
    var stockMin = ""
    var stockMode = ""            // "" | set | delta
    var stockValue = ""
    var tagsAdd = ""
    var tagsRemove = ""
    var status = ""               // "" | active | hidden
    var avail = ""                // "" | 1 | 0
}

enum BulkBuild {
    case ok([String: Any])
    case bad(String)
}

enum BulkEditLogic {
    static let roundings: [(String, String)] = [
        ("none", "Не округлять"), ("integer", "До целого"), ("0.10", "До 0,10"),
        ("0.50", "До 0,50"), ("end9", "На 9")
    ]

    /// Число из поля ввода (запятая допустима), со знаком, если allowNegative.
    static func parse(_ raw: String, fraction: Int, allowNegative: Bool) -> Decimal? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2212}", with: "-")
        var negative = false
        if t.hasPrefix("-") {
            guard allowNegative else { return nil }
            negative = true
            t.removeFirst()
        }
        guard let v = Money.strict(t, maxFraction: fraction) else { return nil }
        return negative ? -v : v
    }

    /// Число — строкой "12.5": сервер принимает строки, а Decimal не теряет точность.
    static func str(_ v: Decimal) -> String { "\(v)" }

    /// Форма -> changes. Ключ — только для заданных полей. Явный null (как в категории) — NSNull().
    /// canPrice / canStock — права products.price / products.create: закрытые поля игнорируются.
    static func build(_ f: BulkForm, canPrice: Bool, canStock: Bool) -> BulkBuild {
        var c: [String: Any] = [:]
        if canPrice && !f.priceMode.isEmpty {
            guard let v = parse(f.priceValue, fraction: 2, allowNegative: f.priceMode != "set") else {
                return .bad("Цена: введите число, например 10 или 12,5")
            }
            c["price"] = ["mode": f.priceMode, "value": str(v), "rounding": f.rounding.isEmpty ? "none" : f.rounding] as [String: Any]
        }
        if canPrice && !f.oldMode.isEmpty {
            var o: [String: Any] = ["mode": f.oldMode]
            if f.oldMode == "set" {
                guard let v = parse(f.oldValue, fraction: 2, allowNegative: false) else {
                    return .bad("Старая цена: введите число, например 120")
                }
                o["value"] = str(v)
            }
            if f.oldMode == "from_price" && f.priceMode.isEmpty {
                return .bad("«Из прежней цены» работает только вместе с изменением цены")
            }
            c["price_old"] = o
        }
        if canPrice && !f.retail.isEmpty { c["retail_price_manual"] = Int(f.retail) ?? 0 }
        if f.categoryTouched { c["category_id"] = f.categoryId }
        if f.unitClear {
            c["unit"] = ""
        } else if !f.unit.trimmingCharacters(in: .whitespaces).isEmpty {
            c["unit"] = f.unit.trimmingCharacters(in: .whitespaces)
        }
        if f.fractional == "1" || f.fractional == "0" {
            c["qty_fractional"] = Int(f.fractional) ?? 0
        } else if f.fractional == "cat" {
            c["qty_fractional"] = NSNull()
        }
        if f.stepCat {
            c["qty_step"] = NSNull()
        } else if !f.step.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let v = parse(f.step, fraction: 3, allowNegative: false), v > 0 else {
                return .bad("Шаг: положительное число, например 0,1")
            }
            c["qty_step"] = str(v)
        }
        if !f.stockMin.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let v = parse(f.stockMin, fraction: 3, allowNegative: false) else {
                return .bad("Мин. остаток: введите число")
            }
            c["stock_min"] = str(v)
        }
        if canStock && !f.stockMode.isEmpty {
            guard let v = parse(f.stockValue, fraction: 3, allowNegative: f.stockMode == "delta") else {
                return .bad("Остаток: введите число, например 12,5")
            }
            c["stock"] = ["mode": f.stockMode, "value": str(v)] as [String: Any]
        }
        let add = f.tagsAdd.trimmingCharacters(in: .whitespaces)
        if !add.isEmpty { c["tags_add"] = add }
        let rem = f.tagsRemove.trimmingCharacters(in: .whitespaces)
        if !rem.isEmpty { c["tags_remove"] = rem }
        if !f.status.isEmpty { c["status"] = f.status }
        if !f.avail.isEmpty { c["is_available"] = Int(f.avail) ?? 0 }
        if c.isEmpty { return .bad("Выберите, что изменить") }
        return .ok(c)
    }

    /// Отпечаток запроса: тот же набор полей и товаров -> тот же ключ повтора.
    static func fingerprint(ids: [Int], changes: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["ids": ids, "changes": changes] as [String: Any],
                                               options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    private static func plain(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) }
        return String(d).replacingOccurrences(of: ".", with: ",")
    }

    /// old/new для показа: деньги из "0.00", числа, списки меток, null — «—».
    static func show(field: String?, value: BulkValue?, categoryName: (Int) -> String? = { _ in nil }) -> String {
        guard let value = value else { return "—" }
        switch value {
        case .null:
            return "—"
        case .list(let a):
            return a.isEmpty ? "—" : a.joined(separator: ", ")
        case .string(let s):
            if field == "price" || field == "price_old" {
                if let d = Decimal(string: s) { return Money.rub(d) }
                return s
            }
            if let d = Double(s), field != "unit", field != "status" { return showNumber(field: field, d: d, categoryName: categoryName) }
            if field == "status" { return s == "active" ? "показан" : (s == "hidden" ? "скрыт" : s) }
            return s.isEmpty ? "—" : s
        case .number(let d):
            if field == "price" || field == "price_old" { return Money.rub(Decimal(string: String(d)) ?? 0) }
            return showNumber(field: field, d: d, categoryName: categoryName)
        }
    }

    private static func showNumber(field: String?, d: Double, categoryName: (Int) -> String?) -> String {
        switch field {
        case "is_available": return d != 0 ? "в наличии" : "нет в наличии"
        case "retail_price_manual": return d != 0 ? "вручную" : "авто"
        case "qty_fractional": return d != 0 ? "дробное" : "целое"
        case "category_id":
            let id = Int(d)
            return categoryName(id) ?? "№\(id)"
        default: return plain(d)
        }
    }

    /// «Цена 45,00 ₽ → 50,00 ₽»
    static func line(_ c: BulkEditChange, categoryName: (Int) -> String? = { _ in nil }) -> String {
        let label = c.label ?? c.field ?? ""
        let a = show(field: c.field, value: c.old, categoryName: categoryName)
        let b = show(field: c.field, value: c.new, categoryName: categoryName)
        return "\(label) \(a) → \(b)"
    }
}
