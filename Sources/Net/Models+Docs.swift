import Foundation

// ============================================================================
//  Документы склада, ингредиенты и тех. карты — разделов в приложении не было.
//
//  Пять типов документа, как на сервере:
//    income          — приход от поставщика
//    expense         — списание (нужна причина)
//    move            — перемещение между складами (нужен склад-получатель)
//    inventory       — инвентаризация (план против факта)
//    return_supplier — возврат поставщику
//
//  Документ живёт в двух состояниях: draft (черновик, остатки не двигает)
//  и posted (проведён). Проведение и отмена — отдельные ручки.
// ============================================================================

enum DocType: String, CaseIterable, Identifiable {
    case income, expense, move, inventory, returnSupplier = "return_supplier"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .income:          return "Приход"
        case .expense:         return "Списание"
        case .move:            return "Перемещение"
        case .inventory:       return "Инвентаризация"
        case .returnSupplier:  return "Возврат поставщику"
        }
    }

    var icon: String {
        switch self {
        case .income:         return "tray.and.arrow.down"
        case .expense:        return "trash"
        case .move:           return "arrow.left.arrow.right"
        case .inventory:      return "list.clipboard"
        case .returnSupplier: return "arrow.uturn.left"
        }
    }

    /// У перемещения обязателен склад-получатель, у списания — причина.
    var needsTargetWarehouse: Bool { self == .move }
    var needsReason: Bool { self == .expense }
    /// Инвентаризация сравнивает план с фактом — там две колонки количества.
    var isInventory: Bool { self == .inventory }
}

/// Причины списания — список зеркалит валидацию сервера.
/// Имя с приставкой Doc: WriteoffReason в Models+Phase3 — строка аналитики списаний.
enum DocWriteoffReason: String, CaseIterable, Identifiable {
    case spoilage, breakage, shortage, test, sale, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spoilage: return "Порча"
        case .breakage: return "Бой"
        case .shortage: return "Недостача"
        case .test:     return "Проба"
        case .sale:     return "Продажа"
        case .other:    return "Другое"
        }
    }
}

struct StockDocument: Decodable, Identifiable {
    @LenientInt var id: Int?
    let type: String?
    let number: String?
    let status: String?
    @LenientDecimal var totalAmount: Decimal?
    let comment: String?
    let createdAt: String?
    let postedAt: String?
    let supplier: String?
    // А99: накладная поставщика № и дата. Старый сервер полей не шлёт — nil.
    @LenientString var supplierDocNo: String?
    @LenientString var supplierDocDate: String?
    /// А1328: дата документа ("2026-11-10 14:30:00"); старый сервер не шлёт — nil.
    let docDate: String?

    /// Дата для показа: проведения, иначе документа, иначе создания.
    var shownDate: String? { DocDates.shown(posted: postedAt, doc: docDate, created: createdAt) }
    var docId: Int { id ?? 0 }
    var isPosted: Bool { (status ?? "") == "posted" }
    var docType: DocType { DocType(rawValue: type ?? "") ?? .income }

    enum CodingKeys: String, CodingKey {
        case id, type, number, status, comment, supplier
        case totalAmount = "total_amount"
        case createdAt = "created_at"
        case postedAt = "posted_at"
        case supplierDocNo = "supplier_doc_no"
        case supplierDocDate = "supplier_doc_date"
        case docDate = "doc_date"
    }
}

/// А1328: дата для показа = posted_at ?? doc_date ?? created_at (пустые строки считаем отсутствием).
enum DocDates {
    static func shown(posted: String?, doc: String?, created: String?) -> String? {
        for s in [posted, doc, created] {
            if let s, !s.isEmpty { return s }
        }
        return nil
    }
}

struct StockDocumentItem: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var productId: Int?
    @LenientInt var ingredientId: Int?
    let name: String?
    let unit: String?
    @LenientDecimal var qtyPlan: Decimal?
    @LenientDecimal var qtyFact: Decimal?
    @LenientDecimal var qtyDiff: Decimal?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var amount: Decimal?
    let reason: String?
    /// Розничная цена строки прихода (А99) — сервер хранит только введённую вручную;
    /// nil — розница шла по наценке. Нужна, чтобы правка проведённого прихода (А1328)
    /// не пересчитала розницу товара по наценке категории.
    @LenientDecimal var retailPrice: Decimal?
    /// А1328: repost переписывает строки целиком из тела — артикул, штрихкод и срок годности возвращаем как были.
    let article: String?
    let barcode: String?
    let expiresAt: String?

    var itemId: Int { id ?? 0 }

    enum CodingKeys: String, CodingKey {
        case id, name, unit, price, amount, reason
        case retailPrice = "retail_price"
        case article, barcode
        case expiresAt = "expires_at"
        case productId = "product_id"
        case ingredientId = "ingredient_id"
        case qtyPlan = "qty_plan"
        case qtyFact = "qty_fact"
        case qtyDiff = "qty_diff"
    }
}

