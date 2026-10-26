import Foundation

// ============================================================================
//  «Помощник Yumurta» (сайт А100): разбор ответа модели и тексты ошибок.
//  Только Foundation — проверяется отдельно (как render() веб-виджета
//  assets/js/assistant.js и AssistantText.kt на Android). Ответ — короткий
//  markdown: абзацы, списки «- » и «1. », **жирный**, ссылки полным адресом.
//  Нажимаются ТОЛЬКО ссылки самого сайта (yumurta.ru и API.base) и
//  относительные «/help/…»: модель могла бы — по подсказке из вопроса или
//  названия заведения — вывести чужую (фишинговую) ссылку. Чужой адрес
//  остаётся простым текстом (так же делает сайт).
// ============================================================================

/// Кусок строки: text — что показать, url — куда ведёт (nil — не ссылка).
struct AsstSpan: Equatable {
    var text: String
    var bold = false
    var italic = false
    var code = false
    var url: String?
}

/// Блок ответа: абзац (heading — строка «## …») или пункт списка с маркером «•» / «1.».
enum AsstBlock: Equatable {
    case para([AsstSpan], heading: Bool)
    case item(marker: String, [AsstSpan])

    var spans: [AsstSpan] {
        switch self {
        case .para(let s, _): return s
        case .item(_, let s): return s
        }
    }
}

/// Источник для строки «Источники:» — полный адрес своего сайта.
struct AsstSourceLink: Equatable {
    let title: String
    let url: String
}

enum AssistantText {
    /// Аудитория приложения продавца — организация, выбранная на сервере.
    static let audience = "seller"
    /// Где человек задаёт вопрос (поле page: сервер вставляет его в подсказку модели).
    static let page = "Приложение Yumurta для продавца iOS"
    /// Предел вопроса, если сервер его не прислал (Assistant::MAX_TEXT).
    static let defaultMax = 2000

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Шаблоны — константы этого файла: ошибка в них ловится проверкой, а не у человека.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let bullet = rx("^[-*•]\\s+(.*)$")
    private static let numbered = rx("^(\\d{1,3})[.)]\\s+(.*)$")
    private static let heading = rx("^#{1,6}\\s+(.*)$")
    private static let rule = rx("^[-*_]{3,}$")
    // Группы: 1–2 [текст](адрес), 3 голый адрес, 4 «/help/…», 5 **жирный**, 6 *курсив*, 7 `код`.
    private static let inlineRx = rx(
        "\\[([^\\[\\]\\n]+)\\]\\(\\s*(https?://[^\\s()<>]+|/help/[A-Za-z0-9\\-]+/?)\\s*\\)"
        + "|(https?://[^\\s<>\"'()\\[\\]*]*[^\\s<>\"'()\\[\\]*.,;:!?])"
        + "|(?<![^\\s(])(/help/[a-z0-9\\-]+)"
        + "|\\*\\*([^*]+)\\*\\*"
        + "|(?<![*\\p{L}\\p{N}])\\*([^*\\s](?:[^*]*[^*\\s])?)\\*(?![*\\p{L}\\p{N}])"
        + "|`([^`\\n]+)`")
    private static let hostRx = rx("^https?://([^/?#:\\s]+)(?::\\d+)?([/?#].*)?$", [.caseInsensitive])
    private static let schemeRx = rx("^https?://(www\\.)?", [.caseInsensitive])
    private static let chatIdRx = rx("^[a-f0-9]{32}$")

    private static func match(_ r: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
        return String(s[rr])
    }

