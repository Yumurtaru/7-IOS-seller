import Foundation

// ============================================================================
//  Приход по фото накладной — routes/seller_invoice_ocr.php (волна В3 сайта).
//
//  Продавец декодирует БЕЗ convertFromSnakeCase: имена полей — явные CodingKeys.
//  Деньги ("1220.00"), количества ("10.000") и коэффициент ("1.0000") приходят
//  строками — @LenientDecimal. Все поля необязательные: старый сервер или
//  кривое поле не должны ронять экран. Отдельные списки и вложенные объекты
//  разбираем терпимо (tol / tolList): одно сломанное поле не губит весь ответ.
// ============================================================================

extension KeyedDecodingContainer {
    /// Поле, которое при любом несовпадении типа становится nil, а не ошибкой.
    func tol<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        do { return try decodeIfPresent(type, forKey: key) } catch { return nil }
    }
    /// Список: нет поля или неверный тип — пустой список.
    func tolList<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        do { return try decodeIfPresent([T].self, forKey: key) ?? [] } catch { return [] }
    }
}

/// GET /state — включено ли распознавание, лимиты.
struct OcrState: Decodable {
    @LenientBool var enabled: Bool?
    @LenientBool var configured: Bool?
    @LenientInt var dailyLimit: Int?
    @LenientInt var usedToday: Int?
    @LenientInt var maxRetries: Int?
    @LenientInt var maxFiles: Int?
    @LenientInt var maxPages: Int?
    @LenientInt var maxBytes: Int?
    @LenientInt var keepDays: Int?
    @LenientBool var canPost: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled, configured
        case dailyLimit = "daily_limit"
        case usedToday = "used_today"
        case maxRetries = "max_retries"
        case maxFiles = "max_files"
        case maxPages = "max_pages"
        case maxBytes = "max_bytes"
        case keepDays = "keep_days"
        case canPost = "can_post"
    }
}

struct OcrProgress: Decodable {
    @LenientInt var elapsedSec: Int?
    @LenientString var hint: String?
    enum CodingKeys: String, CodingKey {
        case hint
        case elapsedSec = "elapsed_sec"
    }
}

struct OcrFile: Decodable {
    @LenientInt var n: Int?
    @LenientString var name: String?
    @LenientString var mime: String?
    @LenientBool var pdf: Bool?
}

struct OcrMatch: Decodable {
    @LenientInt var matchId: Int?
    @LenientString var name: String?
    enum CodingKeys: String, CodingKey {
        case name
        case matchId = "id"
    }
}

struct OcrSupplier: Decodable {
    @LenientString var name: String?
    @LenientString var inn: String?
    @LenientString var kpp: String?
    @LenientBool var innOk: Bool?
    var match: OcrMatch?
    @LenientBool var willCreate: Bool?

    enum CodingKeys: String, CodingKey {
        case name, inn, kpp, match
        case innOk = "inn_ok"
        case willCreate = "will_create"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _name = try c.decode(LenientString.self, forKey: .name)
        _inn = try c.decode(LenientString.self, forKey: .inn)
        _kpp = try c.decode(LenientString.self, forKey: .kpp)
        _innOk = try c.decode(LenientBool.self, forKey: .innOk)
        match = c.tol(OcrMatch.self, .match)
        _willCreate = try c.decode(LenientBool.self, forKey: .willCreate)
    }
}

struct OcrTotals: Decodable {
    @LenientDecimal var net: Decimal?
    @LenientDecimal var vat: Decimal?
    @LenientDecimal var gross: Decimal?
}

struct OcrReconcile: Decodable {
    @LenientDecimal var linesGross: Decimal?
    @LenientDecimal var docGross: Decimal?
    @LenientDecimal var diffGross: Decimal?
    @LenientBool var ok: Bool?
    @LenientBool var checked: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, checked
        case linesGross = "lines_gross"
        case docGross = "doc_gross"
        case diffGross = "diff_gross"
    }
}