struct StockDocumentDetail: Decodable {
    @LenientInt var id: Int?
    let type: String?
    let number: String?
    let status: String?
    @LenientDecimal var totalAmount: Decimal?
    let comment: String?
    let createdAt: String?
    let postedAt: String?
    @LenientInt var warehouseId: Int?
    @LenientInt var warehouseToId: Int?
    @LenientInt var supplierId: Int?
    let items: [StockDocumentItem]?
    // А99: накладная поставщика № и дата (у старого сервера — nil).
    @LenientString var supplierDocNo: String?
    @LenientString var supplierDocDate: String?
    /// А1328: дата документа; старый сервер не шлёт — nil.
    let docDate: String?

    var shownDate: String? { DocDates.shown(posted: postedAt, doc: docDate, created: createdAt) }
    var docType: DocType { DocType(rawValue: type ?? "") ?? .income }
    var isPosted: Bool { (status ?? "") == "posted" }

    enum CodingKeys: String, CodingKey {
        case id, type, number, status, comment, items
        case totalAmount = "total_amount"
        case createdAt = "created_at"
        case postedAt = "posted_at"
        case warehouseId = "warehouse_id"
        case warehouseToId = "warehouse_to_id"
        case supplierId = "supplier_id"
        case supplierDocNo = "supplier_doc_no"
        case supplierDocDate = "supplier_doc_date"
        case docDate = "doc_date"
    }
}

// Результат поиска по складу (товары и ингредиенты одним списком, вид в kind)
// уже описан типом StockSearchItem в Models+Phase3.swift — второй раз тот же
// тип объявлять нельзя, добавляем только то, чего там не было.
extension StockSearchItem {
    /// id повторяется у товара и ингредиента — для строки документа нужен вид.
    var entityId: Int { itemId ?? 0 }
    var isIngredient: Bool { (kind ?? "") == "ingredient" }
}

struct Ingredient: Decodable, Identifiable {
    @LenientInt var id: Int?
    let name: String?
    let unit: String?
    @LenientDecimal var stockQty: Decimal?
    @LenientDecimal var minQty: Decimal?
    @LenientDecimal var pricePerUnit: Decimal?
    let category: String?
    let article: String?
    let barcode: String?

    var ingredientId: Int { id ?? 0 }
    /// Ниже минимума — повод показать предупреждение в списке.
    var isLow: Bool {
        guard let s = stockQty, let m = minQty, m > 0 else { return false }
        return s < m
    }

    enum CodingKeys: String, CodingKey {
        case id, name, unit, category, article, barcode
        case stockQty = "stock_qty"
        case minQty = "min_qty"
        case pricePerUnit = "price_per_unit"
    }
}

// Склад — это WarehouseInfo из Models+Phase3.swift (id, name, is_default,
// address). Своего типа не заводим.

// ── Тех. карты ───────────────────────────────────────────────────────────────
// TechCardResponse, TechCard, TechCardItem и TCModifier объявлены в
// Models+Phase3.swift — раздел тех-карт там уже был описан. Здесь только то,
// чего в них нет.

extension TCModifier {
    /// У модификатора может быть своя карта — тогда tech_card_id не пустой.
    var hasCard: Bool { (techCardId ?? 0) > 0 }
}

struct DocCreateAck: Decodable {
    @LenientInt var id: Int?
    /// А316: строки, которые проведение пропустило (блюдо, набор, услуга). nil — нет.
    let skippedLines: DocSkippedLines?
    enum CodingKeys: String, CodingKey { case id; case skippedLines = "skipped_lines" }
}
struct DocPostAck: Decodable {
    @LenientBool var posted: Bool?
    @LenientBool var cancelled: Bool?
    let skippedLines: DocSkippedLines?
    enum CodingKeys: String, CodingKey { case posted, cancelled; case skippedLines = "skipped_lines" }
}

/// А316: skipped_lines — [{product_id, name, reason: "not_stock_item"}]. Разбор
/// мягкий: что угодно другое не роняет ответ проведения (он уже выполнен).
struct DocSkippedLines: Decodable {
    let names: [String]
    let count: Int

    private struct Row: Decodable {
        let name: String?
        enum CodingKeys: String, CodingKey { case name }
        // Не бросает никогда: иначе элемент массива не пропускался бы.
        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            name = (try? c?.decodeIfPresent(String.self, forKey: .name)) ?? nil
        }
    }

    init(from decoder: Decoder) throws {
        var out: [String] = []
        var n = 0
        if var c = try? decoder.unkeyedContainer() {
            while !c.isAtEnd {
                guard let row = try? c.decode(Row.self) else { break }
                n += 1
                if let nm = row.name?.trimmingCharacters(in: .whitespacesAndNewlines), !nm.isEmpty { out.append(nm) }
            }
        }
        names = out
        count = n
    }

    /// «Пропущены: «Борщ», «Комбо» (не складская позиция)». nil — пропущенных нет.
    var text: String? {
        guard count > 0 else { return nil }
        let what = names.isEmpty ? "\(count) поз." : names.map { "«\($0)»" }.joined(separator: ", ")
        return "Пропущены: \(what) (не складская позиция)"
    }
}

