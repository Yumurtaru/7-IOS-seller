import Foundation

// ============================================================================
//  Жильё (routes/seller_lodging.php): объекты, тарифы, календарь, брони,
//  заявки на длительную аренду, туристический налог.
// ----------------------------------------------------------------------------
//  Формы 1:1 с сервером. Деньги приходят строкой "0.00" → Decimal через
//  @LenientDecimal, целые и булевы — @LenientInt/@LenientBool (канон SKILL.md):
//  сервер отдаёт их и числом, и строкой, и штатный Codable на этом падает.
//
//  ВАЖНО про сохранение: сервер меняет ТОЛЬКО пришедшие ключи
//  (Lodging::unitFromInput). Поэтому запросы собираются словарём и в них
//  попадает лишь то, что экран действительно менял, — иначе приложение
//  затирало бы настройки, сделанные в веб-кабинете.
// ============================================================================

// MARK: - Объекты

struct LodgingUnitsResponse: Decodable {
    let items: [LodgingUnit]?
    let subtypes: [LodgingSubtype]?
}

struct LodgingSubtype: Decodable, Identifiable, Hashable {
    let key: String
    let label: String?
    /// Для отелей, хостелов, баз отдыха номер в реестре обязателен.
    @LenientBool var registryRequired: Bool?
    var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, label
        case registryRequired = "registry_required"
    }
}

struct LodgingReadinessItem: Decodable, Identifiable, Hashable {
    let key: String?
    let label: String?
    let hint: String?
    @LenientBool var ok: Bool?
    var id: String { key ?? label ?? UUID().uuidString }
}

struct LodgingReadiness: Decodable, Hashable {
    @LenientBool var ready: Bool?
    @LenientInt var done: Int?
    @LenientInt var total: Int?
    let items: [LodgingReadinessItem]?

    enum CodingKeys: String, CodingKey { case ready, done, total, items }
}

struct LodgingPhoto: Decodable, Identifiable, Hashable {
    let id: Int
    let path: String?
    @LenientBool var isCover: Bool?

    enum CodingKeys: String, CodingKey {
        case id, path
        case isCover = "is_cover"
    }
}

struct LodgingRules: Decodable, Hashable {
    let checkInFrom: String?
    let checkOutUntil: String?
    let holdType: String?
    let holdUntilTime: String?
    @LenientDouble var prepayPct: Double?
    @LenientInt var cancelFreeDays: Int?
    let cancelPenalty: String?
    @LenientInt var petsAllowed: Int?
    @LenientInt var smokingAllowed: Int?
    @LenientInt var partyAllowed: Int?
    @LenientInt var kidsAllowed: Int?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case text
        case checkInFrom = "check_in_from"
        case checkOutUntil = "check_out_until"
        case holdType = "hold_type"
        case holdUntilTime = "hold_until_time"
        case prepayPct = "prepay_pct"
        case cancelFreeDays = "cancel_free_days"
        case cancelPenalty = "cancel_penalty"
        case petsAllowed = "pets_allowed"
        case smokingAllowed = "smoking_allowed"
        case partyAllowed = "party_allowed"
        case kidsAllowed = "kids_allowed"
    }
}

struct LodgingRegistry: Decodable, Hashable {
    let no: String?
    let url: String?
}

struct LodgingLongTerm: Decodable, Hashable {
    @LenientDecimal var priceMonth: Decimal?
    @LenientInt var minMonths: Int?
    @LenientInt var utilitiesIncluded: Int?
    let utilitiesNote: String?
    @LenientDecimal var depositMonth: Decimal?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case note
        case priceMonth = "price_month"
        case minMonths = "min_months"
        case utilitiesIncluded = "utilities_included"
        case utilitiesNote = "utilities_note"
        case depositMonth = "deposit_month"
    }
}