struct OcrCheck: Decodable {
    @LenientString var code: String?
    @LenientString var level: String?
    @LenientString var text: String?
}

struct OcrFlag: Decodable {
    @LenientString var code: String?
    @LenientString var text: String?
}

struct OcrReceiptRef: Decodable {
    @LenientInt var receiptId: Int?
    @LenientString var number: String?
    @LenientString var status: String?
    enum CodingKeys: String, CodingKey {
        case number, status
        case receiptId = "id"
    }
}

/// Сопоставление строки накладной с товаром или ингредиентом склада.
struct OcrMap: Decodable {
    @LenientString var kind: String?
    @LenientInt var itemId: Int?
    /// Количество на складе = qty × factor. Строка "1.0000".
    @LenientDecimal var factor: Decimal?
    @LenientString var by: String?
    /// true — «проверьте единицу»: приход не оформится, пока не подтвердят.
    @LenientBool var check: Bool?
    @LenientString var name: String?
    @LenientString var unit: String?
    /// true — товар удалён.
    @LenientBool var missing: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, factor, by, check, name, unit, missing
        case itemId = "id"
    }
}

struct OcrLine: Decodable, Identifiable {
    @LenientInt var lineId: Int?
    @LenientInt var lineNo: Int?
    @LenientString var name: String?
    @LenientString var article: String?
    @LenientString var barcode: String?
    @LenientString var unit: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var amountNet: Decimal?
    @LenientString var vatRate: String?
    @LenientDecimal var amountGross: Decimal?
    @LenientBool var skipped: Bool?
    var map: OcrMap?
    var flags: [OcrFlag] = []

    enum CodingKeys: String, CodingKey {
        case name, article, barcode, unit, qty, price, skipped, map, flags
        case lineId = "id"
        case lineNo = "line_no"
        case amountNet = "amount_net"
        case vatRate = "vat_rate"
        case amountGross = "amount_gross"
    }

    var id: Int { lineId ?? 0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _lineId = try c.decode(LenientInt.self, forKey: .lineId)
        _lineNo = try c.decode(LenientInt.self, forKey: .lineNo)
        _name = try c.decode(LenientString.self, forKey: .name)
        _article = try c.decode(LenientString.self, forKey: .article)
        _barcode = try c.decode(LenientString.self, forKey: .barcode)
        _unit = try c.decode(LenientString.self, forKey: .unit)
        _qty = try c.decode(LenientDecimal.self, forKey: .qty)
        _price = try c.decode(LenientDecimal.self, forKey: .price)
        _amountNet = try c.decode(LenientDecimal.self, forKey: .amountNet)
        _vatRate = try c.decode(LenientString.self, forKey: .vatRate)
        _amountGross = try c.decode(LenientDecimal.self, forKey: .amountGross)
        _skipped = try c.decode(LenientBool.self, forKey: .skipped)
        map = c.tol(OcrMap.self, .map)
        flags = c.tolList(OcrFlag.self, .flags)
    }
}

/// Распознанный документ (job.document), заполнен при status = done.
struct OcrDocument: Decodable {
    @LenientInt var docId: Int?
    @LenientString var docType: String?
    @LenientString var docTypeLabel: String?
    @LenientString var docNo: String?
    @LenientString var docDate: String?
    @LenientString var currency: String?
    var supplier: OcrSupplier?
    var totals: OcrTotals?
    var lines: [OcrLine] = []
    @LenientInt var linesCount: Int?
    var reconcile: OcrReconcile?
    var checks: [OcrCheck] = []
    @LenientInt var unmapped: Int?
    @LenientInt var toCheck: Int?
    var negativeLines: [Int] = []
    var receipt: OcrReceiptRef?
    @LenientBool var canReceipt: Bool?

