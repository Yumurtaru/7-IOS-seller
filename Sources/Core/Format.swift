import Foundation
import SwiftUI

// ── Деньги: единый форматтер ₽ (пробел-разделитель тысяч, без хвостовых нулей) ──
enum Money {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = "\u{202F}"   // узкий неразрывный пробел
        f.decimalSeparator = ","
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    static func rub(_ v: Decimal?) -> String {
        let value = v ?? 0
        let s = formatter.string(from: value as NSDecimalNumber) ?? "0"
        return s + " ₽"
    }

    /// Сумма со знаком для истории кошелька: +1 000 ₽ / −250 ₽.
    static func signed(_ v: Decimal?) -> String {
        let value = v ?? 0
        return (value >= 0 ? "+" : "") + rub(value)
    }

    /// Строгий разбор числа из поля ввода. Decimal(string:) читает только
    /// начало строки: «1 500» давало 1, «12,5» на чужой раскладке — 12, а
    /// мусор молча превращался в 0. Пробелы (в т.ч. неразрывные) убираем,
    /// запятую считаем точкой, всё остальное — ошибка (nil).
    static func strict(_ s: String, maxFraction: Int = 2) -> Decimal? {
        let t = s.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        // Проверка без регулярного выражения: strict() зовётся из body форм по
        // нескольку раз на строку (правка состава, закупка, приёмка), и сборка
        // regex на каждом нажатии клавиши тормозила ввод. Правило то же:
        // цифры, затем необязательно точка и от 1 до maxFraction цифр.
        func digits(_ part: Substring) -> Bool {
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
        }
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard !t.isEmpty, parts.count <= 2, digits(parts[0]) else { return nil }
        if parts.count == 2 {
            guard digits(parts[1]), parts[1].count <= maxFraction else { return nil }
        }
        return Decimal(string: t)
    }
}

// ── Даты сервера: "Y-m-d H:i:s" и "Y-m-d" ────────────────────────────────────
enum DateFmt {
    private static let serverDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")   // время сервера — МСК
        return f
    }()
    private static let serverDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        return f
    }()
    /// Дата БЕЗ времени — это календарный день, а не момент: читаем и пишем её
    /// в часовом поясе устройства. Иначе «2026-07-02» в Калининграде показывалось
    /// как 1 июля, а дата из DatePicker в Новосибирске уходила на сервер днём раньше.
    private static let calendarDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s = s, !s.isEmpty else { return nil }
        return serverDateTime.date(from: s) ?? calendarDate.date(from: s)
    }

    // Форматтеры вывода создаются один раз: раньше — новый DateFormatter на
    // каждую строку списка при каждой перерисовке (заметно при прокрутке).
    private static func outFormatter(_ locale: String, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.timeZone = TimeZone.autoupdatingCurrent   // как раньше: пояс устройства
        f.dateFormat = format
        return f
    }
    private static let shortOut = outFormatter("ru_RU", "d MMM, HH:mm")
    private static let dayOut = outFormatter("ru_RU", "d MMMM")
    // Дата другого года — с годом: срок годности «до 2 июля» в 2027-м и заказ
    // прошлого декабря без года читались как даты этого года.
    private static let shortYearOut = outFormatter("ru_RU", "d MMM yyyy, HH:mm")
    private static let dayYearOut = outFormatter("ru_RU", "d MMMM yyyy")
    private static let timeOut = outFormatter("en_US_POSIX", "HH:mm")   // всегда 24 часа, без «AM/PM»

    private static func isThisYear(_ date: Date) -> Bool {
        let cal = Calendar.current
        return cal.component(.year, from: date) == cal.component(.year, from: Date())
    }

    /// "2 июл, 14:05" в локали устройства; другой год — "2 июл 2025, 14:05".
    static func short(_ s: String?) -> String {
        guard let date = parse(s) else { return s ?? "" }
        return (isThisYear(date) ? shortOut : shortYearOut).string(from: date)
    }

    /// "2 июля" для дат без времени; другой год — "2 июля 2027".
    static func day(_ s: String?) -> String {
        guard let date = parse(s) else { return s ?? "" }
        return (isThisYear(date) ? dayOut : dayYearOut).string(from: date)
    }

    /// "28 декабря" всегда без года — для подписей оси графика (14 дней через
    /// Новый год с годом не помещались бы в узкие подписи).
    static func dayMonth(_ s: String?) -> String {
        guard let date = parse(s) else { return s ?? "" }
        return dayOut.string(from: date)
    }

    static func time(_ s: String?) -> String {
        guard let date = parse(s) else {
            // time_start слота приходит как "10:00:00" — обрезаем секунды
            if let s = s, s.count >= 5 { return String(s.prefix(5)) }
            return s ?? ""
        }
        return timeOut.string(from: date)
    }

    /// "yyyy-MM-dd" календарного дня устройства (DatePicker, неделя слотов, срок годности).
    static func ymd(_ date: Date) -> String { calendarDate.string(from: date) }
    /// "yyyy-MM-dd" по Москве — для фильтров по времени сервера (created_at в МСК),
    /// например «сегодня» в продажах кассы; так же считает приложение на Android.
    static func ymdMoscow(_ date: Date) -> String { serverDate.string(from: date) }
}

