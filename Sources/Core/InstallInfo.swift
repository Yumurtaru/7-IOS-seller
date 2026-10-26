import Foundation

/// Волна А105: сведения об установке для статистики «у кого какое приложение и версия»
/// (сайт: core/AppInstalls.php). Уходят необязательными полями в POST api/v1/push/register
/// (app_version, app_build, device_id, device_model, os_version — PushManager → API.registerPushToken) и
/// параметрами GET api/v1/app-version (version, build, device_id, device_model, os_version —
/// AppUpdateCenter → API.appVersion). Старый сервер лишнее игнорирует; чего не получить — не шлём.
///
/// device_id — UUID, созданный один раз (не IDFA, не identifierForVendor). Хранится как номер
/// установки у курьера (DeviceId): файлом в Application Support с пометкой «не в резервную
/// копию» (isExcludedFromBackup) — не в UserDefaults: они уходят в копию iCloud и перенос на
/// новый телефон, и два телефона получили бы один id (сервер склеил бы их в одну установку).
/// Не в Keychain: он переживает удаление приложения. Выход из аккаунта id не трогает.
/// Ограничения — как на сервере (AppInstalls::fields): device_id до 64 знаков [0-9A-Za-z_-:.],
/// device_model до 80, os_version до 40, версия до 20.
///
/// До первой разблокировки телефона (запуск в фоне тихим push) файл закрыт: прочитали бы
/// «нет id» и создали новый. Поэтому создавать новый id можно, только если вызывающий
/// (на главном потоке) проверил UIApplication.isProtectedDataAvailable — `canCreate`.
/// Иначе — только уже сохранённый id, а нет его — поле не шлём.
enum InstallInfo {
    /// Имя файла в Application Support.
    static let fileName = "seller_install_id"
    private static let lock = NSLock()
    private static var cached: String?

    /// Файл id: Application Support/seller_install_id.
    static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    /// Стабильный id установки (UUID, 36 знаков). Новый — только при `canCreate` и только если
    /// его удалось записать (иначе каждый запуск был бы «новой установкой»): тогда nil.
    static func deviceId(canCreate: Bool, file: URL? = InstallInfo.fileURL) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        guard let f = file else { return nil }
        if let d = try? Data(contentsOf: f) {
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidId(s) { cached = s; return s }
        }
        guard canCreate else { return nil }
        let s = UUID().uuidString
        guard save(s, to: f) else { return nil }
        cached = s
        return s
    }

    /// Записать id в файл и пометить «не в резервную копию». true — записано.
    private static func save(_ id: String, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(id.utf8).write(to: file, options: .atomic)
        } catch { return false }
        #if os(iOS) || os(macOS)
        var u = file
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        #endif
        return true
    }

    static func isValidId(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        return s.unicodeScalars.allSatisfy { c in
            ("0"..."9").contains(c) || ("a"..."z").contains(c) || ("A"..."Z").contains(c)
                || c == "_" || c == "-" || c == ":" || c == "."
        }
    }

    /// Идентификатор модели («iPhone16,2») из utsname.machine; в симуляторе — модель,
    /// которую он изображает. Человеко-читаемое имя не выдумываем. До 80 знаков.
    static var deviceModel: String? {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !sim.isEmpty {
            return String(sim.prefix(80))
        }
        var u = utsname()
        guard uname(&u) == 0 else { return nil }
        // Размер — заранее: внутри withUnsafePointer(to: &u.machine) читать u нельзя (эксклюзивный доступ).
        let size = MemoryLayout.size(ofValue: u.machine)
        let machine = withUnsafePointer(to: &u.machine) { p in
            p.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
        let s = machine.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(80))
    }

    /// «iOS 18.1» (patch — только если не ноль: «iOS 17.4.1»). До 40 знаков.
    static var osVersion: String? {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        guard v.majorVersion > 0 else { return nil }
        var s = "iOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { s += ".\(v.patchVersion)" }
        return String(s.prefix(40))
    }

    /// CFBundleShortVersionString («1.0.7»), до 20 знаков.
    static var appVersion: String? {
        let s = ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(20))
    }

    /// CFBundleVersion числом; не число — nil.
    static var appBuild: Int? {
        let s = ((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let b = Int(s), b > 0 else { return nil }
        return b
    }

    /// Поля тела POST api/v1/push/register (ключи — как в AppInstalls::fromPush).
    /// `canCreate` — UIApplication.isProtectedDataAvailable (см. deviceId).
    static func pushFields(canCreate: Bool) -> [String: Any] {
        var m: [String: Any] = [:]
        if let v = appVersion { m["app_version"] = v }
        if let b = appBuild { m["app_build"] = b }
        if let d = deviceId(canCreate: canCreate) { m["device_id"] = d }
        if let x = deviceModel { m["device_model"] = x }
        if let o = osVersion { m["os_version"] = o }
        return m
    }

    /// Параметры GET api/v1/app-version (кроме app и platform; ключи — AppInstalls::fromVersionCheck).
    /// `canCreate` — UIApplication.isProtectedDataAvailable (см. deviceId).
    static func versionQuery(canCreate: Bool) -> [String: String] {
        var q: [String: String] = [:]
        if let v = appVersion { q["version"] = v }
        if let b = appBuild { q["build"] = String(b) }
        if let d = deviceId(canCreate: canCreate) { q["device_id"] = d }
        if let m = deviceModel { q["device_model"] = m }
        if let o = osVersion { q["os_version"] = o }
        return q
    }
}
