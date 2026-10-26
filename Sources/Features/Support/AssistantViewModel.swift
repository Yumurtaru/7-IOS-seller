import Foundation
import SwiftUI

// ============================================================================
//  «Помощник Yumurta» — ИИ-ассистент поддержки (сайт, волна А100; веб-образец —
//  assets/js/assistant.js). Вход: «Ещё» → «Техподдержка» → «Спросить
//  помощника». Кнопка есть, только если status ответил enabled = true (старый
//  сервер — 404, кнопки нет, всё как раньше). «Позвать человека» кладёт
//  переписку сообщением в «Техподдержку» организации (shop_support).
// ============================================================================

/// Есть ли помощник для выбранной организации: спрашиваем при открытии
/// «Техподдержки». Любая ошибка (404 старого сервера, нет сети) — кнопки нет.
/// Сервер посчитал нас не организацией (audience ≠ seller) — тоже нет: «Позвать
/// человека» ушло бы обращением покупателя, которого в приложении продавца не видно.
/// Не @MainActor целиком (как PoolFeature): экраны берут его через
/// @ObservedObject … = .shared в свойствах; состояние меняется в методах @MainActor.
final class AssistantFeature: ObservableObject {
    static let shared = AssistantFeature()
    @Published private(set) var available = false

    private var key: String?
    private var gen = 0

    private init() {}

    @MainActor
    func refresh(shopId: Int?) async {
        let k = "\(Session.shared.user?.id ?? 0):\(shopId ?? 0)"
        // Другой магазин/аккаунт — прежний ответ не показываем, пока не придёт новый.
        if k != key { available = false; key = k }
        gen += 1
        let g = gen
        let s = try? await API.shared.assistantStatus()
        guard g == gen, k == key else { return }
        available = s.map { $0.enabled && $0.audience == AssistantText.audience } ?? false
    }
}

/// id переписки текущего аккаунта и организации (живёт между запусками).
enum AssistantStore {
    @MainActor private static func key(_ shopId: Int?) -> String {
        AssistantText.storeKey(userId: Session.shared.user?.id, shopId: shopId)
    }

    @MainActor static func get(_ shopId: Int?) -> String? {
        let v = UserDefaults.standard.string(forKey: key(shopId))
        return AssistantText.isChatId(v) ? v : nil
    }

    @MainActor static func set(_ shopId: Int?, _ id: String?) {
        if let id { UserDefaults.standard.set(id, forKey: key(shopId)) }
        else { UserDefaults.standard.removeObject(forKey: key(shopId)) }
    }
}

@MainActor
final class AssistantViewModel: ObservableObject {
    @Published private(set) var state: LoadState = .idle
    @Published private(set) var status: AssistantStatus?
    @Published private(set) var messages: [AssistantMessage] = []
    @Published private(set) var chatId: String?
    /// Переписка уже передана в «Техподдержку».
    @Published private(set) var handed = false
    @Published private(set) var sending = false
    @Published private(set) var sendError: String?
    /// 502/504: модель не ответила, вопрос сохранён — рядом с ошибкой «Позвать человека».
    @Published private(set) var noAnswer = false
    @Published private(set) var leftToday: Int?
    @Published private(set) var handing = false
    /// Оценка уходит на сервер — кнопки этого ответа заблокированы.
    @Published private(set) var ratingIds: Set<Int> = []
    /// Короткая подсказка под лентой («Спасибо, учтём…», ошибка оценки).
    @Published var info: String?
    /// Передали в «Техподдержку»: экран показывает текст и уходит в чат.
    @Published var handedTo: String?
    @Published var draft = ""

    private var shopId: Int?
    // Поколение: после смены магазина или «Нового разговора» поздние ответы отбрасываем.
    private var gen = 0
    private var localSeq = 0

