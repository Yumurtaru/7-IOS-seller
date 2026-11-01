import Foundation

// ============================================================================
//  ВА (сайт А618, П-64/П-65): признаки нового сервера в конверте `meta`.
//   • GET /api/seller/orders  → meta {sort: "old"|"new", search: строка|null}
//   • GET /api/seller/returns → meta {sort, search} (так же)
//   • GET /api/seller/clients → meta {sort, dir, segment, search}
//  Старый сервер отдаёт meta пустой (ключей нет) — тогда всё как раньше.
//  Правило: новое поведение включается только по ключу В КАЖДОМ ответе;
//  ключ пропал (сайт откатили) — прежнее поведение, выбор сбрасывается.
//  Тексты — дословно из ТЗ этапа, они же на Android (core/BaLogic.kt).
//  Здесь только чистая логика без сети и экранов.
// ============================================================================

/// Порядок списка заказов. «Сначала старые» → ?sort=old; «Сначала новые» — без параметра.
enum OrderSort: String, CaseIterable, Identifiable {
    case new, old

    var id: String { rawValue }
    var title: String {
        switch self {
        case .new: return "Сначала новые"
        case .old: return "Сначала старые"
        }
    }
    /// Значение ?sort=; nil — параметра нет (как раньше).
    var param: String? { self == .old ? "old" : nil }
}

/// Что сервер сказал про сегмент и сортировку клиентов, если это не совпало с отправленным.
struct ClientsMetaFix {
    /// Сегмент, который сервер применил (nil — «Все»). Менять в UI только при changeSegment.
    var segment: String?
    var changeSegment: Bool
    /// Сортировка, которую сервер применил, и направление (nil — ключа нет). Менять только при changeSort.
    var sort: String?
    var dir: String?
    var changeSort: Bool
}

enum Ba {
    static let returnsSearchUnavailable = "Поиск на сервере пока недоступен — показаны все возвраты"
    static let searchPlaceholder = "Номер, телефон или имя"

    // ── Разбор meta ──────────────────────────────────────────────────────────
    /// Ключ есть в meta (значение может быть null — ключ всё равно есть).
    static func hasKey(_ meta: [String: Any], _ key: String) -> Bool {
        meta.keys.contains(key)
    }

    /// Строковое значение ключа; нет ключа, null или не строка — nil.
    static func string(_ meta: [String: Any], _ key: String) -> String? {
        meta[key] as? String
    }

    // ── Заказы и возвраты ────────────────────────────────────────────────────
    /// Пункт «Сначала старые» показываем, только если в ответе есть meta.sort.
    static func sortAvailable(_ meta: [String: Any]) -> Bool {
        hasKey(meta, "sort")
    }

    /// Откат: просили «Сначала старые», а сервер применил не «old» (или ключ пропал).
    static func sortRolledBack(sent: OrderSort, meta: [String: Any]) -> Bool {
        sent == .old && string(meta, "sort") != "old"
    }

    /// Поиск отправили, а ключа meta.search нет. Только для возвратов: поиск заказов сервер
    /// знает с А116, а meta появился лишь в А618 — для заказов отсутствие ключа ничего не значит.
    static func searchMissing(sent: String?, meta: [String: Any]) -> Bool {
        guard let s = sent, !s.isEmpty else { return false }
        return !hasKey(meta, "search")
    }

    // ── Клиенты ──────────────────────────────────────────────────────────────
    private static let knownSegments: Set<String> = ["loyal", "at_risk", "churned"]

    /// Сверка meta ответа /clients с отправленным. nil — расхождений нет или ключей meta нет
    /// (старый сервер: прежняя логика). Каждый ключ сверяется отдельно, только если он пришёл.
    /// Сортировка сверяется, только если её отправляли (sentSort != nil).
    static func clientsFix(meta: [String: Any], sentSegment: String?,
                           sentSort: String?, sentDir: String?) -> ClientsMetaFix? {
        var fix = ClientsMetaFix(segment: nil, changeSegment: false, sort: nil, dir: nil, changeSort: false)
        let sent = (sentSegment ?? "").isEmpty ? nil : sentSegment
        if hasKey(meta, "segment") {
            var applied: String?
            if let raw = string(meta, "segment"), knownSegments.contains(raw) { applied = raw }
            if applied != sent {
                fix.segment = applied
                fix.changeSegment = true
            }
        }
        if let ss = sentSort, !ss.isEmpty, hasKey(meta, "sort") {
            let appliedSort = string(meta, "sort")
            let appliedDir = string(meta, "dir")
            let dirDiffers = hasKey(meta, "dir") && appliedDir != (sentDir ?? "desc")
            if appliedSort != ss || dirDiffers {
                fix.sort = appliedSort
                fix.dir = appliedDir
                fix.changeSort = true
            }
        }
        return (fix.changeSegment || fix.changeSort) ? fix : nil
    }
}
