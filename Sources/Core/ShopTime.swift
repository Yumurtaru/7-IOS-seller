import Foundation

/// Часовой пояс заведения (П-68, ответ сайта 09.11).
///
/// GET /api/seller/me и /api/seller/settings отдают shop.timezone — IANA-строку пояса города
/// заведения ("Asia/Yekaterinburg"); нет города — "Europe/Moscow". Время записи к услугам
/// (дата + time_start) — стенные часы этого пояса. Нет поля (старый сервер) или пояс телефону
/// неизвестен — Москва, как раньше. Пояс активного заведения держим в памяти (`current`);
/// при смене заведения и выходе — сброс на Москву (`reset`, зовёт Session.resetPause()).
/// Паритет с Android (core/ShopTime.kt).
enum ShopTime {
    static let defaultId = "Europe/Moscow"
    static let moscow: TimeZone = TimeZone(identifier: defaultId) ?? TimeZone(secondsFromGMT: 3 * 3600)!

    /// Пояс активного заведения.
    private(set) static var current: TimeZone = moscow

    /// Запомнить пояс из ответа сервера; nil/пусто (поля нет) — не трогаем, что было.
    static func set(_ id: String?) {
        guard let key = id?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        current = zone(key)
    }

    /// Смена заведения / выход — снова Москва.
    static func reset() { current = moscow }

    /// Пояс по строке сервера; пусто или неизвестный id — Москва.
    static func zone(_ id: String?) -> TimeZone {
        guard let key = id?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let tz = TimeZone(identifier: key) else { return moscow }
        return tz
    }

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = current
        return c
    }

    /// "yyyy-MM-dd" момента по часам заведения.
    static func ymd(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// «Сегодня» заведения как Date для экранов, где день хранится началом суток по часам
    /// устройства (DatePicker, DateFmt.ymd): календарный день тот же, что сейчас у заведения.
    static func todayDate() -> Date {
        let c = calendar.dateComponents([.year, .month, .day], from: Date())
        return Calendar.current.date(from: c) ?? Calendar.current.startOfDay(for: Date())
    }

    /// Стенное время заведения «yyyy-MM-dd HH:mm[:ss]» → момент; не разобралось — nil.
    static func wallDate(_ s: String) -> Date? {
        let t = s.count == 16 ? s + ":00" : s
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: t)
    }
}