    enum CodingKeys: String, CodingKey {
        case currency, supplier, totals, lines, reconcile, checks, unmapped, receipt
        case docId = "id"
        case docType = "doc_type"
        case docTypeLabel = "doc_type_label"
        case docNo = "doc_no"
        case docDate = "doc_date"
        case linesCount = "lines_count"
        case toCheck = "to_check"
        case negativeLines = "negative_lines"
        case canReceipt = "can_receipt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _docId = try c.decode(LenientInt.self, forKey: .docId)
        _docType = try c.decode(LenientString.self, forKey: .docType)
        _docTypeLabel = try c.decode(LenientString.self, forKey: .docTypeLabel)
        _docNo = try c.decode(LenientString.self, forKey: .docNo)
        _docDate = try c.decode(LenientString.self, forKey: .docDate)
        _currency = try c.decode(LenientString.self, forKey: .currency)
        supplier = c.tol(OcrSupplier.self, .supplier)
        totals = c.tol(OcrTotals.self, .totals)
        lines = c.tolList(OcrLine.self, .lines)
        _linesCount = try c.decode(LenientInt.self, forKey: .linesCount)
        reconcile = c.tol(OcrReconcile.self, .reconcile)
        checks = c.tolList(OcrCheck.self, .checks)
        _unmapped = try c.decode(LenientInt.self, forKey: .unmapped)
        _toCheck = try c.decode(LenientInt.self, forKey: .toCheck)
        negativeLines = c.tolList(Int.self, .negativeLines)
        receipt = c.tol(OcrReceiptRef.self, .receipt)
        _canReceipt = try c.decode(LenientBool.self, forKey: .canReceipt)
    }
}

/// Задание распознавания: publicJob + (для GET /{id}) document + (для истории) краткие поля шапки.
struct OcrJob: Decodable, Identifiable {
    @LenientInt var jobId: Int?
    @LenientString var status: String?
    @LenientString var statusLabel: String?
    @LenientInt var pages: Int?
    @LenientString var error: String?
    @LenientString var errorCode: String?
    @LenientInt var retries: Int?
    @LenientInt var retriesLeft: Int?
    @LenientString var retryAt: String?
    var progress: OcrProgress?
    @LenientInt var docId: Int?
    @LenientInt var receiptId: Int?
    @LenientString var createdAt: String?
    @LenientString var finishedAt: String?
    var files: [OcrFile] = []
    @LenientString var notes: String?
    var document: OcrDocument?
    // Только в истории.
    @LenientString var docNo: String?
    @LenientString var docDate: String?
    @LenientString var supplierName: String?
    @LenientDecimal var totalGross: Decimal?
    @LenientInt var linesCount: Int?

    enum CodingKeys: String, CodingKey {
        case status, pages, error, retries, progress, files, notes, document
        case jobId = "id"
        case statusLabel = "status_label"
        case errorCode = "error_code"
        case retriesLeft = "retries_left"
        case retryAt = "retry_at"
        case docId = "doc_id"
        case receiptId = "receipt_id"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case docNo = "doc_no"
        case docDate = "doc_date"
        case supplierName = "supplier_name"
        case totalGross = "total_gross"
        case linesCount = "lines_count"
    }

    var id: Int { jobId ?? 0 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _jobId = try c.decode(LenientInt.self, forKey: .jobId)
        _status = try c.decode(LenientString.self, forKey: .status)
        _statusLabel = try c.decode(LenientString.self, forKey: .statusLabel)
        _pages = try c.decode(LenientInt.self, forKey: .pages)
        _error = try c.decode(LenientString.self, forKey: .error)
        _errorCode = try c.decode(LenientString.self, forKey: .errorCode)
        _retries = try c.decode(LenientInt.self, forKey: .retries)
        _retriesLeft = try c.decode(LenientInt.self, forKey: .retriesLeft)
        _retryAt = try c.decode(LenientString.self, forKey: .retryAt)
        progress = c.tol(OcrProgress.self, .progress)
        _docId = try c.decode(LenientInt.self, forKey: .docId)
        _receiptId = try c.decode(LenientInt.self, forKey: .receiptId)
        _createdAt = try c.decode(LenientString.self, forKey: .createdAt)
        _finishedAt = try c.decode(LenientString.self, forKey: .finishedAt)
        files = c.tolList(OcrFile.self, .files)
        _notes = try c.decode(LenientString.self, forKey: .notes)
        document = c.tol(OcrDocument.self, .document)
        _docNo = try c.decode(LenientString.self, forKey: .docNo)
        _docDate = try c.decode(LenientString.self, forKey: .docDate)
        _supplierName = try c.decode(LenientString.self, forKey: .supplierName)
        _totalGross = try c.decode(LenientDecimal.self, forKey: .totalGross)
        _linesCount = try c.decode(LenientInt.self, forKey: .linesCount)
    }
}

