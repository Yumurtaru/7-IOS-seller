import SwiftUI

// ============================================================================
//  Настройки магазина — GET /api/seller/settings (shop + notifications):
//   • основные POST /settings/main (name/description/address/phone/email/inn/org_type)
//   • лого/баннер POST /settings/logo (multipart, имя поля выбирает колонку)
//   • статус active/paused POST /settings/status (большой тумблер)
//   • окно возвратов POST /settings/returns (1–72 ч)
//   • уведомления Telegram POST /settings/notifications
//   • АZ: Telegram одной кнопкой (GET /settings/telegram, POST /settings/telegram/link) и
//     пауза приёма на время (окно «Пауза приёма заказов» — ShopPauseControl.swift)
//   • оплата и часы работы — отдельные экраны (PaymentSettingsView, HoursSettingsView)
// ============================================================================

@MainActor
final class ShopSettingsViewModel: ObservableObject {
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var success: String?
    /// Сохранение в пути. Кнопки не гасли, и второе нажатие (или новый логотип
    /// поверх ещё не загруженного) слало второй запрос, а логотип грузился
    /// секундами без единого признака — его выбирали ещё раз.
    @Published var saving = false
    @Published var uploadingLogo = false

    @Published var name = ""
    @Published var descriptionText = ""
    @Published var address = ""
    @Published var phone = ""
    @Published var email = ""
    @Published var inn = ""
    @Published var orgType = "ip"
    @Published var logoPath: String?
    @Published var returnWindowHours = 24
    @Published var telegramChatId = ""
    /// Чат Telegram, как его отдал сервер: сотрудник (не владелец) шлёт его же —
    /// менять чат может только владелец (А116), прежнее значение сервер принимает.
    private var loadedChatId = ""
    @Published var tgEvents: Set<String> = []

    // ── АZ (сайт А617): Telegram одной кнопкой ───────────────────────────────
    /// Состояние подключения с сервера. nil — блока нет (старый сервер, 404/405 или любая ошибка):
    /// остаётся только ручное поле chat_id.
    @Published var tg: TelegramState?
    /// Выданный код и ссылки на бота; пока он не nil — идёт опрос подключения.
    @Published var tgLink: TelegramLink?
    @Published var tgLinkBusy = false
    @Published var tgNotice: String?
    @Published var tgError: String?
    /// До какого момента ждём подтверждения от бота (10 минут от выдачи кода).
    private var tgDeadline: Date?
    /// chat_id на сервере до выдачи кода: подключённым считаем только ДРУГОЙ непустой чат.
    private var tgChatBefore = ""
    /// Основные поля в том виде, в каком их отдал сервер (см. saveMain).
    private var loadedMain: [String: String] = [:]

    /// События Telegram-уведомлений — как в веб-настройках.
    static let tgEventOptions: [(String, String)] = [
        ("new_order", "Новый заказ"), ("new_review", "Новый отзыв"),
        ("new_return", "Новый возврат"), ("low_balance", "Низкий баланс"),
        // Эти два ключа сервер тоже читает (бронь стола — routes/tables.php,
        // «курьер не смог доставить» — api_v1), а включить их отсюда было нельзя.
        ("reservation", "Бронь стола"), ("order_returned", "Курьер вернул заказ"),
    ]

    /// П-27.9: галочки событий — по notifications.events_available сервера;
    /// старый сервер списка не шлёт — прежний список выше.
    @Published var eventOptions: [(String, String)] = ShopSettingsViewModel.tgEventOptions

    /// П-27.6: поля, которые сервер умеет очищать списком clear (название — нет).
    private static let clearableMain: Set<String> = ["description", "address", "phone", "email", "inn"]