    var enabled: Bool { status?.enabled == true }
    var maxLength: Int { (status?.maxLength ?? 0) > 0 ? (status?.maxLength ?? AssistantText.defaultMax) : AssistantText.defaultMax }
    var title: String {
        let n = (status?.name ?? "").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Помощник Yumurta" : n
    }
    var canSend: Bool {
        enabled && !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// .task экрана: первая загрузка (или повтор после ошибки/отмены).
    func start() async {
        if state == .loaded && shopId == Session.shared.activeShopId { return }
        await load()
    }

    func load() async {
        gen += 1
        let g = gen
        shopId = Session.shared.activeShopId
        state = .loading
        messages = []; chatId = nil; handed = false; sendError = nil; noAnswer = false
        info = nil; ratingIds = []; sending = false; handing = false
        do {
            let s = try await API.shared.assistantStatus()
            guard g == gen else { return }
            status = s
            leftToday = s.leftToday
            if s.enabled, let id = AssistantStore.get(shopId) {
                do {
                    let h = try await API.shared.assistantChat(id: id)
                    guard g == gen else { return }
                    messages = h.messages
                    handed = h.status == "handed"
                    chatId = id
                } catch let e as AssistantError where e.status == 404 {
                    // Переписку удалили по сроку хранения или она другой организации — начинаем новую.
                    guard g == gen else { return }
                    AssistantStore.set(shopId, nil)
                }
            }
            state = .loaded
        } catch {
            guard g == gen else { return }
            state = .failed(error.localizedDescription)
        }
    }

    /// «Отправить»: поле очищается сразу; не принятый вопрос возвращается в поле.
    func sendDraft() async {
        let q = draft
        guard canSend else { return }
        draft = ""
        await send(q)
    }

    func send(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled, !sending, !q.isEmpty else { return }
        if q.count > maxLength {
            sendError = "Вопрос длиннее \(maxLength) символов — сократите"
            restore(q)
            return
        }
        let g = gen
        localSeq -= 1
        let local = AssistantMessage(id: localSeq, role: "user", text: q)
        messages.append(local)
        sending = true; sendError = nil; noAnswer = false; info = nil
        do {
            let r = try await API.shared.assistantAsk(text: q, chatId: chatId)
            guard g == gen else { return }
            if let id = r.chatId, AssistantText.isChatId(id) { chatId = id }
            AssistantStore.set(shopId, chatId)
            messages = AssistantText.appendAnswer(messages, localId: local.id, [r.question, r.reply].compactMap { $0 })
            leftToday = r.leftToday
            sending = false
        } catch let e as AssistantError {
            guard g == gen else { return }
            sending = false
            if let c = e.chatId { chatId = c }
            if e.status == 404 { chatId = nil }   // «Переписка не найдена — начните новую»
            AssistantStore.set(shopId, chatId)
            // 502 с перепиской: вопрос сохранён на сервере — остаётся на экране.
            let keep = AssistantText.isNoAnswer(e.status) && chatId != nil
            if !keep {
                messages.removeAll { $0.id == local.id }
                restore(q)
            }
            sendError = AssistantText.errorText(status: e.status, message: e.message)
            noAnswer = keep
            // Поле остаётся пустым (вопрос уже в переписке); показываем то, что на сервере.
            if keep, let c = chatId { await reloadAfterNoAnswer(c, g) }
        } catch {
            guard g == gen else { return }
            sending = false
            messages.removeAll { $0.id == local.id }
            restore(q)
            sendError = error.localizedDescription
        }
    }

    /// После 502/504: перечитать переписку — сохранённый вопрос получит настоящий id.
    /// Не вышло (нет сети) — временный пузырь остаётся на экране как есть. Если
    /// человек уже отправил следующий вопрос, ответ отправки сам расставит всё.
    private func reloadAfterNoAnswer(_ chat: String, _ g: Int) async {
        guard let h = try? await API.shared.assistantChat(id: chat) else { return }
        guard g == gen, !sending, chatId == chat, !h.messages.isEmpty else { return }
        messages = h.messages
        handed = h.status == "handed"
    }

    private func restore(_ q: String) {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = q }
    }

    func newChat() {
        guard !sending, !handing else { return }
        gen += 1
        AssistantStore.set(shopId, nil)
        messages = []; chatId = nil; handed = false; sendError = nil; noAnswer = false; info = nil; ratingIds = []
    }

    func rate(_ m: AssistantMessage, _ tapped: Int) async {
        guard let chat = chatId, m.id > 0, !ratingIds.contains(m.id) else { return }
        let nr = AssistantText.nextRating(current: m.rating, tapped: tapped)
        let g = gen
        ratingIds.insert(m.id)
        do {
            let r = try await API.shared.assistantRate(chatId: chat, messageId: m.id, rating: nr)
            guard g == gen else { return }
            ratingIds.remove(m.id)
            if let i = messages.firstIndex(where: { $0.id == m.id }) { messages[i].rating = r.rating }
            if nr == -1 { info = "Спасибо, учтём. Если вопрос не решён — нажмите «Позвать человека»." }
        } catch {
            guard g == gen else { return }
            ratingIds.remove(m.id)
            info = error.localizedDescription
        }
    }

    func handoff() async {
        guard !handing, !sending else { return }
        guard let chat = chatId else {
            info = "Сначала опишите вопрос — переписку передадим сотруднику вместе с ним."
            return
        }
        let g = gen
        handing = true
        do {
            let r = try await API.shared.assistantHandoff(chatId: chat)
            guard g == gen else { return }
            handing = false
            handed = true
            if r.kind == "ticket" {
                // Сервер посчитал нас покупателем — обращение в поддержку сайта.
                info = "Обращение №\(r.id) создано — ответим в «Поддержке» на сайте"
            } else {
                handedTo = r.already ? "Уже передано" : "Передали в Техподдержку"
            }
        } catch {
            guard g == gen else { return }
            handing = false
            info = error.localizedDescription
        }
    }
}
