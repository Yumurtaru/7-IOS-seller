import Foundation

// ============================================================================
//  Выгрузка заданиями (/api/seller/exports/…) и фиды площадок (/api/seller/feeds/…),
//  волна В4Б сайта (routes/seller_feeds.php).
//
//  Продавец декодирует БЕЗ convertFromSnakeCase: имена полей — явные CodingKeys.
//  Всё необязательное: старый сервер этих ручек не знает, поле может прийти числом
//  вместо строки или не прийти вовсе — один кривой элемент не должен ронять экран.
//  Размеры, строки и прогресс — @LenientInt; пустой набор фильтров у PHP бывает и {}, и [].
// ============================================================================

/// Вариант списка: фильтр select, формат, ставка НДС, категория. value — всегда строка.
struct ExpOption: Decodable, Hashable {
    @LenientString var value: String?
    @LenientString var label: String?
}

struct ExpFilter: Decodable, Identifiable {
    @LenientString var key: String?
    @LenientString var label: String?
    /// text / select / date / bool; незнакомый тип экран пропускает.
    @LenientString var type: String?
    var options: [ExpOption] = []

    enum CodingKeys: String, CodingKey { case key, label, type, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _key = try c.decode(LenientString.self, forKey: .key)
        _label = try c.decode(LenientString.self, forKey: .label)
        _type = try c.decode(LenientString.self, forKey: .type)
        options = c.tolList(ExpOption.self, .options)
    }

    var id: String { key ?? "" }
}

/// Объект фильтров пресета → [String: String]. Массив ([] у пустого набора) и мусор — пусто.
private struct ExpFiltersBox: Decodable {
    var values: [String: String] = [:]

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: AnyKey.self) else { return }
        for key in c.allKeys {
            if let s = try? c.decode(String.self, forKey: key) {
                if !s.trimmingCharacters(in: .whitespaces).isEmpty { values[key.stringValue] = s }
            } else if let i = try? c.decode(Int.self, forKey: key) {
                values[key.stringValue] = String(i)
            } else if let b = try? c.decode(Bool.self, forKey: key) {
                if b { values[key.stringValue] = "1" }
            }
        }
    }
}

struct ExpSpec: Decodable {
    var columns: [String] = []
    var filters: [String: String] = [:]
    @LenientString var format: String?

    enum CodingKeys: String, CodingKey { case columns, filters, format }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = c.tolList(String.self, .columns)
        filters = c.tol(ExpFiltersBox.self, .filters)?.values ?? [:]
        _format = try c.decode(LenientString.self, forKey: .format)
    }
}

struct ExpPreset: Decodable, Identifiable {
    @LenientString var presetId: String?
    @LenientString var name: String?
    var spec: ExpSpec?

    enum CodingKeys: String, CodingKey {
        case name, spec
        case presetId = "id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _presetId = try c.decode(LenientString.self, forKey: .presetId)
        _name = try c.decode(LenientString.self, forKey: .name)
        spec = c.tol(ExpSpec.self, .spec)
    }

    var id: String { presetId ?? "" }
}

struct ExpPresets: Decodable {
    var system: [ExpPreset] = []
    var saved: [ExpPreset] = []

    enum CodingKeys: String, CodingKey { case system, saved }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        system = c.tolList(ExpPreset.self, .system)
        saved = c.tolList(ExpPreset.self, .saved)
    }
}

/// GET /exports/{kind}/meta.
struct ExpMeta: Decodable {
    @LenientString var kind: String?
    @LenientString var title: String?
    var filters: [ExpFilter] = []
    var formats: [ExpOption] = []
    var presets: ExpPresets?

    enum CodingKeys: String, CodingKey { case kind, title, filters, formats, presets }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _kind = try c.decode(LenientString.self, forKey: .kind)
        _title = try c.decode(LenientString.self, forKey: .title)
        filters = c.tolList(ExpFilter.self, .filters)
        formats = c.tolList(ExpOption.self, .formats)
        presets = c.tol(ExpPresets.self, .presets)
    }
}

