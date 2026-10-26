import Foundation
import SwiftUI

// ============================================================================
//  Листы ожидания и брони столов — разделов не было в приложении.
//
//  GET /api/seller/waitlist → {waitlist:[…], price_alerts:[…]}
//     waitlist    — кто ждёт товар, которого нет в наличии;
//     price_alerts— кто ждёт снижения цены до target_price.
//
//  GET  /api/seller/reservations?status=&date=   → bare array
//  POST /api/seller/reservations/{id}/status     → confirmed|rejected|cancelled|seated
// ============================================================================

struct WaitlistEntry: Decodable, Identifiable {
    @LenientInt var productId: Int?
    let name: String?
    @LenientInt var waiting: Int?

    var id: Int { productId ?? 0 }

    enum CodingKeys: String, CodingKey {
        case name, waiting
        case productId = "product_id"
    }
}

struct PriceAlertEntry: Decodable, Identifiable {
    @LenientInt var productId: Int?
    let name: String?
    @LenientDecimal var targetPrice: Decimal?
    @LenientInt var watchers: Int?

    /// Один товар может ждать по разным ценам — id склеиваем с ценой,
    /// иначе ForEach схлопнет строки в одну.
    var id: String { "\(productId ?? 0)-\(targetPrice?.description ?? "")" }

    enum CodingKeys: String, CodingKey {
        case name, watchers
        case productId = "product_id"
        case targetPrice = "target_price"
    }
}

struct WaitlistResponse: Decodable {
    let waitlist: [WaitlistEntry]?
    let priceAlerts: [PriceAlertEntry]?

    enum CodingKeys: String, CodingKey {
        case waitlist
        case priceAlerts = "price_alerts"
    }
}

struct TableReservation: Decodable, Identifiable {
    @LenientInt var id: Int?
    let name: String?
    let phone: String?
    @LenientInt var guests: Int?
    let date: String?
    let time: String?
    let status: String?
    let comment: String?
    let createdAt: String?
    let tableNumber: String?

    var reservationId: Int { id ?? 0 }

    enum CodingKeys: String, CodingKey {
        case id, name, phone, guests, date, time, status, comment
        case createdAt = "created_at"
        case tableNumber = "table_number"
    }
}

/// Подписи и цвета статусов брони — зеркало списка, который принимает сервер.
enum ReservationLabels {
    static let actionable = ["confirmed", "rejected", "cancelled", "seated"]

    static func label(_ s: String?) -> String {
        switch s {
        case "new", "pending": return "Новая"
        case "confirmed":      return "Подтверждена"
        case "seated":         return "Гости за столом"
        case "rejected":       return "Отклонена"
        case "cancelled":      return "Отменена"
        case "no_show":        return "Гости не пришли"   // П-22.8: был сырой код «no_show»
        default:               return s ?? "—"
        }
    }

    static func color(_ s: String?) -> Color {
        switch s {
        case "confirmed", "seated": return Brand.green
        case "rejected", "cancelled", "no_show": return Brand.red
        default: return Brand.amber
        }
    }
}
