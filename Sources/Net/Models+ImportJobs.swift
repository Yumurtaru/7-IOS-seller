import Foundation

// ============================================================================
//  Импорт заданиями (/api/seller/import/jobs/…), волна В4А сайта (routes/seller_import.php).
//
//  Продавец декодирует БЕЗ convertFromSnakeCase: имена полей — явные CodingKeys.
//  Всё необязательное: старый сервер этих ручек не знает, поле может прийти числом вместо
//  строки или не прийти вовсе. Вложенные блоки plan, counts, rollback, options и mapping — ImpJSON:
//  PHP отдаёт пустой массив как [] вместо {}, и строгая структура уронила бы разбор всего задания.
//  diff.from и diff.to сервер не нормализует (строка, число, null) — тоже ImpJSON.
// ============================================================================

/// Произвольное значение JSON: строка, число, флаг, null, массив или объект. Разбор никогда не падает на типе.
indirect enum ImpJSON: Decodable {
    case null
    case string(String)
    case number(String)
    case bool(Bool)
    case array([ImpJSON])
    case object([String: ImpJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        // Число раньше флага: старые версии JSONDecoder принимали 0 и 1 за Bool.
        else if let i = try? c.decode(Int.self) { self = .number(String(i)) }
        else if let d = try? c.decode(Double.self) { self = .number(String(d)) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([ImpJSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: ImpJSON].self) { self = .object(o) }
        else { self = .null }
    }

    /// Объект; массив ([] у PHP) и всё остальное — nil.
    var object: [String: ImpJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Текст значения; null, массив и объект — nil.
    var text: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var isBool: Bool {
        if case .bool = self { return true }
        return false
    }
}

struct ImpSheet: Decodable {
    @LenientString var name: String?
    @LenientInt var index: Int?
    @LenientBool var visible: Bool?
    @LenientInt var rows: Int?

    enum CodingKeys: String, CodingKey { case name, index, visible, rows }
}

/// Задание импорта (GET jobs/{id}, а также ответ preview / run / pause / resume / cancel / rollback).
struct ImpJob: Decodable, Identifiable {
    @LenientInt var jobId: Int?
    @LenientString var status: String?
    @LenientString var phase: String?
    @LenientString var target: String?
    @LenientString var mode: String?
    @LenientString var fileName: String?
    @LenientString var format: String?
    @LenientString var sheet: String?
    @LenientString var createdAt: String?
    @LenientString var startedAt: String?
    @LenientString var finishedAt: String?
    @LenientString var rolledBackAt: String?
    @LenientInt var totalRows: Int?
    @LenientInt var fileRows: Int?
    @LenientInt var cursor: Int?
    @LenientInt var progress: Int?
    var plan: ImpJSON?
    var counts: ImpJSON?
    var rollback: ImpJSON?
    var options: ImpJSON?
    var mapping: ImpJSON?
    @LenientString var stopReason: String?
    @LenientString var note: String?
    @LenientString var errorText: String?
    @LenientBool var stalled: Bool?
    @LenientBool var canRun: Bool?
    @LenientBool var canPause: Bool?
    @LenientBool var canResume: Bool?
    @LenientBool var canCancel: Bool?
    @LenientBool var canRollback: Bool?
    @LenientBool var hasErrorsFile: Bool?

    enum CodingKeys: String, CodingKey {
        case status, phase, target, mode, format, sheet, cursor, progress, plan, counts, rollback, options, mapping, note, stalled
        case jobId = "id"
        case fileName = "file_name"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case rolledBackAt = "rolled_back_at"
        case totalRows = "total_rows"
        case fileRows = "file_rows"
        case stopReason = "stop_reason"
        case errorText = "error_text"
        case canRun = "can_run"
        case canPause = "can_pause"
        case canResume = "can_resume"
        case canCancel = "can_cancel"
        case canRollback = "can_rollback"
        case hasErrorsFile = "has_errors_file"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _jobId = try c.decode(LenientInt.self, forKey: .jobId)
        _status = try c.decode(LenientString.self, forKey: .status)
        _phase = try c.decode(LenientString.self, forKey: .phase)
        _target = try c.decode(LenientString.self, forKey: .target)
        _mode = try c.decode(LenientString.self, forKey: .mode)
        _fileName = try c.decode(LenientString.self, forKey: .fileName)
        _format = try c.decode(LenientString.self, forKey: .format)
        _sheet = try c.decode(LenientString.self, forKey: .sheet)
        _createdAt = try c.decode(LenientString.self, forKey: .createdAt)
        _startedAt = try c.decode(LenientString.self, forKey: .startedAt)
        _finishedAt = try c.decode(LenientString.self, forKey: .finishedAt)
        _rolledBackAt = try c.decode(LenientString.self, forKey: .rolledBackAt)
        _totalRows = try c.decode(LenientInt.self, forKey: .totalRows)
        _fileRows = try c.decode(LenientInt.self, forKey: .fileRows)
        _cursor = try c.decode(LenientInt.self, forKey: .cursor)
        _progress = try c.decode(LenientInt.self, forKey: .progress)
        plan = c.tol(ImpJSON.self, .plan)
        counts = c.tol(ImpJSON.self, .counts)
        rollback = c.tol(ImpJSON.self, .rollback)
        options = c.tol(ImpJSON.self, .options)
        mapping = c.tol(ImpJSON.self, .mapping)
        _stopReason = try c.decode(LenientString.self, forKey: .stopReason)
        _note = try c.decode(LenientString.self, forKey: .note)
        _errorText = try c.decode(LenientString.self, forKey: .errorText)
        _stalled = try c.decode(LenientBool.self, forKey: .stalled)
        _canRun = try c.decode(LenientBool.self, forKey: .canRun)
        _canPause = try c.decode(LenientBool.self, forKey: .canPause)
        _canResume = try c.decode(LenientBool.self, forKey: .canResume)
        _canCancel = try c.decode(LenientBool.self, forKey: .canCancel)
        _canRollback = try c.decode(LenientBool.self, forKey: .canRollback)
        _hasErrorsFile = try c.decode(LenientBool.self, forKey: .hasErrorsFile)
    }

    var id: Int { jobId ?? 0 }
}

/// GET jobs: история (без заданий в статусе uploaded).
struct ImpJobsReply: Decodable {
    var jobs: [ImpJob] = []

    enum CodingKeys: String, CodingKey { case jobs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobs = c.tolList(ImpJob.self, .jobs)
    }
}

/// GET jobs/active: незавершённое задание или null.
struct ImpActiveReply: Decodable {
    var job: ImpJob?

    enum CodingKeys: String, CodingKey { case job }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job = c.tol(ImpJob.self, .job)
    }
}

struct ImpDiff: Decodable {
    @LenientString var field: String?
    @LenientString var label: String?
    var from: ImpJSON?
    var to: ImpJSON?

    enum CodingKeys: String, CodingKey { case field, label, from, to }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _field = try c.decode(LenientString.self, forKey: .field)
        _label = try c.decode(LenientString.self, forKey: .label)
        from = c.tol(ImpJSON.self, .from)
        to = c.tol(ImpJSON.self, .to)
    }
}

struct ImpRowError: Decodable {
    @LenientString var field: String?
    @LenientString var label: String?
    @LenientString var message: String?
    /// error / warning / info.
    @LenientString var level: String?
    @LenientString var code: String?

    enum CodingKeys: String, CodingKey { case field, label, message, level, code }
}

struct ImpRow: Decodable, Identifiable {
    @LenientInt var ord: Int?
    @LenientInt var line: Int?
    /// add / update / unchanged / skip / error; пусто — ещё не разобрано.
    @LenientString var action: String?
    @LenientString var name: String?
    @LenientString var key: String?
    @LenientString var price: String?
    @LenientInt var productId: Int?
    @LenientBool var applied: Bool?
    var diff: [ImpDiff] = []
    var errors: [ImpRowError] = []

    enum CodingKeys: String, CodingKey {
        case ord, line, action, name, key, price, applied, diff, errors
        case productId = "product_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _ord = try c.decode(LenientInt.self, forKey: .ord)
        _line = try c.decode(LenientInt.self, forKey: .line)
        _action = try c.decode(LenientString.self, forKey: .action)
        _name = try c.decode(LenientString.self, forKey: .name)
        _key = try c.decode(LenientString.self, forKey: .key)
        _price = try c.decode(LenientString.self, forKey: .price)
        _productId = try c.decode(LenientInt.self, forKey: .productId)
        _applied = try c.decode(LenientBool.self, forKey: .applied)
        diff = c.tolList(ImpDiff.self, .diff)
        errors = c.tolList(ImpRowError.self, .errors)
    }

    /// Номер строки файла уникален в пределах задания; запасной — порядок разбора.
    var id: Int { ord ?? line ?? 0 }
}

/// GET jobs/{id}/rows.
struct ImpRowsReply: Decodable {
    var rows: [ImpRow] = []
    @LenientInt var total: Int?
    @LenientInt var page: Int?
    @LenientInt var pages: Int?
    @LenientInt var perPage: Int?

    enum CodingKeys: String, CodingKey {
        case rows, total, page, pages
        case perPage = "per_page"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rows = c.tolList(ImpRow.self, .rows)
        _total = try c.decode(LenientInt.self, forKey: .total)
        _page = try c.decode(LenientInt.self, forKey: .page)
        _pages = try c.decode(LenientInt.self, forKey: .pages)
        _perPage = try c.decode(LenientInt.self, forKey: .perPage)
    }
}