struct LodgingUnit: Decodable, Identifiable, Hashable {
    let id: Int
    let slug: String?
    let title: String?
    let kind: String?                  // whole | room
    let subtype: String?
    let subtypeLabel: String?
    let description: String?
    @LenientInt var baseGuests: Int?
    @LenientInt var maxGuests: Int?
    @LenientInt var maxChildren: Int?
    @LenientInt var roomsCount: Int?
    @LenientInt var areaM2: Int?
    @LenientInt var floor: Int?
    /// Сколько таких объектов/номеров продаётся одновременно.
    @LenientInt var inventory: Int?
    @LenientInt var rentDaily: Int?
    @LenientInt var rentLong: Int?
    @LenientDecimal var priceNight: Decimal?
    @LenientDecimal var priceWeekend: Decimal?
    @LenientDecimal var cleaningFee: Decimal?
    @LenientDecimal var deposit: Decimal?
    @LenientDecimal var extraGuestPrice: Decimal?
    @LenientInt var minNights: Int?
    @LenientInt var maxNights: Int?
    @LenientDouble var discountWeekPct: Double?
    @LenientDouble var discountMonthPct: Double?
    let address: String?
    @LenientInt var instantBooking: Int?
    let rules: LodgingRules?
    let registry: LodgingRegistry?
    let longTerm: LodgingLongTerm?
    // Поля кабинета (в публичной карточке их нет).
    @LenientInt var isActive: Int?
    @LenientInt var sortOrder: Int?
    @LenientDecimal var priceMonth: Decimal?
    @LenientInt var minMonths: Int?
    let photos: [LodgingPhoto]?
    @LenientInt var photosCount: Int?
    let cover: String?
    let amenities: [String]?
    @LenientInt var ratePlansCount: Int?
    let readiness: LodgingReadiness?
    @LenientInt var bookingsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, slug, title, kind, subtype, description, inventory, address, rules, registry
        case photos, cover, amenities, readiness, floor, deposit
        case subtypeLabel = "subtype_label"
        case baseGuests = "base_guests"
        case maxGuests = "max_guests"
        case maxChildren = "max_children"
        case roomsCount = "rooms_count"
        case areaM2 = "area_m2"
        case rentDaily = "rent_daily"
        case rentLong = "rent_long"
        case priceNight = "price_night"
        case priceWeekend = "price_weekend"
        case cleaningFee = "cleaning_fee"
        case extraGuestPrice = "extra_guest_price"
        case minNights = "min_nights"
        case maxNights = "max_nights"
        case discountWeekPct = "discount_week_pct"
        case discountMonthPct = "discount_month_pct"
        case instantBooking = "instant_booking"
        case longTerm = "long_term"
        case isActive = "is_active"
        case sortOrder = "sort_order"
        case priceMonth = "price_month"
        case minMonths = "min_months"
        case photosCount = "photos_count"
        case ratePlansCount = "rate_plans_count"
        case bookingsCount = "bookings_count"
    }

    var unitTitle: String { title ?? "Объект" }
}

struct LodgingAmenityGroup: Decodable, Identifiable, Hashable {
    let group: String?
    let items: [LodgingAmenity]?
    var id: String { group ?? "—" }
}

struct LodgingAmenity: Decodable, Identifiable, Hashable {
    let slug: String
    let name: String?
    let icon: String?
    var id: String { slug }

    enum CodingKeys: String, CodingKey { case slug, name, icon }
}

/// Удаление объекта: по объекту с бронями сервер его НЕ удаляет, а снимает с
/// витрины и присылает причину — её обязательно показать, иначе «Удалить»
/// выглядит как сбой (объект остаётся в списке).
struct LodgingUnitDeleteAck: Decodable {
    @LenientBool var deleted: Bool?
    @LenientBool var hidden: Bool?
    let message: String?

    enum CodingKeys: String, CodingKey { case deleted, hidden, message }
}

struct LodgingPhotoAck: Decodable {
    let id: Int
    let path: String?
}

// MARK: - Тарифы

struct LodgingRatePlan: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let priceMode: String?          // base | percent | absolute
    @LenientDecimal var priceValue: Decimal?
    let meal: String?               // none | breakfast | half | full
    @LenientInt var cancelFreeDays: Int?
    let cancelPenalty: String?
    @LenientInt var minNights: Int?
    @LenientDouble var prepayPct: Double?
    @LenientInt var isActive: Int?
    @LenientInt var sortOrder: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, meal
        case priceMode = "price_mode"
        case priceValue = "price_value"
        case cancelFreeDays = "cancel_free_days"
        case cancelPenalty = "cancel_penalty"
        case minNights = "min_nights"
        case prepayPct = "prepay_pct"
        case isActive = "is_active"
        case sortOrder = "sort_order"
    }
}

/// Удаление тарифа: по проданному сервер его ВЫКЛЮЧАЕТ, а не удаляет.
struct LodgingPlanDeleteAck: Decodable {
    @LenientBool var deleted: Bool?
    @LenientBool var disabled: Bool?
    @LenientInt var bookings: Int?
    let message: String?
}

// MARK: - Календарь

struct LodgingCalendarUnit: Decodable, Hashable {
    let id: Int
    let title: String?
    @LenientInt var inventory: Int?
}

