import SwiftUI

// ============================================================================
//  Экран «Помощник Yumurta» (ИИ, сайт А100). Пузыри: вопросы справа, ответы
//  слева (короткий markdown, ссылки своего сайта — во встроенном Safari),
//  «Источники:», 👍/👎, «Позвать человека» → чат «Техподдержки».
//  Тело разбито на маленькие подвиды: длинные цепочки модификаторов
//  упираются в лимит времени проверки типов Xcode.
// ============================================================================

struct AssistantView: View {
    @EnvironmentObject var session: Session
    @StateObject private var vm = AssistantViewModel()
    @Environment(\.dismiss) private var dismiss
    /// Ссылка из ответа — во встроенном браузере (SFSafariViewController).
    @State private var link: PayLink?
    @State private var confirmHandoff = false

    var body: some View {
        VStack(spacing: 0) {
            AssistantHeaderNote(vm: vm)
            AssistantMessageList(vm: vm)
            if vm.enabled && vm.state == .loaded {
                AssistantComposer(vm: vm, onHandoff: { confirmHandoff = true })
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle(vm.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .environment(\.openURL, OpenURLAction { url in
            openLink(url)
            return .handled
        })
        .sheet(item: $link) { l in
            SafariView(url: l.url).ignoresSafeArea()
        }
        .task { await vm.start() }
        // Сменили организацию, пока экран открыт, — переписка новой.
        .onChange(of: session.activeShopId) { _ in
            Task { await vm.load() }
        }
        .confirmationDialog("Позвать человека?", isPresented: $confirmHandoff, titleVisibility: .visible) {
            Button("Передать в Техподдержку") { Task { await vm.handoff() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сотрудник увидит вопросы и ответы помощника и ответит в разделе «Техподдержка».")
        }
        .alert(vm.handedTo ?? "", isPresented: handedBinding) {
            Button("Открыть Техподдержку") { dismiss() }
        } message: {
            Text("Ответ сотрудника придёт в чат техподдержки.")
        }
    }

    private var handedBinding: Binding<Bool> {
        Binding(get: { vm.handedTo != nil }, set: { if !$0 { vm.handedTo = nil } })
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if vm.enabled && !vm.messages.isEmpty {
                Button {
                    vm.newChat()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(vm.sending || vm.handing)
                .accessibilityLabel("Новый разговор")
            }
        }
    }

    /// Только http(s): SFSafariViewController другие схемы не открывает.
    private func openLink(_ url: URL) {
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "https" || scheme == "http" else { return }
        link = PayLink(url: url)
    }
}

// ── Под заголовком: отвечает ИИ; переписка передана ──────────────────────────
struct AssistantHeaderNote: View {
    @ObservedObject var vm: AssistantViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(disclaimer)
                .font(.caption2)
                .foregroundColor(Brand.muted)
            if vm.handed {
                Label("Переписка передана в Техподдержку — ответ придёт там.", systemImage: "person.badge.clock")
                    .font(.caption)
                    .foregroundColor(Brand.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Brand.card)
    }

    private var disclaimer: String {
        let d = (vm.status?.disclaimer ?? "").trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? "Отвечает ИИ — может ошибаться" : d
    }
}

// ── Лента ────────────────────────────────────────────────────────────────────
struct AssistantMessageList: View {
    @ObservedObject var vm: AssistantViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    content
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.messages.count) { _ in scrollDown(proxy) }
            .onChange(of: vm.sending) { _ in scrollDown(proxy) }
        }
        .overlay { overlay }
    }

    @ViewBuilder
    private var content: some View {
        if vm.state == .loaded && vm.enabled {
            if vm.messages.isEmpty && !vm.sending {
                AssistantWelcome(vm: vm)
            } else {
                ForEach(vm.messages) { m in
                    if m.isUser {
                        AssistantUserBubble(text: m.text)
                    } else {
                        AssistantBotBubble(message: m, busy: vm.ratingIds.contains(m.id),
                                           onRate: { r in Task { await vm.rate(m, r) } })
                    }
                }
                if vm.sending { AssistantTyping() }
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch vm.state {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed(let msg):
            ErrorBanner(message: msg, retry: { Task { await vm.load() } })
        case .loaded:
            if !vm.enabled {
                EmptyState(icon: "sparkles",
                           title: vm.status?.loginRequired == true
                               ? "Войдите в аккаунт, чтобы задать вопрос помощнику."
                               : "Помощник сейчас выключен.",
                           subtitle: "Напишите в Техподдержку — ответит человек.")
            }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        // После вставки строк LazyVStack ещё не разложен — прокручиваем следующим тактом.
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

// ── Пустой чат: приветствие и подсказки ──────────────────────────────────────
struct AssistantWelcome: View {
    @ObservedObject var vm: AssistantViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssistantBotBubble(message: AssistantMessage(id: 0, role: "assistant", text: greeting),
                               busy: true, onRate: { _ in })
            ForEach(Array((vm.status?.suggestions ?? []).enumerated()), id: \.offset) { _, q in
                Button {
                    Task { await vm.send(q) }
                } label: {
                    Text(q)
                        .font(.subheadline)
                        .foregroundColor(Brand.text)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(Brand.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var greeting: String {
        let g = (vm.status?.greeting ?? "").trimmingCharacters(in: .whitespaces)
        return (g.isEmpty ? "Здравствуйте! Я помощник Yumurta." : g) + "\n\nСпросите своими словами — например:"
    }
}

// ── Пузыри ───────────────────────────────────────────────────────────────────
struct AssistantUserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.white)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Brand.accent)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Вы: " + text)
        }
    }
}

struct AssistantTyping: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Помощник печатает…")
                .font(.footnote)
                .foregroundColor(Brand.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Ответ помощника: markdown-блоки, «Источники:», 👍/👎 (у ответов с id).
struct AssistantBotBubble: View {
    let message: AssistantMessage
    let busy: Bool
    let onRate: (Int) -> Void
    @Environment(\.openURL) private var openURL

    // Разбор markdown и источников — один раз при создании пузыря, а не на каждой
    // перерисовке (раньше вычисляемые свойства гоняли разбор на главном потоке).
    private let blocks: [AsstBlock]
    private let sources: [AsstSourceLink]

    init(message: AssistantMessage, busy: Bool, onRate: @escaping (Int) -> Void) {
        self.message = message
        self.busy = busy
        self.onRate = onRate
        self.blocks = AssistantText.parse(message.text, base: API.base)
        self.sources = AssistantText.sources(message.sources, base: API.base)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                textPart
                if message.id > 0 { rateRow }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 32)
        }
    }

    /// VoiceOver: весь ответ одной фразой «Помощник: …», ссылки — действиями.
    private var textPart: some View {
        let b = blocks
        let src = sources
        let links = b.flatMap { $0.spans.filter { $0.url != nil } } + src.map { AsstSpan(text: $0.title, url: $0.url) }
        let spoken = "Помощник: " + AssistantText.plainText(b)
            + (src.isEmpty ? "" : "\nИсточники: " + src.map(\.title).joined(separator: ", "))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(b.enumerated()), id: \.offset) { _, block in
                AssistantBlockView(block: block)
            }
            if !src.isEmpty { sourcesLine(src) }
        }
        .tint(Brand.accent)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
        .accessibilityActions {
            ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                Button("Открыть ссылку: " + l.text) {
                    if let u = l.url, let url = URL(string: u) { openURL(url) }
                }
            }
        }
    }

    private func sourcesLine(_ src: [AsstSourceLink]) -> some View {
        var t = Text("Источники: ").foregroundColor(Brand.muted)
        for (i, s) in src.enumerated() {
            if i > 0 { t = t + Text(", ").foregroundColor(Brand.muted) }
            t = t + Text(AssistantText.piece(AsstSpan(text: s.title, url: s.url))).underline()
        }
        return t.font(.caption)
    }

    private var rateRow: some View {
        HStack(spacing: 14) {
            rateButton(1, on: message.rating == 1, icon: "hand.thumbsup", label: "Помогло")
            rateButton(-1, on: message.rating == -1, icon: "hand.thumbsdown", label: "Не помогло")
        }
        .padding(.top, 2)
    }

    private func rateButton(_ r: Int, on: Bool, icon: String, label: String) -> some View {
        Button {
            onRate(r)
        } label: {
            Image(systemName: on ? icon + ".fill" : icon)
                .font(.subheadline)
                .foregroundColor(on ? Brand.accent : Brand.muted)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .accessibilityLabel(on ? label + ", отмечено" : label)
    }
}

/// Абзац или пункт списка ответа.
struct AssistantBlockView: View {
    let block: AsstBlock

    var body: some View {
        switch block {
        case .para(let spans, let heading):
            AssistantRich.text(spans)
                .font(heading ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)
        case .item(let marker, let spans):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
                AssistantRich.text(spans)
                    .font(.subheadline)
                    .foregroundColor(Brand.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Куски → один Text: жирный/курсив/код — модификаторами Text, ссылки — .link
/// в AttributedString (нажимаются, открытие — через openURL экрана).
enum AssistantRich {
    static func text(_ spans: [AsstSpan]) -> Text {
        spans.reduce(Text(verbatim: "")) { acc, s in
            var t = Text(AssistantText.piece(s))
            if s.bold { t = t.bold() }
            if s.italic { t = t.italic() }
            if s.code { t = t.font(.system(.subheadline, design: .monospaced)) }
            if s.url != nil { t = t.underline() }
            return acc + t
        }
    }
}

// ── Поле ввода ───────────────────────────────────────────────────────────────
struct AssistantComposer: View {
    @ObservedObject var vm: AssistantViewModel
    let onHandoff: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            errorRow
            infoRow
            metaRow
            counter
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Brand.card)
    }

    /// 502/504 — вопрос уже сохранён: «Позвать человека» (повтора нет, как на сайте);
    /// прочие отказы — текст сервера.
    @ViewBuilder
    private var errorRow: some View {
        if let err = vm.sendError {
            HStack(alignment: .top, spacing: 8) {
                Text(err)
                    .font(.caption)
                    .foregroundColor(Brand.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if vm.noAnswer && vm.status?.canHandoff == true && vm.chatId != nil {
                    Button("Позвать человека", action: onHandoff)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Brand.accent)
                        .disabled(vm.sending || vm.handing)
                }
            }
        }
    }

    @ViewBuilder
    private var infoRow: some View {
        if let info = vm.info {
            Text(info)
                .font(.caption)
                .foregroundColor(Brand.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// «Осталось вопросов сегодня: N» (если мало) и «Позвать человека».
    private var metaRow: some View {
        HStack(spacing: 8) {
            Text(AssistantText.leftNote(vm.leftToday) ?? "")
                .font(.caption2)
                .foregroundColor(Brand.muted)
            Spacer()
            if vm.status?.canHandoff == true {
                Button(action: onHandoff) {
                    HStack(spacing: 4) {
                        if vm.handing { ProgressView().controlSize(.small) }
                        Label("Позвать человека", systemImage: "person.wave.2")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Brand.accent)
                }
                .buttonStyle(.plain)
                .disabled(vm.handing || vm.sending)
            }
        }
    }

    /// Счётчик — ближе к пределу сервера (max_length, 2000 знаков).
    @ViewBuilder
    private var counter: some View {
        let n = vm.draft.count
        if n >= vm.maxLength - 200 {
            Text("\(n) / \(vm.maxLength)")
                .font(.caption)
                .foregroundColor(n > vm.maxLength ? Brand.red : Brand.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Напишите вопрос…", text: $vm.draft, axis: .vertical)
                .lineLimit(1...6)
                .padding(10)
                .background(Brand.chip)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            sendButton
        }
    }

    private var sendButton: some View {
        Button {
            Task { await vm.sendDraft() }
        } label: {
            sendIcon
        }
        .disabled(!vm.canSend || vm.draft.count > vm.maxLength)
        .accessibilityLabel("Отправить")
    }

    @ViewBuilder
    private var sendIcon: some View {
        if vm.sending {
            ProgressView()
                .frame(width: 30, height: 30)
        } else {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(vm.canSend ? Brand.accent : Brand.muted)
        }
    }
}

// ── Кнопка «Спросить помощника» в «Техподдержке» ────────────────────────────
struct AssistantEntryRow: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundColor(Brand.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Спросить помощника")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.text)
                    Text("ИИ ответит сразу по базе знаний")
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(Brand.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Brand.card)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }
}