// ── Черновики строк (то, что уходит на сервер) ───────────────────────────────

/// Строка документа перед отправкой. Собираем словарь сами: nil внутри
/// вложенных массивов уронил бы JSONSerialization (makeRequest чистит только
/// верхний уровень), поэтому все значения здесь непустые.
struct DocItemDraft: Identifiable {
    let id = UUID()
    var kind: String            // product | ingredient
    var entityId: Int
    var name: String
    var unit: String
    var qty: Decimal
    /// Инвентаризация: план и факт различаются, для остальных типов равны.
    var qtyPlan: Decimal?
    var price: Decimal
    var reason: String?
    // А99 (приход): розничная цена, введённая в строке; пусто — по наценке категории.
    var retailText: String = ""
    /// Набранная наценка, %. nil — поле показывает расчёт от розницы и закупки.
    var markupText: String? = nil
    /// Закупку уже подставили или поправили руками — данные сервера её больше не трогают.
    var priceTouched: Bool = false
    /// Новая розничная цена для сервера (retail_price) — ставит экран перед отправкой.
    var retailPriceOut: Decimal? = nil
    /// А1328: розница строки проведённого прихода, как была. Не трогали поле — уходит как есть.
    var origRetail: Decimal? = nil
    /// А1328: поля строки проведённого документа, которые repost иначе потерял бы. Обычное создание — nil.
    var article: String? = nil
    var barcode: String? = nil
    var expiresAt: String? = nil

    var amount: Decimal { qty * price }

    var payload: [String: Any] {
        var out: [String: Any] = [
            "kind": kind,
            "id": entityId,
            "name": name,
            "unit": unit,
            "qty": "\(qty)",
            "price": "\(price)",
        ]
        if let p = qtyPlan {
            out["qty_plan"] = "\(p)"
            out["qty_fact"] = "\(qty)"
        }
        if let r = reason, !r.isEmpty { out["reason"] = r }
        if let a = article, !a.isEmpty { out["article"] = a }
        if let b = barcode, !b.isEmpty { out["barcode"] = b }
        if let e = expiresAt, !e.isEmpty { out["expires_at"] = String(e.prefix(10)) }
        if let rp = retailPriceOut, rp > 0 {
            out["retail_price"] = ReceiptMath.moneyInput(rp).replacingOccurrences(of: ",", with: ".")
        }
        return out
    }
}

/// Строка тех. карты перед отправкой.
struct TechCardDraft: Identifiable {
    let id = UUID()
    var ingredientId: Int
    var name: String
    var unit: String
    var qtyGross: Decimal
    var qtyNet: Decimal

    var payload: [String: Any] {
        ["ingredient_id": ingredientId, "qty_gross": "\(qtyGross)", "qty_net": "\(qtyNet)"]
    }
}

// ── А1328: обнуление остатков и правка проведённого документа ───────────────

struct ZeroStockDoc: Decodable {
    @LenientInt var id: Int?
    let number: String?
    @LenientInt var warehouseId: Int?
    let warehouse: String?
    @LenientInt var lines: Int?
    enum CodingKeys: String, CodingKey {
        case id, number, warehouse, lines
        case warehouseId = "warehouse_id"
    }
}

struct ZeroStockItem: Decodable {
    @LenientInt var id: Int?
    let name: String?
    @LenientInt var warehouseId: Int?
    /// Остаток ДО обнуления, строкой ("12.5") — показываем как есть.
    @LenientString var qty: String?
    enum CodingKeys: String, CodingKey {
        case id, name, qty
        case warehouseId = "warehouse_id"
    }
}

struct ZeroStockSkip: Decodable {
    @LenientInt var id: Int?
    let name: String?
    let reason: String?
}

struct ZeroStockResult: Decodable {
    let mode: String?
    @LenientBool var dryRun: Bool?
    @LenientInt var zeroed: Int?
    @LenientInt var unchanged: Int?
    @LenientInt var notFound: Int?
    let documents: [ZeroStockDoc]?
    @LenientInt var batchId: Int?
    let skipped: [ZeroStockSkip]?
    let items: [ZeroStockItem]?
    let message: String?
    enum CodingKeys: String, CodingKey {
        case mode, documents, skipped, items, message, zeroed, unchanged
        case dryRun = "dry_run"
        case notFound = "not_found"
        case batchId = "batch_id"
    }
}

struct RepostResult: Decodable {
    @LenientBool var reposted: Bool?
    let docDate: String?
    let warnings: [String]?
    enum CodingKeys: String, CodingKey {
        case reposted, warnings
        case docDate = "doc_date"
    }
}
