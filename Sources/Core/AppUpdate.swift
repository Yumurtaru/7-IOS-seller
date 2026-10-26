import Foundation

// ============================================================================
//  П-52 (сайт А101): «Вышла новая версия — обновите».
//  GET /api/v1/app-version?app=seller&platform=ios — что администратор записал
//  в «Настройки площадки» → «Версии приложений». Пустые строки и нули — данных
//  нет, приложение молчит. Здесь только чистая логика (без UIKit и SwiftUI),
//  чтобы её можно было проверить отдельно; экран и окно — Features/Root/AppUpdateViews.swift.
// ============================================================================

struct AppVersionInfo: Equatable {
    var latestVersion = ""
    var latestBuild = 0
    var minVersion = ""
    var minBuild = 0
    var message = ""
    var storeUrl = ""
}

/// Что показать: ничего, мягкое окно «Вышла новая версия» или экран «Нужно обновить».
enum UpdateDecision: Equatable { case none, soft, force }

enum AppUpdateLogic {
    /// Спрашиваем сервер не чаще раза в 6 часов.
    static let checkInterval: TimeInterval = 6 * 60 * 60
    /// «Позже» и «Обновить» в мягком окне — не напоминаем об этой версии сутки.
    static let snoozeInterval: TimeInterval = 24 * 60 * 60

    /// Сравнение версий по точкам — так же, как appVersionCompare() на сервере:
    /// всё с первого символа, который не цифра и не точка, отбрасывается
    /// («1.3-beta» → «1.3»), части — целые (пустая → 0), недостающие = 0.
    /// 1.0.10 > 1.0.9, 1.3 = 1.3.0. Результат: -1, 0, 1.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    private static func parts(_ v: String) -> [Int64] {
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        var clean = ""
        for ch in t {
            guard ch == "." || ("0"..."9").contains(ch) else { break }
            clean.append(ch)
        }
        // Очень длинное число — как «не число» (0), а не падение.
        return clean.split(separator: ".", omittingEmptySubsequences: false).map { Int64($0) ?? 0 }
    }

    /// Решение по ответу сервера. iOS сравнивает только по версии
    /// (CFBundleShortVersionString): номера сборок — для Android. Без ссылки на
    /// магазин ничего не показываем: кнопке «Обновить» некуда вести.
    static func decide(_ info: AppVersionInfo, version: String) -> UpdateDecision {
        guard !info.storeUrl.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        // Версию приложения не прочитали — не с чем сравнивать: «""» оказалась бы ниже
        // любой и заперла бы приложение экраном «Нужно обновить». Молчим.
        guard !version.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        if !info.minVersion.isEmpty && compare(version, info.minVersion) < 0 { return .force }
        if !info.latestVersion.isEmpty && compare(version, info.latestVersion) < 0 { return .soft }
        return .none
    }

    /// Ключ мягкого окна: «Позже» откладывает именно эту версию и сборку.
    static func softKey(_ info: AppVersionInfo) -> String { info.latestVersion + "#" + String(info.latestBuild) }

    /// Отложено ли мягкое окно для этой версии. Часы перевели назад (now < snoozedAt) —
    /// не отложено: иначе окно могло бы не появиться очень долго.
    static func isSnoozed(key: String, snoozedKey: String?, snoozedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard let sk = snoozedKey, sk == key, snoozedAt > 0, now >= snoozedAt else { return false }
        return now - snoozedAt < snoozeInterval
    }

    /// Пора ли спрашивать сервер. Обязательное обновление, если оно уже было,
    /// проверяем каждый раз — после обновления экран должен исчезнуть.
    static func shouldCheck(lastOkAt: TimeInterval, now: TimeInterval, forcePending: Bool) -> Bool {
        forcePending || lastOkAt <= 0 || now < lastOkAt || now - lastOkAt >= checkInterval
    }

    /// Текст экрана «Нужно обновить приложение».
    static func forceText(_ info: AppVersionInfo) -> String {
        let m = info.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "Эта версия больше не поддерживается. Обновите приложение, чтобы продолжить." : m
    }

    /// Мелкая строка под кнопкой: «Установлена версия X, нужна Y или новее».
    static func forceVersionLine(_ info: AppVersionInfo, installed: String) -> String {
        let need = info.minVersion.trimmingCharacters(in: .whitespaces)
        return "Установлена версия \(installed), нужна \(need.isEmpty ? "новая" : need) или новее"
    }

    /// Заголовок мягкого окна.
    static func softTitle(_ info: AppVersionInfo) -> String {
        let v = info.latestVersion.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "Вышла новая версия" : "Вышла новая версия \(v)"
    }

    /// Текст мягкого окна.
    static func softText(_ info: AppVersionInfo) -> String {
        let m = info.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? "Обновите приложение, чтобы пользоваться новыми возможностями." : m
    }

    /// Разбор ответа: мобильный конверт {success, data:{…}} или голый объект.
    /// success:false, data не объект, не JSON — nil (ничего не показываем).
    /// Числа сборок бывают и строкой («4»), строки — числом (1.3): принимаем оба.
    static func parse(_ data: Data) -> AppVersionInfo? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let root = any as? [String: Any] else { return nil }
        if let ok = root["success"] as? Bool, !ok { return nil }
        let d: [String: Any]
        if root.keys.contains("data") {
            guard let inner = root["data"] as? [String: Any] else { return nil }
            d = inner
        } else {
            d = root
        }
        return AppVersionInfo(latestVersion: str(d["latest_version"]), latestBuild: int(d["latest_build"]),
                              minVersion: str(d["min_version"]), minBuild: int(d["min_build"]),
                              message: str(d["message"]), storeUrl: str(d["store_url"]))
    }

    private static func str(_ v: Any?) -> String {
        if let s = v as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    private static func int(_ v: Any?) -> Int {
        var d: Double?
        if let s = v as? String { d = Double(s.trimmingCharacters(in: .whitespaces)) }
        else if let n = v as? NSNumber { d = n.doubleValue }
        guard let x = d, x.isFinite, x > 0 else { return 0 }
        return x >= Double(Int32.max) ? Int(Int32.max) : Int(x)
    }
}