/// GET /api/seller/invoice-ocr?page=N
struct OcrHistory: Decodable {
    var items: [OcrJob] = []
    @LenientInt var total: Int?
    @LenientInt var page: Int?
    @LenientInt var perPage: Int?

    enum CodingKeys: String, CodingKey {
        case items, total, page
        case perPage = "per_page"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.tolList(OcrJob.self, .items)
        _total = try c.decode(LenientInt.self, forKey: .total)
        _page = try c.decode(LenientInt.self, forKey: .page)
        _perPage = try c.decode(LenientInt.self, forKey: .perPage)
    }
}

struct OcrPreviewRow: Decodable, Identifiable {
    @LenientInt var lineNo: Int?
    @LenientString var name: String?
    @LenientDecimal var stockQty: Decimal?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var updAmount: Decimal?
    @LenientDecimal var receiptAmount: Decimal?
    @LenientDecimal var diff: Decimal?
    @LenientBool var checkUnits: Bool?

    enum CodingKeys: String, CodingKey {
        case name, price, diff
        case lineNo = "line_no"
        case stockQty = "stock_qty"
        case updAmount = "upd_amount"
        case receiptAmount = "receipt_amount"
        case checkUnits = "check_units"
    }
    var id: Int { lineNo ?? 0 }
}

/// GET /{id}/receipt-preview
struct OcrPreview: Decodable {
    var rows: [OcrPreviewRow] = []
    @LenientDecimal var updTotal: Decimal?
    @LenientDecimal var receiptTotal: Decimal?
    @LenientDecimal var diff: Decimal?
    @LenientBool var diffBlocking: Bool?
    var skippedLines: [Int] = []
    var unmappedLines: [Int] = []
    var unconfirmedLines: [Int] = []
    var warnings: [String] = []

    enum CodingKeys: String, CodingKey {
        case rows, diff, warnings
        case updTotal = "upd_total"
        case receiptTotal = "receipt_total"
        case diffBlocking = "diff_blocking"
        case skippedLines = "skipped_lines"
        case unmappedLines = "unmapped_lines"
        case unconfirmedLines = "unconfirmed_lines"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = c.tolList(OcrPreviewRow.self, .rows)
        _updTotal = try c.decode(LenientDecimal.self, forKey: .updTotal)
        _receiptTotal = try c.decode(LenientDecimal.self, forKey: .receiptTotal)
        _diff = try c.decode(LenientDecimal.self, forKey: .diff)
        _diffBlocking = try c.decode(LenientBool.self, forKey: .diffBlocking)
        skippedLines = c.tolList(Int.self, .skippedLines)
        unmappedLines = c.tolList(Int.self, .unmappedLines)
        unconfirmedLines = c.tolList(Int.self, .unconfirmedLines)
        warnings = c.tolList(String.self, .warnings)
    }
}

/// POST /{id}/receipt. При already = true полей меньше — все необязательные.
struct OcrReceiptAck: Decodable {
    @LenientBool var already: Bool?
    @LenientInt var stockDocumentId: Int?
    @LenientString var number: String?
    @LenientBool var posted: Bool?
    @LenientString var postError: String?
    @LenientInt var lines: Int?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var diff: Decimal?

    enum CodingKeys: String, CodingKey {
        case already, number, posted, lines, total, diff
        case stockDocumentId = "stock_document_id"
        case postError = "post_error"
    }
}