struct ExpJob: Decodable, Identifiable {
    @LenientInt var jobId: Int?
    @LenientString var kind: String?
    @LenientString var title: String?
    @LenientString var format: String?
    @LenientString var status: String?
    @LenientInt var rowsTotal: Int?
    @LenientInt var rowsDone: Int?
    @LenientInt var progress: Int?
    @LenientString var fileName: String?
    @LenientInt var size: Int?
    @LenientStringArray var warnings: [String]?
    @LenientString var error: String?
    @LenientString var createdAt: String?
    @LenientString var finishedAt: String?
    @LenientString var expiresAt: String?
    @LenientString var downloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case kind, title, format, status, progress, size, warnings, error
        case jobId = "id"
        case rowsTotal = "rows_total"
        case rowsDone = "rows_done"
        case fileName = "file_name"
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case expiresAt = "expires_at"
        case downloadUrl = "download_url"
    }

    var id: Int { jobId ?? 0 }
}

/// Ответ run / jobs/{id} / cancel.
struct ExpJobReply: Decodable {
    var job: ExpJob?

    enum CodingKeys: String, CodingKey { case job }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        job = c.tol(ExpJob.self, .job)
    }
}

struct ExpJobsReply: Decodable {
    var jobs: [ExpJob] = []

    enum CodingKeys: String, CodingKey { case jobs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobs = c.tolList(ExpJob.self, .jobs)
    }
}

// ── Фиды ────────────────────────────────────────────────────────────────────

struct FeedIssueExample: Decodable {
    @LenientString var exampleId: String?
    @LenientString var name: String?

    enum CodingKeys: String, CodingKey {
        case name
        case exampleId = "id"
    }
}

struct FeedIssue: Decodable {
    @LenientString var code: String?
    /// error / warn.
    @LenientString var level: String?
    @LenientString var title: String?
    @LenientInt var count: Int?
    var examples: [FeedIssueExample] = []

    enum CodingKeys: String, CodingKey { case code, level, title, count, examples }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _code = try c.decode(LenientString.self, forKey: .code)
        _level = try c.decode(LenientString.self, forKey: .level)
        _title = try c.decode(LenientString.self, forKey: .title)
        _count = try c.decode(LenientInt.self, forKey: .count)
        examples = c.tolList(FeedIssueExample.self, .examples)
    }
}

struct FeedHelp: Decodable {
    @LenientString var whereTo: String?
    @LenientStringArray var steps: [String]?
    @LenientStringArray var notes: [String]?

    enum CodingKeys: String, CodingKey {
        case steps, notes
        case whereTo = "where"
    }
}

struct FeedUtm: Decodable {
    @LenientString var source: String?
    @LenientString var medium: String?
    @LenientString var campaign: String?
}

struct FeedAvito: Decodable {
    @LenientString var category: String?
    @LenientString var goodsType: String?
    @LenientString var adType: String?
    @LenientString var address: String?
    @LenientString var phone: String?
    @LenientString var manager: String?

    enum CodingKeys: String, CodingKey {
        case category, address, phone, manager
        case goodsType = "goods_type"
        case adType = "ad_type"
    }
}

struct FeedGoogle: Decodable {
    @LenientString var brand: String?
    @LenientString var productCategory: String?

    enum CodingKeys: String, CodingKey {
        case brand
        case productCategory = "product_category"
    }
}

struct FeedOptions: Decodable {
    /// Номера категорий строками (сервер присылает числа).
    var categories: [String] = []
    @LenientBool var onlyAvailable: Bool?
    /// Наценка в процентах строкой "0.00".
    @LenientString var markup: String?
    @LenientBool var descFallback: Bool?
    var utm: FeedUtm?
    var avito: FeedAvito?
    var google: FeedGoogle?