// ── Статусы заказов: подписи, цвета, машина переходов (зеркало routes/seller.php) ──
enum OrderStatuses {
    static let all = ["new", "accepted", "preparing", "ready", "in_delivery", "done", "cancelled"]

    /// Тип организации: shop | cafe | service. Коды статусов у всех одинаковые,
    /// а называются они по-разному: кафе готовит, магазин собирает, салон
    /// начинает работу. Кнопка «Готовить» в барбершопе выглядела ошибкой.
    /// Значение проставляет Session при разборе /api/seller/me — здесь простая
    /// статическая переменная, потому что Session изолирован @MainActor,
    /// а эти функции зовутся из разных мест.
    static var shopType: String = "shop"

    /// Допустимые переходы — точная копия $allowed на сервере. Сервер валидирует,
    /// клиент лишь не показывает лишних кнопок.
    static let transitions: [String: [String]] = [
        "new":         ["accepted", "cancelled"],
        "accepted":    ["preparing", "cancelled"],
        "preparing":   ["ready", "cancelled"],
        "ready":       ["in_delivery", "done"],
        "in_delivery": ["done"],
    ]

    /// Отмена с причиной (/cancel) запрещена на done/cancelled/in_delivery — как на сервере.
    /// П-25: статусов ровно 7 — незнакомый код (новый сервер) отменять не даём:
    /// раньше «всё, кроме done/cancelled/in_delivery» включало и неизвестные.
    static func canCancel(_ status: String?) -> Bool {
        guard let s = status else { return false }
        return ["new", "accepted", "preparing", "ready"].contains(s)
    }

    static func next(_ status: String?) -> [String] {
        (transitions[status ?? ""] ?? []).filter { $0 != "cancelled" }   // отмена — отдельной кнопкой
    }

    /// Как называется состояние заказа.
    static func label(_ s: String?) -> String {
        // А64: у жилья свои подписи (как status_title сервера); бронь идёт
        // new → accepted → done, шагов доставки у неё нет.
        if shopType == "lodging", let l = lodgingLabel(s) { return l }
        switch s {
        case "new": return "Новый"
        case "accepted": return "Принят"
        case "preparing":
            switch shopType {
            case "cafe":    return "Готовится"
            case "service": return "В работе"
            default:        return "Собирается"
            }
        case "ready":
            switch shopType {
            case "cafe":    return "Готов"
            case "service": return "Выполнена"
            default:        return "Собран"
            }
        case "in_delivery": return "В пути"
        case "done": return "Выполнен"
        case "cancelled": return "Отменён"
        default: return s ?? "—"
        }
    }