struct LodgingCalendarDay: Decodable, Identifiable, Hashable {
    let date: String
    /// Цена, которая реально применится (своя цена даты или базовая).
    @LenientDecimal var price: Decimal?
    /// Своя цена именно этой даты; nil — берётся базовая.
    @LenientDecimal var ownPrice: Decimal?
    @LenientInt var inventory: Int?
    @LenientInt var booked: Int?
    @LenientInt var free: Int?
    @LenientInt var isClosed: Int?
    @LenientInt var minNights: Int?
    @LenientInt var cta: Int?
    @LenientInt var ctd: Int?
    @LenientInt var weekend: Int?
    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date, price, inventory, booked, free, cta, ctd, weekend
        case ownPrice = "own_price"
        case isClosed = "is_closed"
        case minNights = "min_nights"
    }
}

struct LodgingCalendar: Decodable {
    let unit: LodgingCalendarUnit?
    @LenientDecimal var basePrice: Decimal?
    @LenientDecimal var weekendPrice: Decimal?
    let from: String?
    let to: String?
    let days: [LodgingCalendarDay]?

    enum CodingKeys: String, CodingKey {
        case unit, from, to, days
        case basePrice = "base_price"
        case weekendPrice = "weekend_price"
    }
}

struct LodgingCalendarAck: Decodable {
    @LenientInt var days: Int?
}

// MARK: - Брони

struct LodgingToday: Decodable, Hashable {
    let date: String?
    @LenientInt var arrivals: Int?
    @LenientInt var departures: Int?
    @LenientInt var staying: Int?
}

struct LodgingBooking: Decodable, Identifiable, Hashable {
    let id: Int
    @LenientInt var unitId: Int?
    let unitTitle: String?
    @LenientInt var orderId: Int?
    @LenientInt var dailyNumber: Int?
    let paymentStatus: String?
    let dateFrom: String?
    let dateTo: String?
    @LenientInt var nights: Int?
    @LenientInt var rooms: Int?
    @LenientInt var adults: Int?
    @LenientInt var children: Int?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var prepay: Decimal?
    @LenientDecimal var touristTax: Decimal?
    let status: String?
    let statusLabel: String?
    let guestName: String?
    let guestPhone: String?
    let guestComment: String?
    let sellerNote: String?
    let ratePlan: String?
    let checkInFrom: String?
    let checkOutUntil: String?

    enum CodingKeys: String, CodingKey {
        case id, nights, rooms, adults, children, total, prepay, status
        case unitId = "unit_id"
        case unitTitle = "unit_title"
        case orderId = "order_id"
        case dailyNumber = "daily_number"
        case paymentStatus = "payment_status"
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case touristTax = "tourist_tax"
        case statusLabel = "status_label"
        case guestName = "guest_name"
        case guestPhone = "guest_phone"
        case guestComment = "guest_comment"
        case sellerNote = "seller_note"
        case ratePlan = "rate_plan"
        case checkInFrom = "check_in_from"
        case checkOutUntil = "check_out_until"
    }
}

struct LodgingBookingsResponse: Decodable {
    let items: [LodgingBooking]?
    let today: LodgingToday?
}

struct LodgingBookingCreatedAck: Decodable {
    let id: Int
    @LenientDecimal var total: Decimal?

    enum CodingKeys: String, CodingKey { case id, total }
}

struct LodgingStatusAck: Decodable {
    let status: String?
    let statusLabel: String?
    @LenientDecimal var penalty: Decimal?
    @LenientDecimal var paid: Decimal?
    @LenientDecimal var refund: Decimal?

    enum CodingKeys: String, CodingKey {
        case status, penalty, paid, refund
        case statusLabel = "status_label"
    }
}

// MARK: - Заявки на длительную аренду

struct LodgingLongRequest: Decodable, Identifiable, Hashable {
    let id: Int
    @LenientInt var unitId: Int?
    let unitTitle: String?
    let name: String?
    let phone: String?
    @LenientInt var months: Int?
    let desiredFrom: String?
    @LenientInt var adults: Int?
    @LenientInt var children: Int?
    @LenientInt var pets: Int?
    let message: String?
    let status: String?              // new|contacted|agreed|declined|closed
    let statusLabel: String?
    let sellerNote: String?
    @LenientDecimal var priceMonth: Decimal?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, phone, months, adults, children, pets, message, status
        case unitId = "unit_id"
        case unitTitle = "unit_title"
        case desiredFrom = "desired_from"
        case statusLabel = "status_label"
        case sellerNote = "seller_note"
        case priceMonth = "price_month"
        case createdAt = "created_at"
    }
}

// MARK: - Настройки раздела (туристический налог)

struct LodgingSettings: Decodable {
    @LenientDouble var touristTaxPct: Double?
    @LenientDecimal var touristTaxMin: Decimal?
    let hint: String?

    enum CodingKeys: String, CodingKey {
        case hint
        case touristTaxPct = "tourist_tax_pct"
        case touristTaxMin = "tourist_tax_min"
    }
}
