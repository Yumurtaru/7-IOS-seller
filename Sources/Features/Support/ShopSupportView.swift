import SwiftUI
import QuickLook
import UniformTypeIdentifiers

// ============================================================================
//  Экран «Техподдержка» — переписка организации с поддержкой площадки
//  (как вкладка «Техподдержка» веб-кабинета, волна А66). Пузыри: свои справа,
//  поддержка слева с подписью автора. Вложение — одно фото или PDF.
//  Тело экрана разбито на маленькие подвиды: длинные цепочки модификаторов
//  уже упирались в лимит времени проверки типов Xcode.
// ============================================================================

struct ShopSupportView: View {
    @EnvironmentObject var session: Session
    @StateObject private var vm = ShopSupportViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    /// Фото на весь экран (в браузере: масштаб жестами, сохранение).
    @State private var imageLink: PayLink?
    /// А100: «Спросить помощника» — только если сервер ответил, что помощник включён.
    @ObservedObject private var assistant = AssistantFeature.shared
    @State private var showAssistant = false

    var body: some View {
        VStack(spacing: 0) {
            if assistant.available {
                AssistantEntryRow { showAssistant = true }
            }
            ShopSupportMessageList(vm: vm, onOpenImage: openImage)
            ShopSupportComposer(vm: vm)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Техподдержка")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.start() }
        // А100: включён ли помощник — при каждом открытии раздела и смене организации
        // (старый сервер — 404, кнопки нет).
        .task(id: session.activeShopId) { await assistant.refresh(shopId: session.activeShopId) }
        .navigationDestination(isPresented: $showAssistant) { AssistantView() }
        // Опрос — только пока экран виден и приложение активно.
        .onAppear { screenAppeared() }
        .onDisappear { screenDisappeared() }
        .onChange(of: scenePhase) { phase in
            vm.setVisible(onScreen && phase == .active)
        }
        // Сменили организацию, пока чат открыт, — переписка новой.
        .onChange(of: session.activeShopId) { _ in
            vm.shopChanged()
        }
        .sheet(item: $imageLink) { link in
            SafariView(url: link.url).ignoresSafeArea()
        }
        .errorAlert($vm.fileError)
    }

    private func screenAppeared() {
        onScreen = true
        ShopSupportViewModel.liveOnScreen = vm
        vm.setVisible(scenePhase == .active)
    }

    private func screenDisappeared() {
        onScreen = false
        if ShopSupportViewModel.liveOnScreen === vm { ShopSupportViewModel.liveOnScreen = nil }
        vm.setVisible(false)
    }

    private func openImage(_ url: URL) {
        imageLink = PayLink(url: url)
    }
}

// ── Лента сообщений ──────────────────────────────────────────────────────────
struct ShopSupportMessageList: View {
    @ObservedObject var vm: ShopSupportViewModel
    let onOpenImage: (URL) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    olderControl
                    ForEach(vm.messages) { msg in
                        bubble(msg)
                            .id(msg.id)
                    }
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.scrollToBottomTick) { _ in
                scrollToBottom(proxy)
            }
            .onChange(of: vm.keepVisibleId) { id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .top)
            }
        }
        .listState(vm.state, isEmpty: vm.messages.isEmpty,
                   emptyIcon: "bubble.left.and.bubble.right",
                   emptyTitle: "Напишите нам — ответим здесь же.",
                   emptySubtitle: "Можно приложить скриншот или PDF.",
                   retry: retry)
        // PDF — системный просмотрщик (файл скачан во временную папку).
        .quickLookPreview($vm.previewFileURL)
    }

    private func bubble(_ msg: ShopSupportMessage) -> ShopSupportBubble {
        ShopSupportBubble(message: msg,
                          supportName: vm.supportName,
                          isRead: isRead(msg),
                          opening: vm.openingMessageId == msg.id,
                          onOpenImage: onOpenImage,
                          onOpenPdf: { vm.openPdf(msg) })
    }

    /// Своё сообщение прочитано: флаг из ответа или отметка поддержки в шапке
    /// (опрос берёт только новые сообщения, флаг у старых сам не обновится).
    private func isRead(_ msg: ShopSupportMessage) -> Bool {
        if msg.read { return true }
        let adminRead = vm.thread?.adminReadId ?? 0
        return msg.id <= adminRead
    }

    private func retry() {
        Task { await vm.loadInitial() }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = vm.messages.last?.id else { return }
        // После вставки строк LazyVStack ещё не разложен — прокручиваем следующим тактом.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        }
    }

    @ViewBuilder
    private var olderControl: some View {
        if vm.hasMore {
            Button {
                Task { await vm.loadOlder() }
            } label: {
                HStack(spacing: 6) {
                    if vm.loadingOlder { ProgressView().controlSize(.small) }
                    Text(vm.loadingOlder ? "Загружаем…" : "Показать раньше")
                }
                .font(.footnote.weight(.semibold))
                .foregroundColor(Brand.accent)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .disabled(vm.loadingOlder)
            if let err = vm.olderError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(Brand.red)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

// ── Пузырь сообщения ─────────────────────────────────────────────────────────
struct ShopSupportBubble: View {
    let message: ShopSupportMessage
    let supportName: String
    let isRead: Bool
    let opening: Bool
    let onOpenImage: (URL) -> Void
    let onOpenPdf: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.mine { Spacer(minLength: 48) }
            content
            if !message.mine { Spacer(minLength: 48) }
        }
    }

    private var content: some View {
        VStack(alignment: message.mine ? .trailing : .leading, spacing: 4) {
            header
            attachmentView
            bodyText
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(message.mine ? Brand.accent : Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var authorName: String {
        let a = (message.author ?? "").trimmingCharacters(in: .whitespaces)
        return a.isEmpty ? supportName : a
    }

    private var mutedColor: Color {
        message.mine ? Color.white.opacity(0.75) : Brand.muted
    }

    private var textColor: Color {
        message.mine ? Color.white : Brand.text
    }

    /// Автор — у сообщений другой стороны; «Рассылка» — у общих объявлений.
    @ViewBuilder
    private var header: some View {
        if !message.mine || message.broadcast {
            HStack(spacing: 6) {
                if !message.mine {
                    Text(authorName)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Brand.accent)
                }
                if message.broadcast {
                    Label("Рассылка", systemImage: "megaphone")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(mutedColor)
                }
            }
        }
    }

    @ViewBuilder
    private var attachmentView: some View {
        if let att = message.attachment, let url = att.fullURL {
            if att.isPdf {
                pdfRow(att)
            } else {
                imageThumb(url)
            }
        }
    }

    private func pdfRow(_ att: ShopSupportAttachment) -> some View {
        Button(action: onOpenPdf) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .font(.title3)
                Text(att.displayName)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if opening {
                    ProgressView().controlSize(.small)
                }
            }
            .foregroundColor(textColor)
            .padding(8)
            .background(message.mine ? Color.white.opacity(0.18) : Brand.chip)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(opening)
    }

    private func imageThumb(_ url: URL) -> some View {
        Button {
            onOpenImage(url)
        } label: {
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
            .background(Brand.chip)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bodyText: some View {
        if !message.body.isEmpty {
            Text(message.body)
                .font(.subheadline)
                .foregroundColor(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Время и, у своих, «Отправлено» / «Прочитано».
    private var footer: some View {
        HStack(spacing: 4) {
            Text(ShopSupportTime.label(message.createdAt))
            if message.mine {
                Text("·")
                Text(isRead ? "Прочитано" : "Отправлено")
                Image(systemName: isRead ? "checkmark.circle.fill" : "checkmark")
            }
        }
        .font(.caption2)
        .foregroundColor(mutedColor)
    }
}

/// Сегодня — «14:05», иначе дата со временем (общий DateFmt приложения).
enum ShopSupportTime {
    static func label(_ s: String?) -> String {
        guard let date = DateFmt.parse(s) else { return s ?? "" }
        if Calendar.current.isDateInToday(date) { return DateFmt.time(s) }
        return DateFmt.short(s)
    }
}

// ── Поле ввода ───────────────────────────────────────────────────────────────
struct ShopSupportComposer: View {
    @ObservedObject var vm: ShopSupportViewModel
    @State private var pickingPhoto = false
    @State private var pickingPdf = false

    var body: some View {
        VStack(spacing: 6) {
            closedNote
            errorRow
            attachmentRow
            counter
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Brand.card)
        .sheet(isPresented: $pickingPhoto) {
            PhotoLibraryPicker(onPick: { image in vm.attachPhoto(image) },
                               onFail: { vm.fileError = $0 })
        }
    }

    /// Поддержка закрыла вопрос — писать всё равно можно (новое сообщение откроет его).
    @ViewBuilder
    private var closedNote: some View {
        if vm.thread?.isClosed == true {
            Label("Вопрос отмечен решённым. Напишите, если нужна ещё помощь.", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundColor(Brand.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Не отправилось — текст и вложение на месте, «Повторить» шлёт с тем же ключом.
    @ViewBuilder
    private var errorRow: some View {
        if let err = vm.sendError {
            HStack(alignment: .top, spacing: 8) {
                Text(err)
                    .font(.caption)
                    .foregroundColor(Brand.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Повторить") {
                    Task { await vm.send() }
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(Brand.accent)
                .disabled(!vm.canSend)
            }
        }
    }

    @ViewBuilder
    private var attachmentRow: some View {
        if vm.preparingAttachment {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Готовим файл…")
                    .font(.caption)
                    .foregroundColor(Brand.muted)
                Spacer()
            }
        } else if let att = vm.attachment {
            HStack(spacing: 8) {
                attachmentThumb(att)
                VStack(alignment: .leading, spacing: 2) {
                    Text(att.isPdf ? att.filename : "Фото")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Brand.text)
                        .lineLimit(1)
                    Text(ShopSupportViewModel.mbText(att.data.count))
                        .font(.caption2)
                        .foregroundColor(Brand.muted)
                }
                Spacer()
                Button {
                    vm.removeAttachment()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(Brand.muted)
                }
                .buttonStyle(.plain)
                .disabled(vm.isSending)
            }
        }
    }

    @ViewBuilder
    private func attachmentThumb(_ att: ShopSupportDraftAttachment) -> some View {
        if let img = att.preview {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            Image(systemName: "doc.richtext")
                .font(.title2)
                .foregroundColor(Brand.accent)
                .frame(width: 40, height: 40)
        }
    }

    /// Счётчик — ближе к пределу сервера (max_body, 4000 знаков).
    @ViewBuilder
    private var counter: some View {
        let n = vm.draftLength
        if n >= vm.maxBody - 200 {
            Text("\(n) / \(vm.maxBody)")
                .font(.caption)
                .foregroundColor(n > vm.maxBody ? Brand.red : Brand.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            attachMenu
            TextField("Сообщение…", text: $vm.draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(10)
                .background(Brand.chip)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            sendButton
        }
        .fileImporter(isPresented: $pickingPdf,
                      allowedContentTypes: [UTType.pdf],
                      allowsMultipleSelection: false) { result in
            vm.attachPdf(result)
        }
    }

    private var attachMenu: some View {
        Menu {
            Button {
                pickingPhoto = true
            } label: {
                Label("Фото из галереи", systemImage: "photo")
            }
            Button {
                pickingPdf = true
            } label: {
                Label("PDF-документ", systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(Brand.muted)
        }
        .disabled(vm.isSending || vm.preparingAttachment)
    }

    private var sendButton: some View {
        Button {
            Task { await vm.send() }
        } label: {
            sendIcon
        }
        .disabled(!vm.canSend)
    }

    @ViewBuilder
    private var sendIcon: some View {
        if vm.isSending {
            ProgressView()
                .frame(width: 30, height: 30)
        } else {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(vm.canSend ? Brand.accent : Brand.muted)
        }
    }
}
