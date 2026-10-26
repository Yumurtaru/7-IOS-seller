import Foundation
import os
import UIKit

// ============================================================================
//  API.swift — сетевой слой «Yumurta Бизнес»
// ----------------------------------------------------------------------------
//  Сервер: PHP, core/Response.php. Формат КАЖДОГО ответа seller-API:
//    { "ok": bool, "data": mixed, "error": string|null, "errors": object|[] , "meta": {} }
//  Отдельный случай — /api/v1/auth/refresh и /api/v1/push/register (формат v1):
//    { "success": bool, "data": mixed, "meta": null, "error": {"message": ...} }
//  Авторизация: Bearer JWT (reg.ru-обход уже на сервере — просто шлём заголовок).
//  Токены — в Keychain. 401 → single-flight refresh через actor → 1 повтор → logout.
// ============================================================================

enum APIError: LocalizedError {
    case server(String)   // ошибка уровня приложения (ok=false) — показываем текст сервера
    case http(Int)        // HTTP-статус ошибки без текста
    case network          // нет соединения
    case timeout          // истёк таймаут
    case unauthorized     // 401 после неудачного refresh — нужен повторный вход
    case decoding

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        // Сбой сервера без текста — подсказываем, что можно повторить (набранное не теряется).
        case .http(let c):   return "Ошибка сервера (\(c)) — попробуйте ещё раз через минуту"
        case .network:       return "Нет соединения с интернетом"
        // Без сети запрос ждёт связь (waitsForConnectivity) и кончается таймаутом —
        // подсказываем про интернет, а не только «время вышло».
        case .timeout:       return "Нет ответа от сервера — проверьте интернет и попробуйте ещё раз"
        case .unauthorized:  return "Сессия истекла, войдите снова"
        case .decoding:      return "Не удалось обработать ответ сервера"
        }
    }

    /// Повторяем только сетевые сбои и 5xx (и только для GET).
    /// Таймаут не повторяем: без сети каждая попытка ждёт связь до 60 с,
    /// и с двумя повторами крутилка висела ~3 минуты вместо ошибки.
    var isRetryable: Bool {
        switch self {
        case .network: return true
        case .http(let c):       return c >= 500
        default:                 return false
        }
    }
    /// Таймаут повторяем один раз: сеть могла мигнуть, но два-три ожидания
    /// по 20 с подряд — это минута «вечной загрузки».
    var isTimeout: Bool { if case .timeout = self { return true }; return false }
}

// ── Конверт seller-API (core/Response.php) ──────────────────────────────────
struct SellerEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
    let errors: [String: [String]]?
    /// П-27.14: машинный код отказа (idempotency_in_progress, idempotency_key_reused…).
    /// Старый сервер его не шлёт — nil, всё как раньше.
    let code: String?

    enum CodingKeys: String, CodingKey { case ok, data, error, errors, code }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = (try? c.decode(Bool.self, forKey: .ok)) ?? false
        code = (try? c.decodeIfPresent(String.self, forKey: .code)) ?? nil
        // Разошлось поле с сервером — data = nil, как и раньше (экран покажет «Не удалось
        // обработать ответ»), но причина с путём поля уходит в журнал, а не теряется.
        do { data = try c.decodeIfPresent(T.self, forKey: .data) }
        catch { data = nil; SellerDecodeLog.report(error, T.self) }
        // error бывает и строкой, и объектом {message} (конверт v1, 429) —
        // раньше объект терялся, и вместо текста сервера было «Ошибка сервера».
        var details: [String: [String]]?
        if let s = try? c.decodeIfPresent(String.self, forKey: .error) {
            error = s
        } else if let o = try? c.decodeIfPresent(SellerErrorObject.self, forKey: .error) {
            error = o.message
            details = o.details
        } else {
            error = nil
        }
        // Response::validation шлёт объект {field:[msg]}, Response::error — [] (пустой массив PHP).
        // А57/П-22.10, П-20.1: текст поля бывает и строкой ({"until_minutes":"…"},
        // {"audience_value":"…"}) — раньше такой объект не разбирался целиком,
        // и вместо причины отказа показывалось общее «Проверьте данные».
        var fieldErrs: [String: [String]]?
        if let strict = try? c.decodeIfPresent([String: [String]].self, forKey: .errors) {
            fieldErrs = strict
        } else if let loose = try? c.decodeIfPresent([String: SellerErrorValue].self, forKey: .errors) {
            let msgs = loose.compactMapValues { $0.messages.isEmpty ? nil : $0.messages }
            fieldErrs = msgs.isEmpty ? nil : msgs
        }
        // М1: конверт v1 кладёт ошибки полей в error.details — раньше они терялись.
        if fieldErrs == nil, let d = details, !d.isEmpty { fieldErrs = d }
        errors = fieldErrs
    }

    /// Сервер прислал хоть какой-то текст ошибки.
    var hasErrorText: Bool {
        (error.map { !$0.isEmpty } ?? false) || !fieldMessages.isEmpty
    }

    /// М1: сообщения полей — по алфавиту ключей (словарь без порядка, и «первым»
    /// раньше было случайное поле), без повторов, не больше трёх. Только текст
    /// с кириллицей: коды и английский пользователю не показываем.
    var fieldMessages: [String] {
        guard let errors else { return [] }
        var out: [String] = []
        for key in errors.keys.sorted() {
            for raw in errors[key] ?? [] {
                let m = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !m.isEmpty, SellerErrorText.isHuman(m) else { continue }
                let text = SellerErrorText.withLabel(m, field: key)
                if !out.contains(text) { out.append(text) }
            }
        }
        return Array(out.prefix(3))
    }

    /// Человекочитаемый текст ошибки: текст сервера + сообщения полей
    /// (М1: все поля, а не одно — «широта» и «долгота» неверны обе).
    var errorText: String {
        var parts: [String] = []
        if let e = error, !e.isEmpty { parts.append(e) }
        let fields = fieldMessages.filter { $0 != error }
        if !fields.isEmpty { parts.append(fields.joined(separator: "; ")) }
        return parts.isEmpty ? "Ошибка сервера" : parts.joined(separator: ": ")
    }
}