    /// А64: подписи статусов заказа-брони жилья — те же, что status_title сервера.
    static func lodgingLabel(_ s: String?) -> String? {
        switch s {
        case "new": return "Бронь создана"
        case "accepted": return "Подтверждена"
        case "done": return "Завершена"
        case "cancelled": return "Отменена"
        default: return nil
        }
    }

    /// Подпись кнопки, которая переводит заказ в это состояние.
    static func actionLabel(_ s: String) -> String {
        switch s {
        case "accepted": return "Принять"
        case "preparing":
            switch shopType {
            case "cafe":    return "Готовить"
            case "service": return "Начать"
            default:        return "Собирать"
            }
        case "ready":
            switch shopType {
            case "cafe":    return "Готов"
            case "service": return "Выполнена"
            default:        return "Собран"
            }
        case "in_delivery": return "Передать в доставку"
        // Паритет с Android: кнопка — глагол. «Выполнен» у услуг шло сразу после
        // кнопки «Выполнена» (ready) — две почти одинаковые кнопки подряд.
        case "done": return "Завершить"
        default: return label(s)
        }
    }

    /// Подпись фильтра в списке заказов (множественное число).
    static func filterLabel(_ s: String) -> String {
        switch s {
        case "preparing":
            switch shopType {
            case "cafe":    return "Готовятся"
            case "service": return "В работе"
            default:        return "Собираются"
            }
        case "ready":
            switch shopType {
            case "cafe":    return "Готовы"
            case "service": return "Выполнены"
            default:        return "Собраны"
            }
        default: return label(s)
        }
    }

    static func color(_ s: String?) -> Color {
        switch s {
        case "new": return Brand.accent
        case "accepted": return Brand.amber
        case "preparing": return .orange
        case "ready": return Brand.green
        case "in_delivery": return .blue
        case "done": return Brand.muted
        case "cancelled": return Brand.red
        default: return Brand.muted
        }
    }
}

enum PaymentLabels {
    static func type(_ s: String?) -> String {
        switch s {
        case "cash": return "Наличные"
        case "card_courier": return "Карта курьеру"
        case "sbp": return "СБП"
        case "online_card": return "Картой онлайн"
        case "card_online": return "Картой онлайн"
        // Заказы кассы/киоска (оплата на станции: cash / card / sbp / mixed) —
        // в списке и карточке заказа стояло голое «card» / «mixed».
        case "card": return "Карта"
        case "mixed": return "Смешанная"
        default: return s ?? "—"
        }
    }
    static func status(_ s: String?) -> String {
        switch s {
        case "paid": return "Оплачен"
        case "pending": return "Ожидает оплаты"
        case "refunded": return "Возврат"
        // К-18: заказ кафе, наличные за который везёт курьер.
        case "awaiting_courier_cash": return "Наличные у курьера"
        default: return s ?? ""
        }
    }
    static func delivery(_ s: String?) -> String {
        switch s {
        case "delivery": return "Доставка"
        case "pickup": return "Самовывоз"
        // Заказ в зале (станция кафе, киоск): раньше показывалось «dine_in».
        case "dine_in": return "В зале"
        default: return s ?? "—"
        }
    }
}

enum WalletLabels {
    static func type(_ s: String?) -> String {
        switch s {
        case "topup": return "Пополнение"
        case "commission": return "Комиссия"
        case "service_fee_received": return "Сервисный сбор"
        case "service_fee_shop_pays": return "Сервисный сбор (магазин)"
        case "subscription": return "Тариф / абонплата"
        case "promo": return "Продвижение"
        default: return s ?? "Операция"
        }
    }
    static func method(_ s: String?) -> String {
        switch s {
        case "card_online": return "Картой онлайн"
        case "sbp": return "СБП"
        case "bank_transfer": return "Банковский перевод"
        default: return s ?? "—"
        }
    }
}

