import Foundation

// ============================================================================
//  Раздел «Управление» — то, что в веб-панели живёт отдельными страницами:
//    • вакансии и отклики   (vacancies, applications; право «Сотрудники»)
//    • подарочные карты     (gift_cards;              право «Клиенты»)
//    • выгрузки данных      (export/*;                право «Товары»)
//    • QR витрины           (marketing/qr.*;          право «Маркетинг»)
//    • тип и режим организации (settings/type|mode;   право «Настройки»)
//
//  Права взяты из карты сервера (core/StaffAccess.php), не придуманы здесь:
//  скрытый пункт меню — удобство, отказ выдаёт сервер.
// ============================================================================

// ── Вакансии ─────────────────────────────────────────────────────────────────

/// Профессия. Список закрытый — enum в БД, сервер молча подменяет чужое на other.
enum VacancyCategory: String, CaseIterable, Identifiable {
    case cook, bartender, cashier, courier, manager, cleaner, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cook:      return "Повар"
        case .bartender: return "Бармен"
        case .cashier:   return "Кассир"
        case .courier:   return "Курьер"
        case .manager:   return "Менеджер"
        case .cleaner:   return "Уборщик"
        case .other:     return "Другое"
        }
    }
}

enum VacancyEmployment: String, CaseIterable, Identifiable {
    case full, part, project
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full:    return "Полная занятость"
        case .part:    return "Подработка"
        case .project: return "Проект"
        }
    }
}

enum VacancyExperience: String, CaseIterable, Identifiable {
    case none, y1 = "1year", y3 = "3years", y5 = "5years"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Без опыта"
        case .y1:   return "От 1 года"
        case .y3:   return "От 3 лет"
        case .y5:   return "От 5 лет"
        }
    }
}

enum VacancyStatus: String, CaseIterable, Identifiable {
    case open, paused, closed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open:   return "Открыта"
        case .paused: return "На паузе"
        case .closed: return "Закрыта"
        }
    }
}

struct Vacancy: Decodable, Identifiable {
    @LenientInt var id: Int?
    let title: String?
    let category: String?
    let description: String?
    let requirements: String?
    let conditions: String?
    let schedule: String?
    @LenientDecimal var salaryFrom: Decimal?
    @LenientDecimal var salaryTo: Decimal?
    let employmentType: String?
    let experience: String?
    let address: String?
    let status: String?
    @LenientInt var viewsCount: Int?
    /// Считаются подзапросом на сервере: всего откликов и сколько новых.
    @LenientInt var apps: Int?
    @LenientInt var newApps: Int?
    let createdAt: String?

    var vacancyId: Int { id ?? 0 }
    var kind: VacancyCategory { VacancyCategory(rawValue: category ?? "") ?? .other }
    var employment: VacancyEmployment { VacancyEmployment(rawValue: employmentType ?? "") ?? .full }
    var exp: VacancyExperience { VacancyExperience(rawValue: experience ?? "") ?? .none }
    var state: VacancyStatus { VacancyStatus(rawValue: status ?? "") ?? .open }

    /// «от 50 000 ₽», «50 000 – 80 000 ₽», «Зарплата не указана».
    var salaryLabel: String {
        let from = (salaryFrom ?? 0) > 0 ? salaryFrom : nil
        let to = (salaryTo ?? 0) > 0 ? salaryTo : nil
        switch (from, to) {
        case let (f?, t?): return "\(Money.rub(f)) – \(Money.rub(t))"
        case let (f?, nil): return "от \(Money.rub(f))"
        case let (nil, t?): return "до \(Money.rub(t))"
        default: return "Зарплата не указана"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, title, category, description, requirements, conditions, schedule
        case address, status, apps
        case salaryFrom = "salary_from"
        case salaryTo = "salary_to"
        case employmentType = "employment_type"
        case experience
        case viewsCount = "views_count"
        case newApps = "new_apps"
        case createdAt = "created_at"
    }
}

enum ApplicationStatus: String, CaseIterable, Identifiable {
    case new, viewed, invited, rejected
    var id: String { rawValue }
    var title: String {
        switch self {
        case .new:      return "Новый"
        case .viewed:   return "Просмотрен"
        case .invited:  return "Приглашён"
        case .rejected: return "Отказ"
        }
    }
}

struct JobApplication: Decodable, Identifiable {
    @LenientInt var id: Int?
    let name: String?
    let phone: String?
    let email: String?
    let coverLetter: String?
    let resumeFile: String?
    let status: String?
    let createdAt: String?

