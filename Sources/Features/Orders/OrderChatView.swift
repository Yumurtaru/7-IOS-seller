import SwiftUI

// ============================================================================
//  Чат с клиентом — GET/POST /api/seller/orders/{id}/chat.
//  Инкрементальная подгрузка через ?after_id=N (сервер поддерживает, Фаза 1.10),
//  поллинг 5 с → 15 с в тишине (см. startPolling), отправка шлёт клиенту push (серверная логика).
// ============================================================================

@MainActor
final class OrderChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var state: LoadState = .idle
    @Published var sendError: String?
    @Published var isSending = false

    let orderId: Int
    private var pollTask: Task<Void, Never>?
    /// Ушли в фон (или закрыли) во время первой загрузки — опрос после неё не запускаем.
    private var paused = false

    init(orderId: Int) { self.orderId = orderId }

    func start() async {
        paused = false
        state = .loading
        await loadInitial()
        // Экран закрыли, пока шла первая загрузка, — опрос не запускаем
        // (иначе он крутился бы до конца сессии).
        guard !Task.isCancelled, !paused else { return }
        startPolling(immediate: false)
    }

    /// Опрос с бэк-оффом: раньше GET каждые 5 с, пока чат открыт (~720 в час,
    /// если шторку оставили на весь день). Первые 12 тихих опросов (минута) —
    /// раз в 5 с, дальше раз в 15 с; новое сообщение (своё или клиента) и
    /// повторный показ экрана снова дают 5 с. Инкремент по after_id прежний.
    private func startPolling(immediate: Bool) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var quiet = 0
            var lastSeen = self?.messages.last?.messageId ?? 0
            var first = immediate
            while !Task.isCancelled {
                if !first {
                    try? await Task.sleep(nanoseconds: quiet < 12 ? 5_000_000_000 : 15_000_000_000)
                }
                first = false
                // Закрыли во время паузы — лишний запрос после закрытия не шлём.
                if Task.isCancelled { return }
                guard let self else { return }
                await self.loadNew()
                let now = self.messages.last?.messageId ?? 0
                if now != lastSeen { lastSeen = now; quiet = 0 } else { quiet += 1 }
            }
        }
    }

    /// Вернулись в приложение с открытым чатом: сразу забираем новое и снова
    /// опрашиваем часто. До конца первой загрузки опрос запустит start().
    func resume() {
        paused = false   // первая загрузка ещё идёт — опрос запустит start()
        guard state != .idle, state != .loading else { return }
        startPolling(immediate: true)
    }

    func stop() {
        paused = true
        pollTask?.cancel()
        pollTask = nil
    }

    private func loadInitial() async {
        do {
            messages = try await API.shared.orderChat(id: orderId, afterId: nil)
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func loadNew() async {
        let lastId = messages.last?.messageId ?? 0
        guard lastId > 0 else { await loadInitial(); return }
        guard let fresh = try? await API.shared.orderChat(id: orderId, afterId: lastId), !fresh.isEmpty else { return }
        // Опрос и отправка могут дозапросить одно и то же параллельно (оба с
        // тем же lastId) — без фильтра сообщения задваивались, а одинаковые id
        // в ForEach ломают список. Берём только то, чего ещё нет.
        let known = Set(messages.map { $0.messageId })
        let add = fresh.filter { !known.contains($0.messageId) }
        if !add.isEmpty { messages += add }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            _ = try await API.shared.sendChatMessage(orderId: orderId, message: text)
            // Пока сообщение уходило, могли допечатать новое — его не стираем.
            // Отправленное убираем из начала поля, допечатанное после — оставляем
            // (иначе следующая отправка повторяла уже ушедший текст).
            let rest = draft.drop { $0.isWhitespace || $0.isNewline }
            if rest.hasPrefix(text) {
                draft = String(rest.dropFirst(text.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            await loadNew()
        } catch {
            sendError = error.localizedDescription
        }
    }
}

struct OrderChatView: View {
    @StateObject private var vm: OrderChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(orderId: Int) {
        _vm = StateObject(wrappedValue: OrderChatViewModel(orderId: orderId))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(vm.messages) { msg in
                                bubble(msg)
                                    .id(msg.messageId)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: vm.messages.count) { _ in
                        if let last = vm.messages.last {
                            withAnimation { proxy.scrollTo(last.messageId, anchor: .bottom) }
                        }
                    }
                }
                .listState(vm.state, isEmpty: vm.messages.isEmpty,
                           emptyIcon: "bubble.left.and.bubble.right",
                           emptyTitle: "Сообщений пока нет",
                           emptySubtitle: "Напишите клиенту по этому заказу")

                if let err = vm.sendError {
                    Text(err).font(.caption).foregroundColor(Brand.red).padding(.horizontal, 12)
                }
                // паритет с Android: сервер (routes/seller.php, чат) принимает не длиннее
                // 1000 символов — счётчик с 900, длиннее отправить нельзя.
                if draftLength >= 900 {
                    Text("\(draftLength) / 1000")
                        .font(.caption)
                        .foregroundColor(draftLength > 1000 ? Brand.red : Brand.muted)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 12)
                }

                HStack(spacing: 8) {
                    TextField("Сообщение…", text: $vm.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(10)
                        .background(Brand.chip)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    Button {
                        Task { await vm.send() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(vm.draft.trimmingCharacters(in: .whitespaces).isEmpty ? Brand.muted : Brand.accent)
                    }
                    .disabled(vm.isSending || vm.draft.trimmingCharacters(in: .whitespaces).isEmpty
                              || draftLength > 1000)
                }
                .padding(12)
                .background(Brand.card)
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Чат по заказу")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .task { await vm.start() }
            .onDisappear { vm.stop() }
            // В фоне чат не опрашиваем (свёрнутое приложение с открытой шторкой
            // слало запросы, пока iOS его не усыпит); вернулись — сразу дозапрос.
            .onChange(of: scenePhase) { phase in
                if phase == .background { vm.stop() } else if phase == .active { vm.resume() }
            }
        }
        // Чат — шторка: случайный свайп вниз закрывал её и стирал набранное, но
        // не отправленное сообщение. Есть текст — закрыть только кнопкой «Готово».
        .interactiveDismissDisabled(!vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Длина так, как её считает сервер (mb_strlen после trim).
    private var draftLength: Int {
        vm.draft.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    private func bubble(_ msg: ChatMessage) -> some View {
        let mine = msg.mine ?? false
        return HStack {
            if mine { Spacer(minLength: 48) }
            VStack(alignment: .trailing, spacing: 3) {
                // Фото из чата клиента: без него пузырь был пустым.
                if let url = API.imageURL(msg.attachment) {
                    Link(destination: url) {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                Image(systemName: "photo").foregroundColor(Brand.muted)
                            default:
                                ProgressView()
                            }
                        }
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                if let text = msg.message, !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .foregroundColor(mine ? .white : Brand.text)
                }
                Text(DateFmt.short(msg.createdAt))
                    .font(.caption2)
                    .foregroundColor(mine ? .white.opacity(0.7) : Brand.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(mine ? Brand.accent : Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if !mine { Spacer(minLength: 48) }
        }
    }
}