/// Ошибка объектом: {"message": "…", "details": {поле: [текст]}} (конверт v1).
/// details бывает null, объектом или чем-то иным — разбираем мягко.
private struct SellerErrorObject: Decodable {
    let message: String?
    let details: [String: [String]]?

    enum CodingKeys: String, CodingKey { case message, details }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? nil
        if let loose = try? c.decodeIfPresent([String: SellerErrorValue].self, forKey: .details) {
            let msgs = loose.compactMapValues { $0.messages.isEmpty ? nil : $0.messages }
            details = msgs.isEmpty ? nil : msgs
        } else {
            details = nil
        }
    }
}

/// М1: общие помощники текста ошибок.
enum SellerErrorText {
    /// Есть кириллица — это сообщение для человека, а не код.
    static func isHuman(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Общие тексты core/Validator.php не называют поле («Поле обязательно
    /// для заполнения») — без подписи непонятно, что исправить. Подписываем
    /// известные поля; свои тексты сервера оставляем как есть.
    static func withLabel(_ message: String, field: String) -> String {
        let generic = ["Поле обязательно для заполнения", "Некорректный e-mail", "Некорректный номер телефона",
                       "Должно быть целым числом", "Должно быть числом", "Некорректная ссылка",
                       "Недопустимое значение", "Некорректный ИНН", "Значения не совпадают",
                       "Некорректное значение"]
        let isGeneric = generic.contains(message)
            || message.hasPrefix("Минимальная длина:") || message.hasPrefix("Максимальная длина:")
        guard isGeneric, let label = labels[field] else { return message }
        return label + ": " + message.prefix(1).lowercased() + String(message.dropFirst())
    }

    private static let labels: [String: String] = [
        "name": "Название", "price": "Цена", "email": "E-mail", "phone": "Телефон",
        "password": "Пароль", "login": "Логин", "inn": "ИНН", "address": "Адрес",
    ]
}

/// А57/П-22.10: значение в errors — строка или массив строк. Берём только
/// человеческий текст (с кириллицей): коды вроде {"status":"cancelled"} и числа
/// в сообщение не добавляем.
private struct SellerErrorValue: Decodable {
    let messages: [String]
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        var raw: [String] = []
        if let s = try? c.decode(String.self) { raw = [s] }
        else if let a = try? c.decode([String].self) { raw = a }
        messages = raw.filter { s in
            s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        }
    }
}

/// Журнал ошибок разбора ответа: Console.app / Xcode, категория «decode».
enum SellerDecodeLog {
    static let logger = Logger(subsystem: "ru.marketplace.business", category: "decode")
    static func report(_ error: Error, _ type: Any.Type) {
        let what = String(describing: type)
        let why = describe(error)
        logger.error("Не разобран \(what, privacy: .public): \(why, privacy: .public)")
    }
    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return String(describing: error) }
        func path(_ keys: [CodingKey]) -> String {
            keys.reduce("") { acc, key in
                if let i = key.intValue { return acc + "[\(i)]" }
                return acc.isEmpty ? key.stringValue : acc + "." + key.stringValue
            }
        }
        switch e {
        case .typeMismatch(let t, let ctx):  return "тип \(t) в \(path(ctx.codingPath))"
        case .valueNotFound(let t, let ctx): return "нет значения \(t) в \(path(ctx.codingPath))"
        case .keyNotFound(let k, let ctx):   return "нет ключа \(k.stringValue) в \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx):        return "битые данные в \(path(ctx.codingPath))"
        @unknown default:                    return String(describing: e)
        }
    }
}

/// Пустая полезная нагрузка (когда data не нужна).
struct EmptyData: Decodable {}

/// П-27.14: отказ сервера по ключу повтора (запрос с Idempotency-Key).
/// in_progress — первый запрос с этим ключом ещё идёт (ждём 2 с и повторяем
/// один раз); key_reused — ключ уже ушёл на другое тело. Текст — сервера,
/// поэтому экраны, которые показывают localizedDescription, пишут то же, что раньше.
struct IdempotencyError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// А80: отказ сервера с машинным кодом и ошибками полей — только для запросов,
/// которые сами попросили подробности (вызов курьера Yumurta: 422 по полям,
/// 409 price_changed с новой ценой в errors.fee). Текст — тот же, что был бы у
/// APIError.server, поэтому localizedDescription не меняется. fields — как
/// прислал сервер, без отбора по кириллице (там бывает и цена "7750.00").
struct APIDetailedError: LocalizedError {
    let status: Int
    let code: String?
    let message: String
    let fields: [String: [String]]
    /// А91: только текст сервера (error), без сообщений полей — для отказов, где
    /// объяснение в error, а в errors служебное «не больше 0.00». nil — текста нет.
    var serverError: String? = nil
    /// Номер документа из errors ответа (Response::error(…, ['document_id' => N])):
    /// складской документ создан черновиком, а провести не вышло. nil — нет.
    var documentId: Int? = nil
    var errorDescription: String? { message }
}