    /// Ответ помощника → блоки. base — адрес сайта (API.base).
    static func parse(_ md: String?, base: String) -> [AsstBlock] {
        var out: [AsstBlock] = []
        let text = (md ?? "").replacingOccurrences(of: "\r", with: "")
        for raw in text.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || match(rule, l) != nil { continue }
            if let m = match(bullet, l), let t = group(m, 1, l) {
                out.append(.item(marker: "•", inline(t, base: base)))
            } else if let m = match(numbered, l), let n = group(m, 1, l), let t = group(m, 2, l) {
                out.append(.item(marker: n + ".", inline(t, base: base)))
            } else if let m = match(heading, l), let t = group(m, 1, l) {
                out.append(.para(inline(t, base: base, bold: true), heading: true))
            } else {
                out.append(.para(inline(l, base: base), heading: false))
            }
        }
        return out
    }

    /// Строка → куски с жирным/курсивом/кодом и ссылками своего сайта.
    static func inline(_ s: String, base: String, bold: Bool = false) -> [AsstSpan] {
        var out: [AsstSpan] = []
        // Соседний простой текст того же вида — одним куском (чужой адрес — тоже простой текст).
        func plain(_ t: String) {
            guard !t.isEmpty else { return }
            if let last = out.last, last.url == nil, last.bold == bold, !last.italic, !last.code {
                out[out.count - 1].text += t
            } else {
                out.append(AsstSpan(text: t, bold: bold))
            }
        }
        let ns = s as NSString
        var pos = 0
        for m in inlineRx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            plain(ns.substring(with: NSRange(location: pos, length: m.range.location - pos)))
            if let label = group(m, 1, s), let target = group(m, 2, s) {
                let t = label.trimmingCharacters(in: .whitespaces)
                if let url = ownURL(target, base: base) { out.append(AsstSpan(text: t, bold: bold, url: url)) }
                else { plain(t + " (" + target + ")") }
            } else if let u = group(m, 3, s) {
                if let url = ownURL(u, base: base) { out.append(AsstSpan(text: shortURL(u), bold: bold, url: url)) }
                else { plain(u) }
            } else if let p = group(m, 4, s) {
                out.append(AsstSpan(text: p, bold: bold, url: ownURL(p, base: base)))
            } else if let b = group(m, 5, s) {
                out.append(contentsOf: inline(b, base: base, bold: true))
            } else if let i = group(m, 6, s) {
                out.append(AsstSpan(text: i, bold: bold, italic: true))
            } else if let c = group(m, 7, s) {
                out.append(AsstSpan(text: c, bold: bold, code: true))
            }
            pos = m.range.location + m.range.length
        }
        plain(ns.substring(from: pos))
        return out
    }

    /// Полный адрес, если ссылка ведёт на свой сайт: yumurta.ru (с www или без),
    /// хост API.base или относительный «/…». Иначе nil — ссылку не делаем.
    static func ownURL(_ raw: String, base: String) -> String? {
        let u = raw.trimmingCharacters(in: .whitespaces)
        var root = base
        while root.hasSuffix("/") { root.removeLast() }
        if u.hasPrefix("/") && !u.hasPrefix("//") { return root + u }
        guard let m = match(hostRx, u), let h = group(m, 1, u) else { return nil }
        let own: Set<String> = ["yumurta.ru", host(of: root)]
        return own.contains(stripWWW(h.lowercased())) ? u : nil
    }

    private static func stripWWW(_ h: String) -> String { h.hasPrefix("www.") ? String(h.dropFirst(4)) : h }

    private static func host(of url: String) -> String {
        guard let m = match(hostRx, url), let h = group(m, 1, url) else { return "" }
        return stripWWW(h.lowercased())
    }

    /// Подпись ссылки — без «https://» и «www.», как на сайте.
    static func shortURL(_ u: String) -> String {
        schemeRx.stringByReplacingMatches(in: u, range: NSRange(u.startIndex..., in: u), withTemplate: "")
    }

    /// Текст для VoiceOver: блоки строками, пункты — с маркером.
    static func plainText(_ blocks: [AsstBlock]) -> String {
        blocks.map { b -> String in
            let t = b.spans.map(\.text).joined()
            if case .item(let marker, _) = b { return marker + " " + t }
            return t
        }.joined(separator: "\n")
    }

    /// «Источники:» — статьи, на которые ответ опирался, но ссылкой в тексте их нет
    /// (cited = false), не больше двух — как в веб-виджете. Адрес — свой сайт.
    static func sources(_ list: [AssistantSource]?, base: String) -> [AsstSourceLink] {
        var out: [AsstSourceLink] = []
        for s in list ?? [] where !s.cited {
            guard let raw = s.url, !raw.isEmpty, let url = ownURL(raw, base: base) else { continue }
            let t = (s.title ?? "").trimmingCharacters(in: .whitespaces)
            out.append(AsstSourceLink(title: t.isEmpty ? "Статья" : t, url: url))
            if out.count == 2 { break }
        }
        return out
    }

    /// Текст ошибки отправки вопроса. 502 (и 504 хостинга) — модель не ответила:
    /// вопрос уже сохранён на сервере (routes/assistant.php пишет его ДО вызова
    /// модели), поэтому кнопки «Повторить» нет — как на сайте: повтор задвоил бы
    /// вопрос в переписке и в дневном лимите. Предлагаем спросить заново или
    /// позвать человека. Остальное (422 пусто/длинно,
    /// 429 дневной лимит, 503 выключен/перегружен, 404 переписка не найдена) —
    /// текст сервера как есть.
    static func errorText(status: Int, message: String) -> String {
        isNoAnswer(status) ? "Помощник не ответил — попробуйте спросить ещё раз или позовите человека" : message
    }

    /// Модель не ответила — вопрос остался в переписке (на экране — до перечитывания).
    static func isNoAnswer(_ status: Int) -> Bool { status == 502 || status == 504 }

    /// Ответ пришёл: убрать свой временный пузырь localId и добавить вопрос и ответ
    /// сервера в конец. Остальное — как было и на своих местах, в том числе вопрос,
    /// сохранённый после 502 (временный id < 0, пока переписку не перечитали).
    static func appendAnswer(_ list: [AssistantMessage], localId: Int, _ add: [AssistantMessage]) -> [AssistantMessage] {
        let ids = Set(add.map(\.id))
        return list.filter { $0.id != localId && !ids.contains($0.id) } + add
    }

    /// Публичный id переписки — 32 hex (Assistant::newPublicId, проверка findChat).
    static func isChatId(_ s: String?) -> Bool {
        guard let s else { return false }
        return match(chatIdRx, s) != nil
    }

    /// «Осталось вопросов сегодня: N» — только когда осталось мало (≤ 5).
    static func leftNote(_ left: Int?) -> String? {
        guard let left, (0...5).contains(left) else { return nil }
        return "Осталось вопросов сегодня: \(left)"
    }

    /// Повторный тап по той же оценке снимает её (0).
    static func nextRating(current: Int?, tapped: Int) -> Int { current == tapped ? 0 : tapped }

    /// Ключ хранения id переписки: на аккаунт и организацию (переписка привязана к магазину).
    static func storeKey(userId: Int?, shopId: Int?) -> String { "asst_chat_\(userId ?? 0)_\(shopId ?? 0)" }

    /// Кусок → AttributedString для Text: у ссылки — .link (SwiftUI делает её
    /// нажимаемой, открытие перехватывает openURL экрана). Жирный/курсив/код
    /// накладываются на Text (AssistantView), куски склеиваются через «+».
    static func piece(_ s: AsstSpan) -> AttributedString {
        var a = AttributedString(s.text)
        if let u = s.url, let url = URL(string: u) { a.link = url }
        return a
    }
}
