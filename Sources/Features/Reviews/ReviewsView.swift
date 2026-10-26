import SwiftUI

// ============================================================================
//  Отзывы — GET /api/seller/reviews?status= (bare array, до 200).
//  Модерация approve/reject на сервере ЗАКРЫТА (403 «модерирует администратор
//  маркетплейса») — кнопок модерации нет, продавцу доступен ответ владельца:
//  POST /api/seller/reviews/{id}/reply (создаёт или обновляет один ответ).
// ============================================================================

@MainActor
final class ReviewsViewModel: ObservableObject {
    @Published var items: [SellerReview] = []
    @Published var state: LoadState = .idle
    /// Номер последнего запроса: ответ на прежний фильтр/период, пришедший
    /// позже нового, раньше перетирал экран данными не того фильтра.
    private var loadGen = 0
    @Published var statusFilter: String? {
        didSet { if statusFilter != oldValue { items = []; state = .loading; loadGen += 1; Task { await load() } } }
    }
    @Published var error: String?

    static let statusChips: [(String?, String)] = [
        (nil, "Все"), ("pending", "На модерации"), ("approved", "Опубликованы"), ("rejected", "Отклонены"),
    ]

    func load() async {
        loadGen += 1
        let myGen = loadGen
        if items.isEmpty { state = .loading }
        do {
            let fresh = try await API.shared.reviews(status: statusFilter)
            guard myGen == loadGen else { return }
            items = fresh
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard myGen == loadGen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func reply(to review: SellerReview, text: String) async -> Bool {
        error = nil
        do {
            try await API.shared.replyToReview(id: review.reviewId, text: text)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

struct ReviewsView: View {
    @StateObject private var vm = ReviewsViewModel()
    @State private var replyTarget: SellerReview?

    var body: some View {
        VStack(spacing: 0) {
            chips
            List {
                ForEach(vm.items) { review in
                    ReviewRow(review: review) { replyTarget = review }
                        .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .refreshable { await vm.load() }
            .listState(vm.state, isEmpty: vm.items.isEmpty,
                       emptyIcon: "star.bubble", emptyTitle: "Отзывов пока нет",
                       emptySubtitle: "Отзывы модерирует администратор маркетплейса, вы можете на них отвечать",
                       retry: { Task { await vm.load() } })
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Отзывы")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $replyTarget) { review in
            ReviewReplySheet(review: review, vm: vm)
                .onAppear { vm.error = nil }   // ошибка прошлого ответа не висит в новом окне
        }
        .task { await vm.load() }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ReviewsViewModel.statusChips, id: \.1) { value, title in
                    FilterChip(title: title, selected: vm.statusFilter == value) {
                        vm.statusFilter = value
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

struct ReviewRow: View {
    let review: SellerReview
    let onReply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                stars(review.ratingOverall ?? 0)
                if review.isVerified == true {
                    StatusBadge(text: "Покупка", color: Brand.green)
                }
                Spacer()
                StatusBadge(text: statusLabel, color: statusColor)
            }
            HStack(spacing: 8) {
                Text(review.author ?? "Аноним")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Brand.text)
                if let oid = review.orderId, oid > 0 {
                    Text("Заказ №\(oid)").font(.caption).foregroundColor(Brand.muted)
                }
                Text(DateFmt.short(review.createdAt))
                    .font(.caption).foregroundColor(Brand.muted)
            }
            if let text = review.text, !text.isEmpty {
                Text(text).font(.subheadline).foregroundColor(Brand.text)
            }
            subRatings
            if !review.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(review.photos, id: \.self) { path in
                            RemoteImage(path: path, size: 56, cornerRadius: 8)
                        }
                    }
                }
            }
            if let reply = review.reply, !reply.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ваш ответ").font(.caption2.weight(.bold)).foregroundColor(Brand.accent)
                    Text(reply).font(.footnote).foregroundColor(Brand.text)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.chip)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Button(action: onReply) {
                Label(review.reply?.isEmpty == false ? "Изменить ответ" : "Ответить",
                      systemImage: "arrowshape.turn.up.left")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(Brand.accent)
        }
        .padding(.vertical, 4)
    }

    private var subRatings: some View {
        HStack(spacing: 10) {
            subRating("Кухня", review.ratingFood)
            subRating("Доставка", review.ratingDelivery)
            subRating("Сервис", review.ratingService)
        }
        .font(.caption2)
        .foregroundColor(Brand.muted)
    }

    @ViewBuilder
    private func subRating(_ title: String, _ value: Int?) -> some View {
        if let v = value, v > 0 {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "star.fill").font(.system(size: 8)).foregroundColor(Brand.amber)
                Text("\(v)")
            }
        }
    }

    private func stars(_ n: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= n ? "star.fill" : "star")
                    .font(.caption)
                    .foregroundColor(i <= n ? Brand.amber : Brand.muted)
            }
        }
    }

    private var statusLabel: String {
        switch review.status {
        case "pending": return "На модерации"
        case "approved": return "Опубликован"
        case "rejected": return "Отклонён"
        default: return review.status ?? "—"
        }
    }

    private var statusColor: Color {
        switch review.status {
        case "pending": return Brand.amber
        case "approved": return Brand.green
        case "rejected": return Brand.red
        default: return Brand.muted
        }
    }
}

/// Лист ответа владельца на отзыв.
struct ReviewReplySheet: View {
    let review: SellerReview
    @ObservedObject var vm: ReviewsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var sending = false

    /// Предел длины ответа на сервере.
    private static let maxReply = 1000
    /// Длина так, как её считает сервер (mb_strlen после trim).
    private var replyLength: Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    init(review: SellerReview, vm: ReviewsViewModel) {
        self.review = review
        self.vm = vm
        _text = State(initialValue: review.reply ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Отзыв") {
                    Text(review.text ?? "Без текста")
                        .font(.subheadline).foregroundColor(Brand.muted)
                }
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                } header: {
                    Text("Ответ владельца")
                } footer: {
                    // Сервер молча обрезает ответ до 1000 символов
                    // (seller_analytics.php, reviews/{id}/reply: noteClamp 1000) —
                    // на витрине он оборвался бы на полуслове.
                    Text("\(replyLength) / \(Self.maxReply)")
                        .foregroundColor(replyLength > Self.maxReply ? Brand.red : Brand.muted)
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Ответ на отзыв")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Отправка…" : "Отправить") {
                        // Флаг — до Task: два тапа в одном кадре слали ответ дважды.
                        guard !sending else { return }
                        sending = true
                        Task {
                            let ok = await vm.reply(to: review, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
                            sending = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || replyLength > Self.maxReply)
                }
            }
            // Смахивание листа вниз стирало набранный ответ без вопроса (и во
            // время отправки). Закрыть с правками — только кнопкой «Отмена».
            .interactiveDismissDisabled(sending || text != (review.reply ?? ""))
        }
    }
}