    func load() async {
        state = .loading
        let statusGenBefore = Session.shared.statusGeneration
        do {
            let res = try await API.shared.settings()
            if let shop = res.shop {
                name = shop.name ?? ""
                descriptionText = shop.description ?? ""
                address = shop.address ?? ""
                phone = shop.phone ?? ""
                email = shop.email ?? ""
                inn = shop.inn ?? ""
                orgType = shop.orgType ?? "ip"
                logoPath = shop.logo
                returnWindowHours = shop.returnWindowHours ?? 24
                loadedMain = mainValues()
            }
            if let n = res.notifications {
                telegramChatId = n.telegramChatId ?? ""
                loadedChatId = telegramChatId
                tgEvents = Set(n.events ?? [])
                // Сохранённые ключи, которых нет в списке (low_stock), не теряются:
                // tgEvents уходит при сохранении целиком.
                eventOptions = n.eventsAvailable?.map { ($0.key, $0.label) } ?? Self.tgEventOptions
            }
            // АZ: ключ pause в ответе — сервер умеет паузу на время (нет ключа — старый сервер).
            Session.shared.applyPause(res.pause, ifGen: statusGenBefore)
            state = .loaded
            await loadTelegram()
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Поля формы прочитаны с сервера. Пока нет (загрузка идёт или упала) — в
    /// них пусто, и «Сохранить основные» стирало название, адрес и телефон
    /// магазина, а «Сохранить уведомления» — chat_id и события.
    var canSaveFields: Bool { state == .loaded }

    /// Текущие значения основных полей: ключ API → значение.
    private func mainValues() -> [String: String] {
        ["name": name, "description": descriptionText, "address": address,
         "phone": phone, "email": email, "inn": inn]
    }

    func saveMain() async {
        guard canSaveFields else { return }
        // Пустое поле сервер не сохраняет — оставляет прежнее значение
        // (seller_settings.php, settings/main: array_filter по null). Раньше
        // «Сохранено» показывалось и над стёртым полем, а после перезахода
        // старое значение возвращалось. Говорим об этом и возвращаем его в форму.
        let labels = ["name": "Название", "description": "Описание", "address": "Адрес",
                      "phone": "Телефон", "email": "Email", "inn": "ИНН"]
        let now = mainValues()
        let order = ["name", "description", "address", "phone", "email", "inn"]
        let cleared = order.filter { key in
            let v = (now[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty && !(loadedMain[key] ?? "").isEmpty
        }
        let before = loadedMain
        // П-27.6: стёртые поля (кроме названия) уходят списком clear — новый
        // сервер их очищает и отвечает cleared:[…]. Старый сервер cleared не
        // шлёт и пустое не очищает — тогда, как раньше, возвращаем прежние значения.
        var kept: [String] = []
        await run("Основные настройки сохранены") {
            var fields: [String: Any?] = [
                "name": self.name, "description": self.descriptionText,
                "address": self.address, "phone": self.phone,
                "email": self.email, "inn": self.inn, "org_type": self.orgType,
            ]
            let toClear = cleared.filter { Self.clearableMain.contains($0) }
            if !toClear.isEmpty { fields["clear"] = toClear }
            let res = try await API.shared.saveSettingsMain(fields: fields)
            let done = Set(res ?? [])
            kept = cleared.filter { !done.contains($0) }
            for key in kept { self.restoreMain(key, before[key] ?? "") }
            self.loadedMain = self.mainValues()
        }
        if success != nil && !kept.isEmpty {
            let names = kept.compactMap { labels[$0] }.map { "«\($0)»" }.joined(separator: ", ")
            success = "Сохранено. Пустые поля " + names + " сервер не очищает — оставлены прежние значения"
        }
    }

    /// Вернуть в форму значение, которое осталось на сервере.
    private func restoreMain(_ key: String, _ value: String) {
        switch key {
        case "name": name = value
        case "description": descriptionText = value
        case "address": address = value
        case "phone": phone = value
        case "email": email = value
        case "inn": inn = value
        default: break
        }
    }

    /// banner = true — баннер витрины (паритет с Android: там можно загрузить и
    /// логотип, и баннер; ручка та же, поле выбирает колонку на сервере).
    func uploadLogo(_ image: UIImage, banner: Bool = false) async {
        guard !uploadingLogo, !saving else { return }
        uploadingLogo = true
        defer { uploadingLogo = false }
        let side: CGFloat = banner ? 1600 : 1000
        // Сжатие — не на главном потоке: иначе экран подвисал на полсекунды.
        guard let jpeg = await Task.detached(operation: { ImageCompressor.jpegForUpload(image, maxSide: side) }).value else {
            // Раньше — молча: логотип просто не менялся.
            error = "Не удалось подготовить изображение — выберите другое"
            return
        }
        await run(banner ? "Баннер обновлён" : "Логотип обновлён") {
            let ack = try await API.shared.uploadShopImage(jpeg: jpeg, banner: banner)
            if !banner, let p = ack.logo { self.logoPath = p }
        }
    }

    func saveReturns() async {
        guard canSaveFields else { return }
        await run("Окно возвратов сохранено") {
            try await API.shared.saveReturnWindow(hours: self.returnWindowHours)
        }
    }

    /// АZ: GET /settings/telegram. Любая ошибка или ответ без ключа enabled — нового блока нет.
    func loadTelegram() async {
        do {
            let t = try await API.shared.telegramState()
            if Task.isCancelled { return }
            tg = t.known ? t : nil
        } catch is CancellationError {
        } catch {
            tg = nil
        }
    }

    /// АZ: «Подключить Telegram» — POST /settings/telegram/link, дальше экран опрашивает подключение.
    func startTelegramLink() async {
        guard !tgLinkBusy else { return }   // двойной тап — один запрос
        tgLinkBusy = true
        defer { tgLinkBusy = false }
        tgError = nil
        tgNotice = nil
        do {
            let link = try await API.shared.telegramLink()
            guard let url = link.url, !url.isEmpty else {
                tgError = APIError.decoding.localizedDescription
                return
            }
            tgChatBefore = (tg?.chatId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // Код живёт 10 минут: ждём не дольше, чем сказал сервер, и не дольше десяти.
            let ttl = min(max(link.ttl ?? 600, 60), 600)
            tgDeadline = Date().addingTimeInterval(TimeInterval(ttl))
            tgLink = link
        } catch is CancellationError {
        } catch {
            tgError = error.localizedDescription   // 403 / 429 / 503 — текст сервера
        }
    }

    /// Один шаг опроса (раз в 3 с, пока экран на виду). false — опрос закончен.
    func pollTelegram() async -> Bool {
        guard tgLink != nil, let deadline = tgDeadline else { return false }
        if Date() >= deadline {
            tgLink = nil
            tgDeadline = nil
            tgNotice = nil
            tgError = "Время кода вышло — нажмите кнопку ещё раз."
            return false
        }
        do {
            let t = try await API.shared.telegramState()
            guard tgLink != nil else { return false }   // закрыли, пока ждали ответ
            let chat = (t.chatId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.known && !chat.isEmpty && chat != tgChatBefore {
                tg = t
                // КРИТИЧНО: новый чат — и в поле формы, и в «загруженное» значение. Иначе следующее
                // «Сохранить уведомления» (telegramChatId для владельца, loadedChatId для остальных)
                // отправило бы на сервер СТАРЫЙ chat_id и перетёрло подключённый чат.
                telegramChatId = chat
                loadedChatId = chat
                tgLink = nil
                tgDeadline = nil
                tgError = nil
                tgNotice = "Telegram подключён"
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            // Сбой сети на одном шаге — не конец: следующий опрос через 3 с.
        }
        return true
    }

    func saveNotifications() async {
        guard canSaveFields else { return }
        await run("Настройки уведомлений сохранены") {
            try await API.shared.saveNotificationSettings(
                telegramChatId: Session.shared.isOwner
                    ? self.telegramChatId.trimmingCharacters(in: .whitespaces) : self.loadedChatId,
                events: Array(self.tgEvents)
            )
        }
    }

    private func run(_ successText: String, _ op: @escaping () async throws -> Void) async {
        guard !saving else { return }   // двойное нажатие — один запрос
        saving = true
        defer { saving = false }
        error = nil
        success = nil
        do {
            try await op()
            success = successText
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ShopSettingsView: View {
    @EnvironmentObject var session: Session
    @StateObject private var vm = ShopSettingsViewModel()
    @State private var showPhotoPicker = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    /// Что выбираем в галерее: логотип или баннер.
    @State private var pickBanner = false

    var body: some View {
        Form {
            statusSection
            logoSection
            mainSection
            Section {
                NavigationLink { PaymentSettingsView() } label: {
                    Label("Способы оплаты", systemImage: "creditcard")
                }
                NavigationLink { HoursSettingsView() } label: {
                    Label("Часы работы", systemImage: "clock")
                }
            } header: { Text("Приём заказов") }
            .listRowBackground(Brand.card)
            returnsSection
            notificationsSection
            feedbackSection
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Настройки магазина")
        .navigationBarTitleDisplayMode(.inline)
        .listState(vm.state, isEmpty: vm.state != .loaded,
                   emptyIcon: "gearshape", emptyTitle: "Загрузка…",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPicker { image in
                let banner = pickBanner
                Task { await vm.uploadLogo(image, banner: banner) }
            }
        }
        // Отказ сервера показывался только строкой в самом низу длинной формы:
        // после «Сохранить основные» её не видно, и казалось, что всё сохранилось.
        .errorAlert($vm.error)
        // Только первая загрузка (или повтор после ошибки): .task срабатывает
        // при каждом возврате на экран (из «Часов работы», с другой вкладки) и
        // затирал несохранённые правки данными сервера.
        // АZ: пока выдан код Telegram, экран на виду и приложение активно — раз в 3 секунды
        // спрашиваем сервер, подключился ли чат (не дольше 10 минут от выдачи кода).
        .task(id: pollActive) {
            guard pollActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                if await vm.pollTelegram() == false { break }
            }
        }
        .task {
            // Пропускаем, только если загрузка ЗАВЕРШИЛАСЬ: ушли с экрана посреди
            // первой загрузки — она отменилась, состояние осталось .loading, и
            // экран висел со спиннером навсегда.
            if vm.state != .loaded { await vm.load() }
        }
    }

    private var pollActive: Bool { vm.tgLink != nil && scenePhase == .active }

    // ── Статус (большой тумблер) ─────────────────────────────────────────────
    private var statusSection: some View {
        Section {
            // Черновик и организация на проверке ещё не опубликованы: паузу и
            // возобновление сервер для них запрещает (seller_settings.php,
            // settings/status → 422), а тумблер показывал «на паузе» и падал.
            // Паритет с Android: «на проверке» (pending) и «заблокирована» (blocked)
            // тоже не переключаются — сервер меняет статус только у active|paused,
            // а тумблер подписывал их «на паузе» и падал с отказом.
            if session.shopStatus != "active" && session.shopStatus != "paused" {
                VStack(alignment: .leading, spacing: 2) {
                    Text(unpublishedTitle).font(.headline)
                    Text(unpublishedHint)
                        .font(.caption).foregroundColor(Brand.muted)
                }
            } else {
            // АZ: тумблер и окно «Пауза приёма заказов» — общий компонент (ShopPauseControl.swift).
            ShopStatusControl(titleFont: .headline)
            }
        }
        .listRowBackground(Brand.card)
    }

    private var unpublishedTitle: String {
        switch session.shopStatus {
        case "review", "pending": return "Организация на проверке"
        case "blocked": return "Заблокирована площадкой"
        default: return "Организация ещё не опубликована"
        }
    }

    /// Что делать дальше. Чек-лист и «Отправить на проверку» теперь на
    /// «Дашборде» (publish-status) — раньше отправляли в кабинет на сайте.
    private var unpublishedHint: String {
        switch session.shopStatus {
        case "blocked": return "Клиенты её сейчас не видят. Причину уточните у поддержки площадки."
        case "review", "pending": return "Клиенты её пока не видят — ждём решения администратора площадки."
        default: return "Клиенты её пока не видят. Что заполнить и кнопка «Отправить на проверку» — на «Дашборде»."
        }
    }

    // ── Логотип ──────────────────────────────────────────────────────────────
    private var logoSection: some View {
        Section("Логотип и баннер") {
            HStack(spacing: 14) {
                RemoteImage(path: vm.logoPath, size: 64, cornerRadius: 12,
                            placeholderIcon: "building.2")
                Button("Загрузить новый") { pickBanner = false; showPhotoPicker = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.accent)
                    .disabled(vm.uploadingLogo || vm.saving)
                if vm.uploadingLogo { ProgressView() }
            }
            // Паритет с Android: баннер витрины тоже загружается с телефона.
            Button("Загрузить баннер") { pickBanner = true; showPhotoPicker = true }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.accent)
                .disabled(vm.uploadingLogo || vm.saving)
        }
        .listRowBackground(Brand.card)
    }

    // ── Основные ─────────────────────────────────────────────────────────────
    private var mainSection: some View {
        Section("Основные") {
            TextField("Название", text: $vm.name)
            TextField("Описание", text: $vm.descriptionText, axis: .vertical).lineLimit(2...4)
            TextField("Адрес", text: $vm.address)
            TextField("Телефон", text: $vm.phone.phoneInput).keyboardType(.phonePad)
            TextField("Email", text: $vm.email)
                .keyboardType(.emailAddress).textInputAutocapitalization(.never)
            TextField("ИНН", text: $vm.inn).keyboardType(.numberPad)
            Picker("Форма организации", selection: $vm.orgType) {
                Text("ИП").tag("ip")
                Text("ООО").tag("ooo")
                Text("Самозанятый").tag("self_employed")
            }
            Button("Сохранить основные") { Task { await vm.saveMain() } }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.accent)
                .disabled(!vm.canSaveFields || vm.saving || vm.uploadingLogo)
        }
        .listRowBackground(Brand.card)
    }

    // ── Возвраты ─────────────────────────────────────────────────────────────
    private var returnsSection: some View {
        Section {
            Stepper("Окно возвратов: \(vm.returnWindowHours) ч", value: $vm.returnWindowHours, in: 1...72)
            Button("Сохранить окно возвратов") { Task { await vm.saveReturns() } }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.accent)
                .disabled(!vm.canSaveFields || vm.saving || vm.uploadingLogo)
        } header: {
            Text("Возвраты")
        } footer: {
            Text("Сколько часов после получения заказа клиент может оформить возврат (1–72).")
        }
        .listRowBackground(Brand.card)
    }

    // ── Telegram-уведомления ─────────────────────────────────────────────────
    private var notificationsSection: some View {
        Section {
            // АZ: «Подключить Telegram» одной кнопкой — только если сервер ответил на GET /settings/telegram.
            if let t = vm.tg { telegramBlock(t) }
            TextField("Telegram chat_id", text: $vm.telegramChatId)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .disabled(!Session.shared.isOwner)
            // П-27.9: список событий — с сервера (events_available), иначе прежний.
            ForEach(vm.eventOptions, id: \.0) { key, title in
                Toggle(title, isOn: Binding(
                    get: { vm.tgEvents.contains(key) },
                    set: { on in if on { vm.tgEvents.insert(key) } else { vm.tgEvents.remove(key) } }
                ))
                .tint(Brand.accent)
            }
            Button("Сохранить уведомления") { Task { await vm.saveNotifications() } }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Brand.accent)
                .disabled(!vm.canSaveFields || vm.saving || vm.uploadingLogo)
        } header: {
            Text("Уведомления в Telegram")
        } footer: {
            Text("chat_id вашего Telegram-аккаунта или группы для событий магазина."
                 + (Session.shared.isOwner ? "" : " Чат Telegram для уведомлений меняет только владелец организации."))
        }
        .listRowBackground(Brand.card)
    }

    // ── АZ: Telegram одной кнопкой ───────────────────────────────────────────
    private func telegramBlock(_ t: TelegramState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Az.telegramStatus(t), systemImage: t.connected ? "checkmark.circle.fill" : "paperplane")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(t.connected ? Brand.green : Brand.text)
            if !t.enabled {
                Text("Бот площадки сейчас не настроен — укажите chat_id вручную ниже.")
                    .font(.caption).foregroundColor(Brand.muted)
            } else if !t.canLink {
                Text("Подключить чат может владелец организации.")
                    .font(.caption).foregroundColor(Brand.muted)
            } else {
                Button {
                    Task { await vm.startTelegramLink() }
                } label: {
                    HStack(spacing: 6) {
                        if vm.tgLinkBusy { ProgressView().controlSize(.small) }
                        Text(t.connected ? "Подключить другой чат" : "Подключить Telegram")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .disabled(vm.tgLinkBusy)
            }
            if let link = vm.tgLink { telegramLinkPanel(link, bot: link.bot ?? t.bot) }
            if let n = vm.tgNotice {
                Text(n).font(.footnote.weight(.semibold)).foregroundColor(Brand.green)
            }
            if let e = vm.tgError {
                Text(e).font(.footnote).foregroundColor(Brand.red)
            }
        }
    }

    private func telegramLinkPanel(_ link: TelegramLink, bot: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Откройте бота и нажмите «Запустить» — уведомления пойдут в этот чат. Для группы смены — «Добавить в группу» и выберите группу.")
                .font(.caption).foregroundColor(Brand.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Открыть @" + (bot ?? "")) { open(link.url) }
                if let g = link.groupUrl, !g.isEmpty {
                    Button("Добавить в группу") { open(g) }
                }
            }
            .buttonStyle(.bordered)
            .tint(Brand.accent)
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Ждём подтверждения от бота… Код действует 10 минут.")
                    .font(.caption).foregroundColor(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Ссылка на бота — во внешнем приложении (Telegram) или браузере.
    private func open(_ urlString: String?) {
        guard let s = urlString, let url = URL(string: s) else { return }
        openURL(url)
    }

    private var feedbackSection: some View {
        Section {
            if let msg = vm.success {
                Text(msg).font(.footnote.weight(.semibold)).foregroundColor(Brand.green)
            }
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
            }
        }
        .listRowBackground(Color.clear)
    }
}
