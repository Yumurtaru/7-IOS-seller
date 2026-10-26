import Foundation

// ============================================================================
//  Импорт товаров и ингредиентов из файла — routes/seller_import.php.
//
//  Три шага, как в веб-кабинете:
//    1. POST /api/seller/import/upload?target=  (multipart, поле file)
//       -> file_id, заголовки, первые строки, поля и предложенный маппинг;
//    2. POST /api/seller/import/preview — считает, что произойдёт, ничего не меняя;
//    3. POST /api/seller/import/run — применяет.
//
//  Право — «Товары» (products), так размечено на сервере.
// ============================================================================

/// Поле, в которое можно замапить колонку файла.
struct ImportField: Decodable {
    let label: String?
    @LenientBool var required: Bool?
}

/// Ответ первого шага. sample — первые пять строк файла как есть.
struct ImportUpload: Decodable {
    let fileId: String?
    let target: String?
    let headers: [String]?
    let sample: [[String]]?
    @LenientInt var total: Int?
    let fields: [String: ImportField]?
    /// Автоподбор сервера: поле -> номер колонки.
    let suggested: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case target, headers, sample, total, fields, suggested
        case fileId = "file_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileId = try? c.decodeIfPresent(String.self, forKey: .fileId)
        target = try? c.decodeIfPresent(String.self, forKey: .target)
        headers = (try? c.decodeIfPresent([String].self, forKey: .headers)) ?? []
        // Ячейки приходят строками, но пустые колонки бывают null — не роняем разбор.
        sample = (try? c.decodeIfPresent([[String]].self, forKey: .sample)) ?? []
        _total = try c.decode(LenientInt.self, forKey: .total)
        fields = (try? c.decodeIfPresent([String: ImportField].self, forKey: .fields)) ?? [:]
        suggested = (try? c.decodeIfPresent([String: Int].self, forKey: .suggested)) ?? [:]
    }

    /// Порядок полей повторяет importFieldsFor() на сервере: JSON-объект в Swift
    /// раскладывается в неупорядоченный словарь, а владельцу нужен тот же
    /// порядок, что и в кабинете. Неизвестные ключи добавляем в конец, чтобы
    /// новое поле сервера не потерялось.
    var orderedFieldKeys: [String] {
        let productOrder = ["name", "article", "barcode", "category", "price", "price_old",
                            "description", "unit", "weight", "stock", "stock_min", "status",
                            "tags", "allergens", "calories", "proteins", "fats", "carbs",
                            "image", "modifiers"]
        let ingredientOrder = ["name", "article", "barcode", "category", "unit",
                               "stock", "stock_min", "price"]
        let known = target == "ingredients" ? ingredientOrder : productOrder
        let have = fields ?? [:]
        var out = known.filter { have[$0] != nil }
        out.append(contentsOf: have.keys.filter { !known.contains($0) }.sorted())
        return out
    }
}

/// Счётчики предпросмотра и запуска.
struct ImportCounters: Decodable {
    @LenientInt var add: Int?
    @LenientInt var update: Int?
    @LenientInt var skip: Int?
    @LenientInt var error: Int?
}

struct ImportRowError: Decodable, Identifiable {
    @LenientInt var line: Int?
    let error: String?
    let name: String?
    var id: Int { line ?? 0 }
}

struct ImportPreviewRow: Decodable, Identifiable {
    @LenientInt var line: Int?
    let action: String?          // add | update | skip | error
    let name: String?
    @LenientString var price: String?
    let error: String?
    var id: Int { line ?? 0 }
}

struct ImportResult: Decodable {
    let report: ImportCounters?
    let errors: [ImportRowError]?
    let preview: [ImportPreviewRow]?
    /// А60/П-23.6: импорт остановился на этой строке — можно продолжить с неё
    /// (start_row). replayed — повтор того же запроса: сервер отдал сохранённый
    /// отчёт, импорт заново не шёл. Старый сервер полей не шлёт → nil.
    @LenientInt var stoppedAt: Int?
    @LenientBool var replayed: Bool?

    enum CodingKeys: String, CodingKey {
        case report, errors, preview, replayed
        case stoppedAt = "stopped_at"
    }
}

extension ImportResult {
    /// Пустой отчёт: статус «done» пришёл без result.
    init() {
        report = nil
        errors = nil
        preview = nil
        _stoppedAt = LenientInt(wrappedValue: nil)
        _replayed = LenientBool(wrappedValue: nil)
    }
}

/// А60/П-23.6: GET /api/seller/import/status?file_id= — последний запуск импорта:
/// {state: running|done|stopped|failed|interrupted|unknown, busy, file_id,
///  start_row, result, started_at, finished_at, file_exists, http_code?}.
struct ImportStatus: Decodable {
    var state: String?
    @LenientBool var busy: Bool?
    @LenientString var fileId: String?
    @LenientInt var startRow: Int?
    var result: ImportResult?
    @LenientBool var fileExists: Bool?

    enum CodingKeys: String, CodingKey {
        case state, busy, result
        case fileId = "file_id"
        case startRow = "start_row"
        case fileExists = "file_exists"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        _busy = try c.decode(LenientBool.self, forKey: .busy)
        _fileId = try c.decode(LenientString.self, forKey: .fileId)
        _startRow = try c.decode(LenientInt.self, forKey: .startRow)
        // Отчёт бывает пустым массивом PHP — не роняем весь статус.
        result = (try? c.decodeIfPresent(ImportResult.self, forKey: .result)) ?? nil
        _fileExists = try c.decode(LenientBool.self, forKey: .fileExists)
    }
}