/// П-27.14: ключи повтора для создания записей. Один ключ на одно и то же
/// нажатие: тот же запрос (путь + тело) после обрыва уходит с ТЕМ ЖЕ ключом,
/// и сервер не создаёт дубль, а отдаёт уже созданное. После ответа сервера
/// ключ забываем — следующее «Создать» уже новое действие.
final class IdempotencyKeys: @unchecked Sendable {
    static let shared = IdempotencyKeys()
    private let lock = NSLock()
    private var keys: [String: (key: String, at: Date)] = [:]
    /// Срок жизни ключа; nil — без срока. Общий набор — 5 минут. Набор ФОРМЫ
    /// (IdempotencyKeys.form()) живёт, пока живёт окно: «нажмите ещё раз» через
    /// 6 минут после обрыва уходит с тем же ключом, а новое окно — с новым.
    private let ttl: TimeInterval?

    init(ttl: TimeInterval? = 300) { self.ttl = ttl }

    /// Ключи одного экземпляра формы (окна): без срока, пропадают вместе с окном.
    static func form() -> IdempotencyKeys { IdempotencyKeys(ttl: nil) }

    func key(for fingerprint: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        // Старые ключи убираем: повтор позже 5 минут — уже другое действие (после
        // удаления и такого же создания старый ключ вернул бы прежний ответ, и
        // запись молча не создалась бы).
        if let ttl { keys = keys.filter { now.timeIntervalSince($0.value.at) < ttl } }
        if let k = keys[fingerprint] { return k.key }
        let k = UUID().uuidString
        keys[fingerprint] = (k, now)
        return k
    }

    func forget(_ fingerprint: String) {
        lock.lock(); defer { lock.unlock() }
        keys.removeValue(forKey: fingerprint)
    }

    /// Исход стал известен (перечитали изменившийся заказ) — все ключи формы забыть.
    func forgetAll() {
        lock.lock(); defer { lock.unlock() }
        keys.removeAll()
    }
}

// ── Actor очереди обновления токена (single-flight) ─────────────────────────
// Параллельные 401 ждут ОДИН общий вызов /api/v1/auth/refresh — токен не
// перезатирается гонкой, сервер не получает шквал refresh-запросов.
/// Итог обновления токена. transient — сбой сети/сервера (5xx, 429, таймаут):
/// сессию НЕ сбрасываем, запрос просто падает с сетевой ошибкой. invalid — сервер
/// явно отверг refresh-токен (или его нет) — только тогда нужен повторный вход.
enum RefreshOutcome {
    case ok(String)
    case invalid
    case transient
}

actor TokenRefresher {
    private var inFlight: Task<RefreshOutcome, Never>?

    func refresh(base: String) async -> RefreshOutcome {
        if let running = inFlight { return await running.value }
        let task = Task<RefreshOutcome, Never> {
            defer { Task { await self.clear() } }
            guard let refresh = Keychain.get(.refreshToken), !refresh.isEmpty,
                  let url = URL(string: base + "/api/v1/auth/refresh") else { return .invalid }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 20
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return .transient }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .invalid }
            guard status == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["success"] as? Bool) == true,
                  let payload = json["data"] as? [String: Any],
                  let token = payload["token"] as? String, !token.isEmpty else { return .transient }
            // Пока шло продление, нажали «Выйти» (или вошли в другой аккаунт):
            // новый токен прежней сессии в Keychain не пишем — иначе после
            // перезапуска приложение снова открывалось вышедшим аккаунтом.
            guard Keychain.get(.refreshToken) == refresh else { return .transient }
            Keychain.set(token, for: .accessToken)
            API.clearCookies()   // ответ refresh снова кладёт токены в cookie — убираем
            return .ok(token)
        }
        inFlight = task
        return await task.value
    }

    private func clear() { inFlight = nil }
}

// ── Фоновое время для сохранений ────────────────────────────────────────────
// Свернули приложение посреди сохранения или загрузки фото — iOS через пару
// секунд замораживала запрос: сервер уже сохранил (создал товар, провёл
// документ), а экран получал «нет соединения», и повтор делал дубль.
// На время POST/PUT/DELETE просим у системы фоновое время (до ~30 с).
final class BackgroundSaveToken: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
}

enum BackgroundSave {
    @MainActor static func begin() -> BackgroundSaveToken {
        let token = BackgroundSaveToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "yumurta.save") {
            // Время вышло — закрываем сами, иначе iOS завершит приложение.
            guard token.id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(token.id)
            token.id = .invalid
        }
        return token
    }

    static func end(_ token: BackgroundSaveToken) {
        Task { @MainActor in
            guard token.id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(token.id)
            token.id = .invalid
        }
    }
}

// ── Клиент ───────────────────────────────────────────────────────────────────
final class API {
    static let shared = API()
    static let base = "https://yumurta.ru"

    /// Вызывается при окончательном 401 (refresh не помог) — Session разлогинивает.
    var onUnauthorized: (() -> Void)?

    private let refresher = TokenRefresher()
    private let maxRetries = 2   // доп. попытки для GET (итого до 3)