    var applicationId: Int { id ?? 0 }
    var state: ApplicationStatus { ApplicationStatus(rawValue: status ?? "") ?? .new }

    enum CodingKeys: String, CodingKey {
        case id, name, phone, email, status
        case coverLetter = "cover_letter"
        case resumeFile = "resume_file"
        case createdAt = "created_at"
    }
}

// ── Подарочные карты ─────────────────────────────────────────────────────────

struct GiftCard: Decodable, Identifiable {
    @LenientInt var id: Int?
    let code: String?
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var balance: Decimal?
    let recipientName: String?
    let greeting: String?
    let status: String?
    let expiresAt: String?
    let createdAt: String?

    var cardId: Int { id ?? 0 }
    var isActive: Bool { (status ?? "") == "active" }
    /// active | used | expired — других значений enum в базе нет.
    var statusTitle: String {
        switch status ?? "" {
        case "active":  return "Активна"
        case "used":    return "Использована"
        case "expired": return "Погашена"
        default:        return status ?? "—"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, code, amount, balance, greeting, status
        case recipientName = "recipient_name"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}

/// POST /api/seller/giftcards → {id, code}. Код придумывает сервер.
struct GiftCardCreateAck: Decodable {
    @LenientInt var id: Int?
    let code: String?
}

// ── Тип и режим организации ──────────────────────────────────────────────────

/// В API тип называется иначе, чем в базе: store↔shop, restaurant↔cafe.
/// Приложение всегда говорит на языке API, перевод делает сервер.
enum OrgType: String, CaseIterable, Identifiable {
    case store, restaurant, service, lodging
    var id: String { rawValue }
    var title: String {
        switch self {
        case .store:      return "Магазин"
        case .restaurant: return "Кафе или ресторан"
        case .service:    return "Услуги"
        case .lodging:    return "Жильё"
        }
    }
    var hint: String {
        switch self {
        case .store:      return "Товары, склад, доставка"
        case .restaurant: return "Меню, столы, кухня, тех. карты"
        case .service:    return "Мастера, записи, выезд к клиенту"
        case .lodging:    return "Объекты, календарь цен, тарифы, брони"
        }
    }
    /// Как тот же тип называется в shops.type — это приходит в /api/seller/me.
    var dbValue: String {
        switch self {
        case .store:      return "shop"
        case .restaurant: return "cafe"
        case .service:    return "service"
        case .lodging:    return "lodging"
        }
    }
    static func fromDb(_ v: String?) -> OrgType {
        switch v ?? "" {
        case "cafe":    return .restaurant
        case "service": return .service
        // Без этой ветки гостиница показывала себя «Магазином»: значение
        // проваливалось в default. Мало того что подпись врала — сосед по
        // списку был в одном нажатии от превращения жилья в услуги.
        case "lodging": return .lodging
        default:        return .store
        }
    }
}

/// Режим витрины: shops.mode. Значения здесь и в базе совпадают.
enum OrgMode: String, CaseIterable, Identifiable {
    case storefront, shop, restaurant
    var id: String { rawValue }
    var title: String {
        switch self {
        case .storefront: return "Витрина"
        case .shop:       return "Магазин"
        case .restaurant: return "Ресторан"
        }
    }
    var hint: String {
        switch self {
        case .storefront: return "Только показ товаров, без заказов"
        case .shop:       return "Корзина и оформление заказа"
        case .restaurant: return "Меню, модификаторы, столы"
        }
    }
}

struct OrgTypeAck: Decodable { let type: String? }
struct OrgModeAck: Decodable { let mode: String? }
