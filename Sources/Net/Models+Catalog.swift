import Foundation

// ============================================================================
//  Каталог: категории, наборы, модификаторы, артикулы и штрихкоды.
//  Разделов не было в приложении — товар можно было завести, но не разложить
//  по категориям, не собрать набор и не проставить штрихкод.
//
//  Все поля nullable: часть колонок появляется только после миграций
//  (station_route, qty_*, markup_*), и сервер честно отдаёт по ним NULL.
// ============================================================================

struct ProductCategory: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var parentId: Int?
    let name: String?
    let slug: String?
    let image: String?
    @LenientBool var isActive: Bool?
    @LenientInt var sortOrder: Int?
    /// Маршрут на станцию кухни/бара — только у ресторана и только после миграции.
    let stationRoute: String?
    @LenientBool var qtyFractional: Bool?
    @LenientDecimal var qtyStep: Decimal?
    let qtyPresets: String?
    @LenientDecimal var markupPercent: Decimal?
    let roundingMode: String?

    var categoryId: Int { id ?? 0 }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, image
        case parentId = "parent_id"
        case isActive = "is_active"
        case sortOrder = "sort_order"
        case stationRoute = "station_route"
        case qtyFractional = "qty_fractional"
        case qtyStep = "qty_step"
        case qtyPresets = "qty_presets"
        case markupPercent = "markup_percent"
        case roundingMode = "rounding_mode"
    }
}

// ── Наборы ───────────────────────────────────────────────────────────────────

/// Набор — это обычный товар, у которого есть строки в combo_items.
/// Отдельной сущности «набор» на сервере нет, поэтому и здесь id — id товара.
struct ComboSummary: Decodable, Identifiable {
    @LenientInt var id: Int?
    let name: String?
    @LenientDecimal var price: Decimal?
    @LenientInt var itemsCount: Int?

    var comboId: Int { id ?? 0 }

    enum CodingKeys: String, CodingKey {
        case id, name, price
        case itemsCount = "items_count"
    }
}

struct ComboItem: Decodable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var productId: Int?
    @LenientInt var qty: Int?
    let name: String?
    @LenientDecimal var price: Decimal?

    var itemId: Int { id ?? 0 }

    enum CodingKeys: String, CodingKey {
        case id, qty, name, price
        case productId = "product_id"
    }
}

/// Товар для выбора в набор (GET /api/seller/combos/products).
struct ComboPickProduct: Decodable, Identifiable {
    @LenientInt var id: Int?
    let name: String?
    @LenientDecimal var price: Decimal?
    var pickId: Int { id ?? 0 }
}

// ── Модификаторы ─────────────────────────────────────────────────────────────
// ModifierGroup и ModifierOption объявлены в Models.swift — там же, где их
// читает карточка товара. Здесь только то, чего в них не было.

extension ModifierGroup {
    /// В базе колонка — enum('single','multi'), и киоск со станциями
    /// сравнивают именно с 'multi'. В API-запросах при этом принято
    /// 'multiple'. Понимаем оба, чтобы не зависеть от того, кто создал группу.
    var isMultiple: Bool {
        let t = (type ?? "").lowercased()
        return t == "multi" || t == "multiple"
    }
}

// ── Артикулы и штрихкоды ─────────────────────────────────────────────────────

struct ArticleRow: Decodable, Identifiable {
    @LenientInt var id: Int?
    let name: String?
    let article: String?
    let barcode: String?

    var rowId: Int { id ?? 0 }
}

/// Ответ POST /api/seller/articles/bulk: сколько строк сохранено и что не прошло.
struct ArticlesBulkAck: Decodable {
    @LenientInt var saved: Int?
    let errors: [String]?
}

struct BarcodeAck: Decodable { let barcode: String? }

/// Строка для пакетного сохранения артикулов. Пустая строка = очистить поле:
/// сервер приводит её к NULL, и отдельного «удалить» не нужно.
struct ArticleEdit {
    let id: Int
    let article: String
    let barcode: String
}