    private let decoder = JSONDecoder()   // имена полей 1:1 через CodingKeys — без convertFromSnakeCase

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// А60/П-23.6: запуск импорта на большом файле идёт дольше минуты — для него
    /// отдельная сессия с длинным ожиданием ответа (обычная обрывала через 20 с,
    /// и владелец видел ошибку при идущем импорте). Без ожидания связи: обрыв
    /// сразу уходит в опрос статуса.
    private let longSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 300
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// Понятный текст для 4xx без текста сервера (ответ веб-сервера, пустое тело).
    /// Раньше показывалось голое «Ошибка 403» / «Ошибка 413».
    /// Целое из errors ответа (сервер кладёт туда служебные числа, например
    /// document_id) — конверт берёт из errors только тексты. Нет — nil.
    static func errorsInt(_ data: Data, _ key: String) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errs = root["errors"] as? [String: Any] else { return nil }
        if let n = errs[key] as? NSNumber { return n.intValue }
        if let t = errs[key] as? String { return Int(t) }
        return nil
    }

    static func statusText(_ code: Int) -> String {
        switch code {
        case 403: return "Нет доступа: у вашей роли нет права на это действие"
        case 404: return "Не найдено — возможно, запись уже удалена"
        case 409: return "Данные уже изменились — обновите экран"
        case 413: return "Файл слишком большой — выберите файл поменьше"
        case 422: return "Проверьте правильность заполнения"
        case 429: return "Слишком много запросов — подождите минуту и повторите"
        // М1: сбой сервера — подсказываем повтор; вместо голого «Ошибка 400» — понятная фраза.
        case 500...: return "Ошибка сервера (\(code)) — попробуйте ещё раз через минуту"
        default:  return "Запрос не выполнен (код \(code)) — попробуйте ещё раз"
        }
    }

    /// М1: «Внутренняя ошибка сервера» (500/502/504) — временный сбой: добавляем,
    /// что можно повторить. 501/503 («не настроено», «примените миграцию») не трогаем.
    static func withRetryHint(_ text: String, status: Int) -> String {
        guard status == 500 || status == 502 || status == 504,
              !text.lowercased().contains("попробуйте") else { return text }
        return text + " — попробуйте ещё раз через минуту"
    }

    static func imageURL(_ path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        // Пробел или кириллица в имени файла: на iOS 16 URL(string:) даёт nil,
        // и фото не показывалось. Кодируем, только если иначе адрес не собрать.
        func url(_ s: String) -> URL? {
            URL(string: s) ?? s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        }
        if p.hasPrefix("http") { return url(p) }
        return url(base + "/assets/uploads/" + p.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    // ── Публичные методы ─────────────────────────────────────────────────────

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type) async throws -> T {
        try await send(makeRequest("GET", path, query: query), as: type)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any?] = [:], as type: T.Type) async throws -> T {
        try await send(makeRequest("POST", path, jsonBody: body), as: type)
    }

    /// А81: POST, отказ которого нужен с кодом и полями (APIDetailedError: status,
    /// code, fields) — жалоба на курьера (409 complaint_exists, 422 reason/comment).
    /// Без повторов, как у всех POST. Тело — с ключами по алфавиту (makeRequest).
    func postDetailed<T: Decodable>(_ path: String, body: [String: Any?] = [:], as type: T.Type) async throws -> T {
        try await perform(makeRequest("POST", path, jsonBody: body), as: type, detailed: true)
    }

    /// А82: GET, отказ которого нужен с HTTP-статусом (APIDetailedError.status):
    /// 403 — у сотрудника нет права (блок не показываем), 404 — старый сервер
    /// без ручки (прячем молча). Статус есть и у 4xx без JSON (ответ веб-сервера).
    /// retries — доп. попытки при сбое сети и 5xx без JSON: экран — 2, как у get();
    /// дашборд и проверка пунктов «Ещё» — 0 (тяжёлый контроль потерь не трижды).
    func getDetailed<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type,
                                   retries: Int = 2) async throws -> T {
        let req = makeRequest("GET", path, query: query)
        let extra = max(0, retries)
        var lastError: Error = APIError.network
        for attempt in 0...extra {
            do {
                return try await perform(req, as: type, detailed: true, statusOnBareError: true)
            } catch let e as APIError where (e.isRetryable || (e.isTimeout && attempt == 0)) && attempt < extra {
                lastError = e
                let delay = pow(2.0, Double(attempt)) * 0.5 + Double.random(in: 0...0.3)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError
    }

    func put<T: Decodable>(_ path: String, body: [String: Any?] = [:], as type: T.Type) async throws -> T {
        try await send(makeRequest("PUT", path, jsonBody: body), as: type)
    }

    func delete<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try await send(makeRequest("DELETE", path), as: type)
    }

    /// А60/П-23.6: POST с ожиданием ответа до 90 с (импорт run). Без повторов —
    /// после обрыва экран сам спрашивает статус импорта.
    func postLong<T: Decodable>(_ path: String, body: [String: Any?] = [:], as type: T.Type) async throws -> T {
        var req = makeRequest("POST", path, jsonBody: body)
        req.timeoutInterval = 90
        return try await perform(req, as: type, using: longSession)
    }

    /// А100 («Помощник Yumurta»): запрос с обычным Bearer, тихим продлением токена
    /// (401 → refresh → один повтор → выход) и 403 → перечитать права, но БЕЗ разбора
    /// кабинетного конверта: у /api/v1/assistant/… мобильный конверт, а из тела
    /// ошибки 502 нужен error.details.chat_id. Возвращает HTTP-статус и тело.
    /// long — ответ модели (10–30 с): ждём до 60 с сессией без ожидания связи.
    /// Без повторов (вопрос не задваиваем).
    func rawRequest(_ method: String, _ path: String, query: [String: String] = [:],
                    body: [String: Any?]? = nil, long: Bool = false) async throws -> (Int, Data) {
        var req = makeRequest(method, path, query: query, jsonBody: body)
        if long { req.timeoutInterval = 60 }
        return try await raw(req, long: long, isRetryAfterRefresh: false)
    }

    private func raw(_ req: URLRequest, long: Bool, isRetryAfterRefresh: Bool) async throws -> (Int, Data) {
        // Запись (вопрос, оценка, передача) доводим до ответа и в фоне — см. BackgroundSave.
        var bgToken: BackgroundSaveToken?
        if (req.httpMethod ?? "GET") != "GET" { bgToken = await BackgroundSave.begin() }
        defer { if let t = bgToken { BackgroundSave.end(t) } }
        let data: Data; let resp: URLResponse
        do {
            (data, resp) = try await (long ? longSession : session).data(for: req)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }
            throw urlError.code == .timedOut ? APIError.timeout : APIError.network
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.network
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            if !isRetryAfterRefresh {
                switch await refresher.refresh(base: API.base) {
                case .ok(let newToken):
                    var retry = req
                    retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    return try await raw(retry, long: long, isRetryAfterRefresh: true)
                case .transient:
                    throw APIError.network      // сбой сети при продлении — не разлогиниваем
                case .invalid:
                    break
                }
            }
            if let handler = onUnauthorized { await MainActor.run { handler() } }
            throw APIError.unauthorized
        }
        if status == 403 {
            Task { @MainActor in Session.shared.onForbidden() }
        }
        return (status, data)
    }

    /// Multipart-загрузка одного файла (фото товара/мастера/категории).
    func upload<T: Decodable>(_ path: String, field: String, filename: String,
                              mime: String, fileData: Data, as type: T.Type) async throws -> T {
        let boundary = "yumurta-" + UUID().uuidString
        var req = try baseRequest("POST", path)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        return try await send(req, as: type)
    }

    /// А66 (техподдержка площадки): JSON-POST с заголовком Idempotency-Key.
    /// Повтор той же отправки с тем же ключом сервер не задваивает, а отвечает
    /// тем же сообщением. Сам запрос здесь не повторяется (как у всех POST).
    func postIdempotent<T: Decodable>(_ path: String, body: [String: Any?],
                                      idempotencyKey: String, as type: T.Type) async throws -> T {
        var req = makeRequest("POST", path, jsonBody: body)
        req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        return try await send(req, as: type)
    }

    /// П-27.14: POST создания записи (товар, акция, промокод, документ склада,
    /// заказ поставщику, услуга, мастер, поставщик) с Idempotency-Key. Ключ один
    /// на одинаковый запрос до ответа сервера: повторное «Создать» после обрыва
    /// не делает дубль. 409 idempotency_in_progress — ждём 2 с и один раз
    /// повторяем с тем же ключом. Старый сервер заголовок не читает — как раньше.
    /// detailed — отказ сервера приходит APIDetailedError (HTTP-статус, код, document_id),
    /// а не APIError.server; текст тот же. По умолчанию — как раньше.
    /// keys — ключи формы (IdempotencyKeys.form()), если ключ держит окно; nil — общие (5 минут).
    func postKeyed<T: Decodable>(_ path: String, body: [String: Any?] = [:], as type: T.Type,
                                 detailed: Bool = false, keys formKeys: IdempotencyKeys? = nil) async throws -> T {
        var req = makeRequest("POST", path, jsonBody: body)
        let clean = body.compactMapValues { $0 }
        let sorted = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
        // Тело — с ключами по алфавиту: сервер сверяет повтор по телу, и то же
        // «Создать» после обрыва должно уйти байт-в-байт тем же (порядок ключей
        // словаря от раза к разу не гарантирован — был бы отказ key_reused).
        if let sorted { req.httpBody = sorted }
        let bodyPrint = sorted.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let fingerprint = path + "\n" + bodyPrint
        let keys = formKeys ?? IdempotencyKeys.shared
        req.setValue(keys.key(for: fingerprint), forHTTPHeaderField: "Idempotency-Key")
        do {
            let res: T
            do {
                res = try await perform(req, as: type, detailed: detailed)
            } catch let e as IdempotencyError where e.code == "idempotency_in_progress" {
                // Первый запрос с этим ключом ещё идёт на сервере (Retry-After: 2).
                try await Task.sleep(nanoseconds: 2_000_000_000)
                res = try await perform(req, as: type, detailed: detailed)
            }
            keys.forget(fingerprint)
            return res
        } catch let e as IdempotencyError {
            // Ключ уже ушёл на другой запрос — следующая попытка пойдёт с новым.
            // unknown_outcome теперь тоже приходит сюда (раньше — APIError.server,
            // и ключ забывался) — забываем, как прежде: с этим ключом сервер так и
            // будет отвечать 409.
            if e.code == "idempotency_key_reused" || e.code == "idempotency_unknown_outcome" { keys.forget(fingerprint) }
            if detailed {
                throw APIDetailedError(status: e.code == "idempotency_key_reused" ? 422 : 409, code: e.code,
                                       message: e.message, fields: [:])
            }
            throw APIError.server(e.message)
        } catch let e as APIDetailedError {
            // Ответ сервера получен (как .server выше) — ключ не нужен. 5xx с текстом —
            // исход неизвестен: ключ оставляем, повтор уйдёт с ним.
            if e.status < 500 { keys.forget(fingerprint) }
            throw e
        } catch let e as APIError {
            // Отказ сервера с текстом (проверка полей) или неразобранный ответ —
            // ответ получен, ключ не нужен. Обрыв/таймаут/5xx — ключ оставляем:
            // повтор того же «Создать» пойдёт с ним, и сервер не сделает дубль.
            switch e {
            case .server, .decoding: keys.forget(fingerprint)
            default: break
            }
            throw e
        }
    }

    /// А78 («Курьеры Yumurta»): POST, где сервер ТРЕБУЕТ ключ повтора в теле
    /// (idempotency_key) — тот же ключ уходит и заголовком. Ключ ведёт экран:
    /// один на неизменённую форму, новый — после окончательного ответа сервера.
    /// Тело с ключами по алфавиту: повтор после обрыва уходит байт-в-байт тем же
    /// (сервер сверяет повтор по телу). 409 idempotency_in_progress — ждём 2 с
    /// и один раз повторяем с тем же ключом. Остальные отказы — как у postIdempotent.
    /// detailedErrors (А80) — отказ сервера приходит как APIDetailedError (код и
    /// поля), а не APIError.server; по умолчанию — как раньше.
    func postBodyKeyed<T: Decodable>(_ path: String, body: [String: Any?],
                                     idempotencyKey: String, detailedErrors: Bool = false,
                                     as type: T.Type) async throws -> T {
        var req = makeRequest("POST", path, jsonBody: body)
        var clean = body.compactMapValues { $0 }
        clean["idempotency_key"] = idempotencyKey
        if let sorted = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys]) {
            req.httpBody = sorted
        }
        req.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        do {
            return try await perform(req, as: type, detailed: detailedErrors)
        } catch let e as IdempotencyError where e.code == "idempotency_in_progress" {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await perform(req, as: type, detailed: detailedErrors)
        }
    }

    /// А66: multipart с текстовыми полями и ОДНИМ файлом + Idempotency-Key
    /// (сообщение в техподдержку с фото или PDF). Отдельно от upload(): там
    /// нет полей формы и ключа повтора. Сессия с долгим ожиданием — PDF до
    /// нескольких мегабайт на медленной сети не укладывался в обычные 60 с.
    func uploadForm<T: Decodable>(_ path: String, fields: [String: String],
                                  fileField: String, filename: String, mime: String, fileData: Data,
                                  idempotencyKey: String?, as type: T.Type) async throws -> T {
        let boundary = "yumurta-" + UUID().uuidString
        var req = try baseRequest("POST", path)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key = idempotencyKey, !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "Idempotency-Key")
        }
        // Кавычки и переводы строк в имени файла ломали бы заголовок части.
        let safeName = filename
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var body = Data()
        for key in fields.keys.sorted() {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(Data((fields[key] ?? "").utf8))
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(safeName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        req.timeoutInterval = 90
        return try await perform(req, as: type, using: longSession)
    }

    /// Диагностика push: сервер шлёт уведомление на все токены этого пользователя
    /// и возвращает ответ Apple по каждому (routes/api_v1.php: /api/v1/push/test).
    func sendPushTest() async throws -> PushDiag {
        var req = try baseRequest("POST", "api/v1/push/test")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw APIError.server("На сервере нет /api/v1/push/test — файлы routes/api_v1.php и core/Push.php ещё не залиты на хостинг.")
        }
        guard status == 200 else { throw APIError.http(status) }
        struct Env: Decodable { let success: Bool; let data: PushDiag? }
        guard let env = try? JSONDecoder().decode(Env.self, from: data),
              env.success, let d = env.data else { throw APIError.decoding }
        return d
    }

    /// Токены живут только в Keychain. Сервер при входе/продлении отдаёт их ещё и
    /// в cookie, а URLSession сохраняет cookie на диск (Cookies.binarycookies) —
    /// вне Keychain и без очистки при выходе. Убираем cookie нашего домена.
    static func clearCookies() {
        guard let url = URL(string: base) else { return }
        let store = HTTPCookieStorage.shared
        for c in store.cookies(for: url) ?? [] { store.deleteCookie(c) }
    }

    /// Выход на сервере с ЯВНО переданным токеном: локальная очистка Keychain
    /// идёт сразу, и запрос не должен зависеть от того, успел ли он прочитать
    /// токен до неё. push_token — чтобы сервер выключил уведомления этого
    /// устройства для вышедшего пользователя.
    func logout(accessToken: String?, pushToken: String?) async {
        guard let url = URL(string: API.base + "/api/v1/auth/logout") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = accessToken, !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        var body: [String: String] = [:]
        if let p = pushToken, !p.isEmpty { body["push_token"] = p }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await session.data(for: req)
        API.clearCookies()
    }

    /// Регистрация push-токена — endpoint формата v1 (routes/api_v1.php: /api/v1/push/register).
    /// `install` — сведения об установке (InstallInfo.pushFields, собирает PushManager); пусто — как раньше.
    func registerPushToken(_ token: String, install: [String: Any] = [:]) async throws {
        var req = try baseRequest("POST", "api/v1/push/register")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // ios_seller, а не ios: у приложения продавца свой apns-topic на сервере.
        // А105: плюс необязательные сведения об установке (AppInstalls::fromPush) — версия,
        // сборка, id установки, модель, ОС; чего нет — ключа нет. Старый сервер их не читает.
        var body = install
        body["token"] = token
        body["platform"] = "ios_seller"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["success"] as? Bool) == true else {
            throw APIError.http(status)
        }
    }

    /// П-28.6: «сессия истекла» — гасим push-токен этого устройства на сервере.
    /// БЕЗ Authorization (токен доступа уже недействителен); ответ сервера всегда
    /// одинаковый, поэтому ничего не разбираем. Старый сервер ответит 404 — не важно.
    func unregisterPushToken(_ token: String) async {
        guard !token.isEmpty, let url = URL(string: API.base + "/api/v1/push/unregister") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])
        // Общая сессия без ожидания связи: без сети запрос сразу кончается, и
        // регистрация при следующем входе (она ждёт этот запрос) не задерживается.
        _ = try? await URLSession.shared.data(for: req)
    }

    /// П-52 (сайт А101): какая версия приложения вышла и ниже какой нужно обновиться.
    /// GET /api/v1/app-version?app=seller&platform=ios — без входа, мобильный конверт.
    /// Любая ошибка (нет сети, 404 старого сервера, 429, не JSON) — nil: молчим.
    /// Общая сессия без ожидания связи и без повторов: проверка фоновая, без сети
    /// она просто ничего не покажет.
    /// А105: `install` — сведения об установке (InstallInfo.versionQuery(canCreate:): version, build,
    /// device_id, device_model, os_version) для статистики версий; с Authorization, если
    /// вошли, — сервер привяжет установку к человеку (ручка без входа: 401 не бывает).
    func appVersion(install: [String: String] = [:]) async -> AppVersionInfo? {
        guard var comps = URLComponents(string: API.base + "/api/v1/app-version") else { return nil }
        var items = [URLQueryItem(name: "app", value: "seller"), URLQueryItem(name: "platform", value: "ios")]
        for k in install.keys.sorted() where !["app", "platform"].contains(k) {
            items.append(URLQueryItem(name: k, value: install[k]))
        }
        comps.queryItems = items
        // «+» URLComponents не кодирует, а PHP читает его как пробел.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = Keychain.get(.accessToken), !t.isEmpty {
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return AppUpdateLogic.parse(data)
    }

    /// Скачивание файла (XLSX/CSV-экспорты) с Bearer во временный файл.
    /// Сервер отдаёт бинарь + Content-Disposition (не JSON-конверт), поэтому
    /// путь отдельный: 401 → один общий refresh → один повтор; ошибка ok=false
    /// (если вместо файла пришёл JSON) — текстом сервера.
    func downloadFile(_ path: String, query: [String: String] = [:],
                      fallbackName: String, isRetryAfterRefresh: Bool = false) async throws -> URL {
        let req = try baseRequest("GET", path, query: query)
        let data: Data; let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }
            throw urlError.code == .timedOut ? APIError.timeout : APIError.network
        } catch {
            throw APIError.network
        }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 {
            if !isRetryAfterRefresh {
                switch await refresher.refresh(base: API.base) {
                case .ok:
                    return try await downloadFile(path, query: query, fallbackName: fallbackName, isRetryAfterRefresh: true)
                case .transient:
                    throw APIError.network      // сбой сети при продлении — не разлогиниваем
                case .invalid:
                    break
                }
            }
            if let handler = onUnauthorized { await MainActor.run { handler() } }
            throw APIError.unauthorized
        }
        let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if status >= 400 || contentType.contains("application/json") {
            // Пришёл JSON-конверт с ошибкой вместо файла — показываем текст сервера.
            if let env = try? decoder.decode(SellerEnvelope<EmptyData>.self, from: data), !env.ok {
                throw APIError.server(env.hasErrorText || status < 400 ? env.errorText : API.statusText(status))
            }
            if status >= 400 { throw status >= 500 ? APIError.http(status) : APIError.server(API.statusText(status)) }
        }
        // Имя файла: из Content-Disposition (filename="...") или запасное.
        var filename = fallbackName
        if let disposition = http?.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: "filename=\"") {
            let tail = disposition[range.upperBound...]
            if let end = tail.firstIndex(of: "\"") {
                let n = String(tail[..<end])
                if !n.isEmpty { filename = n }
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent(filename)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url) } catch { throw APIError.decoding }
        return url
    }

    // ── Внутренности ─────────────────────────────────────────────────────────

    private func baseRequest(_ method: String, _ path: String, query: [String: String] = [:]) throws -> URLRequest {
        guard var comps = URLComponents(string: API.base + "/" + path) else { throw APIError.network }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents оставляет «+» как есть, а PHP читает его как пробел:
            // поиск «+7938…» или артикула с плюсом уходил на сервер с пробелом.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = comps.url else { throw APIError.network }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token = Keychain.get(.accessToken) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    private func makeRequest(_ method: String, _ path: String,
                             query: [String: String] = [:], jsonBody: [String: Any?]? = nil) -> URLRequest {
        var req = (try? baseRequest(method, path, query: query)) ?? URLRequest(url: URL(string: API.base)!)
        if let body = jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let clean = body.compactMapValues { $0 }
            // Ключи по алфавиту — тело повтора совпадает с первой попыткой (ключи идемпотентности).
            req.httpBody = try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
        }
        return req
    }

    /// Повтор только для идемпотентных GET — POST/PUT/DELETE не задваиваем.
    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let idempotent = (req.httpMethod ?? "GET") == "GET"
        let attempts = idempotent ? maxRetries + 1 : 1
        var lastError: Error = APIError.network
        for attempt in 0..<attempts {
            do {
                return try await perform(req, as: type)
            } catch let e as APIError where (e.isRetryable || (e.isTimeout && attempt == 0)) && attempt < attempts - 1 {
                lastError = e
                // Экспоненциальный бэкофф с джиттером: 0.5s, 1.5s… — только для GET.
                let delay = pow(2.0, Double(attempt)) * 0.5 + Double.random(in: 0...0.3)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
        }
        throw lastError
    }

    /// Один сетевой проход: 401 → single-flight refresh (actor) → один повтор → logout.
    /// Разбирает конверт seller-API {ok,data,error,errors}; текст ошибки — из env.errorText.
    private func perform<T: Decodable>(_ req: URLRequest, as type: T.Type,
                                       isRetryAfterRefresh: Bool = false,
                                       using customSession: URLSession? = nil,
                                       detailed: Bool = false,
                                       statusOnBareError: Bool = false) async throws -> T {
        // Запись (не GET) доводим до ответа и в фоне — см. BackgroundSave.
        var bgToken: BackgroundSaveToken?
        if (req.httpMethod ?? "GET") != "GET" { bgToken = await BackgroundSave.begin() }
        defer { if let t = bgToken { BackgroundSave.end(t) } }
        let data: Data; let resp: URLResponse
        do {
            (data, resp) = try await (customSession ?? session).data(for: req)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }   // отмена (дебаунс) — не повторяем
            throw urlError.code == .timedOut ? APIError.timeout : APIError.network
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.network
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // Вход по паролю: 401 значит «неверный логин или пароль», а не истёкшая
        // сессия. Раньше шёл refresh и выход, и на экране входа писало
        // «Сессия истекла, войдите снова» вместо текста сервера.
        if status == 401, req.url?.path.hasSuffix("/login") == true {
            let env = try? decoder.decode(SellerEnvelope<EmptyData>.self, from: data)
            if let env, env.hasErrorText { throw APIError.server(env.errorText) }
            throw APIError.server("Неверный логин или пароль")
        }
        if status == 401 {
            // Тихое продление access-токена: общий refresh через actor → повтор с новым Bearer.
            if !isRetryAfterRefresh,
               !(req.url?.path.hasSuffix("/auth/refresh") ?? false) {
                switch await refresher.refresh(base: API.base) {
                case .ok(let newToken):
                    var retry = req
                    retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    return try await perform(retry, as: type, isRetryAfterRefresh: true, using: customSession,
                                             detailed: detailed, statusOnBareError: statusOnBareError)
                case .transient:
                    // Сервер/сеть не ответили на продление: сессия, скорее всего, жива —
                    // не выкидываем продавца на экран входа из-за мигнувшего интернета.
                    throw APIError.network
                case .invalid:
                    break
                }
            }
            if let handler = onUnauthorized { await MainActor.run { handler() } }
            throw APIError.unauthorized
        }
        // Паритет с Android: 403 у сотрудника — повод перечитать права (/me),
        // роль могли изменить, пока приложение открыто. Сам ответ не меняем.
        if status == 403 {
            Task { @MainActor in Session.shared.onForbidden() }
        }

        do {
            let env = try decoder.decode(SellerEnvelope<T>.self, from: data)
            // ok=false — прикладная ошибка: показываем текст сервера (в т.ч. валидацию).
            // Без текста от сервера — понятная подпись по коду (403, 413, 429…).
            if env.ok == false || status >= 400 {
                // П-27.14: отказ по ключу повтора — отдельной ошибкой, чтобы
                // postKeyed мог подождать и повторить. Только у запросов с ключом.
                // unknown_outcome (409) — тоже по коду: чат поддержки по нему
                // бросает ключ и перечитывает переписку (как Android).
                if let code = env.code,
                   code == "idempotency_in_progress" || code == "idempotency_key_reused"
                    || code == "idempotency_unknown_outcome",
                   req.value(forHTTPHeaderField: "Idempotency-Key") != nil {
                    throw IdempotencyError(code: code, message: env.hasErrorText ? env.errorText : API.statusText(status))
                }
                let text = env.hasErrorText || status < 400
                    ? API.withRetryHint(env.errorText, status: status) : API.statusText(status)
                // А80: вызов курьера — с кодом и полями (тот же текст).
                if detailed {
                    throw APIDetailedError(status: status, code: env.code, message: text, fields: env.errors ?? [:],
                                           serverError: env.error, documentId: API.errorsInt(data, "document_id"))
                }
                throw APIError.server(text)
            }
            guard let payload = env.data else {
                // Успех без data — допустим, если T принимает пустую нагрузку (EmptyData).
                if let empty = EmptyData() as? T { return empty }
                throw APIError.decoding
            }
            return payload
        } catch let e as APIError {
            throw e
        } catch let e as IdempotencyError {
            throw e
        } catch let e as APIDetailedError {
            // А81: отказ с кодом и полями (брошен выше, в этом же do) — наружу как есть.
            // Без этой ветки он попадал в общий catch ниже и превращался в «Данные уже
            // изменились (409)» без текста сервера — вызов курьера (price_changed, поля 422)
            // и жалоба (complaint_exists) не видели ни кода, ни полей.
            throw e
        } catch {
            if status >= 500 { throw APIError.http(status) }
            // А82 (getDetailed): 4xx без JSON — тоже со статусом, чтобы «нет ручки»
            // (404) и «нет права» (403) не путались с 429/413/400.
            if statusOnBareError && status >= 400 {
                throw APIDetailedError(status: status, code: nil, message: API.statusText(status), fields: [:])
            }
            if status >= 400 { throw APIError.server(API.statusText(status)) }
            throw APIError.decoding
        }
    }
}


// ── Диагностика push (ответ /api/v1/push/test) ──────────────────────────────
struct PushDiag: Decodable {
    struct TokenRow: Decodable {
        let platform: String
        let active: Bool
        let token: String
    }
    struct ReportRow: Decodable {
        let platform: String
        let token: String
        let ok: Bool
        let detail: String
    }
    let apnsConfigured: Bool
    let topicSeller: String
    let topicClient: String
    let tokens: [TokenRow]
    let sent: Int
    let report: [ReportRow]

    enum CodingKeys: String, CodingKey {
        case apnsConfigured = "apns_configured"
        case topicSeller    = "topic_seller"
        case topicClient    = "topic_client"
        case tokens, sent, report
    }
}