enum ReturnLabels {
    static func status(_ s: String?) -> String {
        switch s {
        case "pending": return "Ожидает"
        case "approved": return "Одобрен"
        case "rejected": return "Отклонён"
        case "refunded": return "Возвращён"
        // closed = деньги покупателю фактически выплачены (продавец подтвердил
        // выплату или они отданы из ящика на кассе). «Закрыт» об этом молчал.
        case "closed": return "Деньги выплачены"
        default: return s ?? "—"
        }
    }
    /// Причина возврата (reason_code из белого списка сервера). Раньше в карточке
    /// продавец видел «changed_mind» — как на Android, подписываем по-русски.
    static func reason(_ s: String?) -> String {
        switch s {
        case "wrong_item": return "Привезли не то"
        case "bad_quality": return "Плохое качество"
        case "not_delivered": return "Не доставили"
        case "changed_mind": return "Передумал"
        case "other": return "Другое"
        default: return s ?? "—"
        }
    }
    static func color(_ s: String?) -> Color {
        switch s {
        case "pending": return Brand.amber
        case "approved", "refunded", "closed": return Brand.green
        case "rejected": return Brand.red
        default: return Brand.muted
        }
    }
}

/// Число со словом в нужной форме: RuPlural.count(5, "день", "дня", "дней") → «5 дней».
/// Раньше счётчики писались с одной формой: «истекает через 1 дн.», «из 21 позиций».
enum RuPlural {
    static func word(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n100 = abs(n) % 100, n10 = abs(n) % 10
        if (11...14).contains(n100) { return many }
        if n10 == 1 { return one }
        if (2...4).contains(n10) { return few }
        return many
    }

    static func count(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(n) " + word(n, one, few, many)
    }
}

/// Непустые строки через разделитель: `joinedNonEmpty([a, b], separator: " · ")`.
/// Отдельная функция вместо цепочки `[a, b].compactMap { $0 }.filter { … }`:
/// на Xcode 26 такие цепочки упирались в лимит проверки типов и роняли сборку
/// («unable to type-check this expression in reasonable time», сборка 74).
func joinedNonEmpty(_ parts: [String?], separator: String) -> String {
    var out: [String] = []
    for p in parts {
        guard let s = p, !s.isEmpty else { continue }
        out.append(s)
    }
    return out.joined(separator: separator)
}

// ── Телефон в поле ввода (волна А107) ──
/// Как маска телефона на сайте (auth.js, org-auth.js, checkout.js) и Android (core/Format.kt
/// fixPhoneInput). Человек начинает номер с «+7», а дальше по привычке набирает 8 или 7:
/// «+7 8928 000-00-00», «+78928…», «+7 7928…». Выходит 12 цифр — сервер (normalizePhone,
/// core/helpers.php) такой номер не понимает: «Неверный логин или пароль». У мобильного номера
/// (дальше 9) лишнюю цифру убираем прямо в поле. Всё прочее не трогаем: почту (есть буква или @),
/// «8928…», «7928…», «+7928…», «928…», пробелы, скобки, дефисы — сервер приводит их сам.
enum PhoneInput {
    static func fix(_ s: String) -> String {
        if s.contains(where: { $0.isLetter || $0 == "@" }) { return s }
        let d = Array(s.filter { $0.isASCII && $0.isNumber })
        guard d.count == 12, d[0] == "7", d[1] == "7" || d[1] == "8", d[2] == "9" else { return s }
        var chars = Array(s)
        var seen = 0
        var idx = -1
        for (i, c) in chars.enumerated() where c.isASCII && c.isNumber {
            seen += 1
            if seen == 2 { idx = i; break }
        }
        guard idx >= 0 else { return s }
        chars.remove(at: idx)
        // «+7 8 928…» → «+7  928…»: двойной пробел на месте цифры — один.
        if idx > 0, idx < chars.count, chars[idx - 1] == " ", chars[idx] == " " { chars.remove(at: idx) }
        return String(chars)
    }
}

extension Binding where Value == String {
    /// Поле телефона: лишняя 8/7 после «+7» убирается при вводе и вставке (PhoneInput.fix).
    var phoneInput: Binding<String> {
        Binding(get: { wrappedValue }, set: { wrappedValue = PhoneInput.fix($0) })
    }
}