    enum CodingKeys: String, CodingKey {
        case categories, markup, utm, avito, google
        case onlyAvailable = "only_available"
        case descFallback = "desc_fallback"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        categories = c.tolList(LenientString.self, .categories).compactMap { $0.wrappedValue }
        _onlyAvailable = try c.decode(LenientBool.self, forKey: .onlyAvailable)
        _markup = try c.decode(LenientString.self, forKey: .markup)
        _descFallback = try c.decode(LenientBool.self, forKey: .descFallback)
        utm = c.tol(FeedUtm.self, .utm)
        avito = c.tol(FeedAvito.self, .avito)
        google = c.tol(FeedGoogle.self, .google)
    }
}

struct FeedCard: Decodable, Identifiable {
    @LenientString var type: String?
    @LenientString var title: String?
    @LenientBool var exists: Bool?
    @LenientBool var enabled: Bool?
    /// off / building / ok / warn / error.
    @LenientString var status: String?
    @LenientString var url: String?
    @LenientBool var urlHidden: Bool?
    @LenientString var builtAt: String?
    @LenientInt var builtMinAgo: Int?
    @LenientInt var items: Int?
    @LenientInt var skipped: Int?
    @LenientInt var lastFetchMinAgo: Int?
    @LenientString var buildError: String?
    var issues: [FeedIssue] = []
    var options: FeedOptions?
    var help: FeedHelp?

    enum CodingKeys: String, CodingKey {
        case type, title, exists, enabled, status, url, items, skipped, issues, options, help
        case urlHidden = "url_hidden"
        case builtAt = "built_at"
        case builtMinAgo = "built_min_ago"
        case lastFetchMinAgo = "last_fetch_min_ago"
        case buildError = "build_error"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _type = try c.decode(LenientString.self, forKey: .type)
        _title = try c.decode(LenientString.self, forKey: .title)
        _exists = try c.decode(LenientBool.self, forKey: .exists)
        _enabled = try c.decode(LenientBool.self, forKey: .enabled)
        _status = try c.decode(LenientString.self, forKey: .status)
        _url = try c.decode(LenientString.self, forKey: .url)
        _urlHidden = try c.decode(LenientBool.self, forKey: .urlHidden)
        _builtAt = try c.decode(LenientString.self, forKey: .builtAt)
        _builtMinAgo = try c.decode(LenientInt.self, forKey: .builtMinAgo)
        _items = try c.decode(LenientInt.self, forKey: .items)
        _skipped = try c.decode(LenientInt.self, forKey: .skipped)
        _lastFetchMinAgo = try c.decode(LenientInt.self, forKey: .lastFetchMinAgo)
        _buildError = try c.decode(LenientString.self, forKey: .buildError)
        issues = c.tolList(FeedIssue.self, .issues)
        options = c.tol(FeedOptions.self, .options)
        help = c.tol(FeedHelp.self, .help)
    }

    var id: String { type ?? "" }
}

struct FeedVat: Decodable {
    /// "" (не указана) / none / 0 / 5 / 7 / 10 / 20 / 22.
    @LenientString var value: String?
    var options: [ExpOption] = []

    enum CodingKeys: String, CodingKey { case value, options }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _value = try c.decode(LenientString.self, forKey: .value)
        options = c.tolList(ExpOption.self, .options)
    }
}

struct FeedsReply: Decodable {
    var feeds: [FeedCard] = []
    var vat: FeedVat?
    var categories: [ExpOption] = []

    enum CodingKeys: String, CodingKey { case feeds, vat, categories }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feeds = c.tolList(FeedCard.self, .feeds)
        vat = c.tol(FeedVat.self, .vat)
        categories = c.tolList(ExpOption.self, .categories)
    }
}

/// Ответ enable / options / rotate / rebuild.
struct FeedReply: Decodable {
    var feed: FeedCard?

    enum CodingKeys: String, CodingKey { case feed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        feed = c.tol(FeedCard.self, .feed)
    }
}

/// Ответ POST feeds/vat.
struct FeedVatReply: Decodable {
    var vat: FeedVat?

    enum CodingKeys: String, CodingKey { case vat }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vat = c.tol(FeedVat.self, .vat)
    }
}
