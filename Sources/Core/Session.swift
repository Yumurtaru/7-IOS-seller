import Foundation
import Combine
import UIKit
import UserNotifications

/// Состояние авторизации и активной организации.
/// После login / switch-shop подтягивает shops + settings (оттуда shops.type
/// активного магазина — /api/seller/shops тип не отдаёт, это факт контракта).
@MainActor
final class Session: ObservableObject {
    static let shared = Session()

    @Published private(set) var isLoggedIn: Bool
    @Published private(set) var user: SellerUser?
    @Published private(set) var shops: [ShopSummary] = []
    @Published private(set) var activeShopId: Int?
    @Published private(set) var shopType: String = "shop"      // shop | cafe | service
    /// shops.mode: storefront | shop | restaurant — режим витрины, не тип.
    @Published private(set) var shopMode: String = "shop"
    @Published private(set) var shopStatus: String = "active"  // active | paused
    @Published private(set) var shopName: String = ""
    /// shops.slug — из него собирается публичный адрес витрины (для QR и ссылок).
    @Published private(set) var shopSlug: String = ""
    @Published var bootError: String?
    @Published private(set) var booting = false

    /// Меняется при каждом переключении магазина — экраны перезагружают данные по .id(reloadKey).
    @Published private(set) var reloadKey = UUID()

    /// RBAC (Фаза 2.5). Факт контракта: в панель входит только владелец
    /// (auth_seller.php пускает лишь account_type seller/kafe/service) и login-ответ
    /// permissions НЕ содержит → nil = полные права. Если сервер аддитивно начнёт
    /// отдавать permissions ({code:true} из StaffRBAC), меню сразу режется по ним.
    @Published private(set) var permissions: [String: Bool]?

    /// Владелец организации или сотрудник. Показываем роль в шапке, чтобы
    /// сотруднику было понятно, почему часть разделов не видна.
    @Published private(set) var isOwner: Bool = true
    @Published private(set) var roleName: String?
    @Published private(set) var staffName: String?

    /// Номер «входа»: меняется при входе и выходе. Ответы bootstrap/switch-shop,
    /// начатые до смены аккаунта, по нему отбрасываются.
    private var accountEpoch = 0
    /// Переключение магазина в пути — второе не начинаем.
    /// @Published: меню магазинов показывает ожидание и не принимает второй
    /// выбор (раньше второй тап молча отбрасывался).
    @Published private(set) var switching = false
    /// Номер переключения магазина. Ответ bootstrap/статуса, начатый до смены,
    /// по нему отбрасывается: иначе тип, имя и статус прежнего магазина
    /// ложились поверх нового (и галочка в меню вставала на прежний).
    private var shopEpoch = 0
    /// Номер нажатия паузы: устаревший ответ /shops не перетирает новый статус.
    private var statusGen = 0
    /// Почему открылся экран входа. Сессия истекла посреди работы — продавца
    /// молча выбрасывало на вход, и было непонятно, куда делась форма.
    @Published var signOutNotice: String?
    /// П-28.6: запрос push/unregister после «сессия истекла» — регистрация при
    /// следующем входе ждёт его, иначе он погасил бы уже новую регистрацию.
    private var pushUnregister: Task<Void, Never>?

    private init() {
        isLoggedIn = Keychain.get(.accessToken) != nil
        loadPersisted()
        API.shared.onUnauthorized = { [weak self] in
            guard let self else { return }
            // Только если были в аккаунте: поздний 401 после «Выйти» — не «истекла».
            if self.isLoggedIn {
                self.signOutNotice = "Сессия истекла — войдите снова"
                // П-28.6: сессия истекла — выход на сервере и гашение push-токена
                // устройства (без Authorization) одной цепочкой. Оба запроса
                // гасят токен, поэтому регистрация при следующем входе (signIn)
                // ждёт всю цепочку — иначе поздний ответ погасил бы новую.
                let tok = Keychain.get(.accessToken)
                let push = PushManager.shared.deviceToken
                self.pushUnregister = Task {
                    await API.shared.logout(accessToken: tok, pushToken: push)
                    if let push, !push.isEmpty { await API.shared.unregisterPushToken(push) }
                }
                self.signOut(serverLogout: false)   // выход на сервере уже в цепочке выше
                return
            }
            self.signOut()
        }
        // Приложение запустилось в фоне (тихий push) до первой разблокировки
        // телефона: Keychain и UserDefaults в этот момент закрыты, токен не
        // читался — и после разблокировки продавец видел экран входа, хотя
        // из аккаунта не выходил. После разблокировки перечитываем.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { _ in
            Task { @MainActor in Session.shared.restoreAfterUnlock() }
        }
    }

    /// Токен появился после разблокировки, а вход ещё не выполнен — поднимаем
    /// сессию. После явного «Выйти» токена в Keychain нет, и сюда не попадаем.
    func restoreAfterUnlock() {
        guard !isLoggedIn, Keychain.get(.accessToken) != nil else { return }
        loadPersisted()
        isLoggedIn = true
    }

    /// Профиль, права и тип организации прошлого запуска (из UserDefaults).
    private func loadPersisted() {
        if let data = UserDefaults.standard.data(forKey: "seller_user"),
           let u = try? JSONDecoder().decode(SellerUser.self, from: data) {
            user = u
        }
        if let data = UserDefaults.standard.data(forKey: "seller_permissions"),
           let p = try? JSONDecoder().decode([String: Bool].self, from: data) {
            permissions = p
        }
        isOwner = permissions == nil
        // Тип организации прошлого запуска: без него до ответа /me тип был «shop»,
        // и у кафе после /me вкладки пересоздавались — заказ, открытый из push
        // на холодном старте, тут же закрывался.
        if let t = UserDefaults.standard.string(forKey: "seller_shop_type"), !t.isEmpty {
            shopType = t
            OrderStatuses.shopType = t
        }
        roleName = UserDefaults.standard.string(forKey: "seller_role_name")
        staffName = UserDefaults.standard.string(forKey: "seller_staff_name")
    }

    /// Право из каталога core/StaffRBAC.php: orders / returns / products /
    /// promotions / analytics / customers / reviews / employees / finance / settings…
    /// Повторяет StaffRBAC::can() на сервере:
    ///  1. явно записанное значение сильнее всего — иначе роль с «*» нельзя
    ///     было бы ограничить в одном действии;
    ///  2. «*» (или отсутствие карты, то есть владелец) — можно всё;
    ///  3. право действия «раздел.действие» без своего ключа наследуется от
    ///     раздела, поэтому старые роли работают как работали.
    func can(_ key: String) -> Bool {
        guard let p = permissions else { return true }   // владелец — всё можно
        if let explicit = p[key] { return explicit }
        if p["*"] == true { return true }
        if let dot = key.firstIndex(of: "."), dot > key.startIndex {
            return can(String(key[key.startIndex..<dot]))
        }
        return false
    }

    func signIn(response: LoginResponse) {
        accountEpoch += 1   // запоздалые ответы прежней сессии больше не применяются
        signOutNotice = nil   // вошли — подсказка «сессия истекла» больше не нужна
        user = response.user
        if let u = response.user, let data = try? JSONEncoder().encode(EncodableUser(from: u)) {
            UserDefaults.standard.set(data, forKey: "seller_user")
        }
        // Владелец — ТОЛЬКО по полю is_owner с сервера. Пустой набор прав
        // приходит как nil и владельцем не делает (см. LoginResponse.isOwner).
        // Сотрудник без единой галочки: сервер шлёт permissions: [] (в Swift — nil),
        // а nil в can() значит «можно всё». До ответа /me (и навсегда, если /me
        // не дошёл) сотрудник видел меню владельца; после перезапуска приложение
        // считало его владельцем. Для не-владельца nil — это пустой набор прав.
        let owner = response.isOwner ?? (response.permissions == nil)
        applyAccess(permissions: owner ? nil : (response.permissions ?? [:]),
                    isOwner: owner,
                    roleName: response.role?.name,
                    staffName: nil)
        // Паритет с Android: до ответа /me тип организации берём из типа аккаунта
        // (kafe → кафе, service → услуги). Раньше у кафе первые секунды были вкладка
        // «Товары» и подписи статусов магазина, потом вкладки пересоздавались.
        // /me уточнит тип (у владельца нескольких точек он может отличаться).
        switch response.user?.accountType {
        case "kafe": shopType = "cafe"; OrderStatuses.shopType = "cafe"
        case "service": shopType = "service"; OrderStatuses.shopType = "service"
        default: break
        }
        isLoggedIn = true
        Task { await bootstrap() }
        let pendingUnregister = pushUnregister
        pushUnregister = nil
        Task {
            await pendingUnregister?.value   // П-28.6: сначала дойдёт unregister, потом регистрация
            await PushManager.shared.registerIfPossible()
        }
    }

    /// serverLogout: false — только при «сессия истекла»: выход на сервере уже
    /// запущен цепочкой pushUnregister (П-28.6). «Выйти» вручную — как раньше.
    func signOut(serverLogout: Bool = true) {
        // Гасим сессию и на сервере: без этого refresh-токен оставался живым, и
        // «Выйти» на потерянном телефоне ничего не защищало. Ждать ответа не
        // нужно — локальная очистка идёт в любом случае.
        let tok = Keychain.get(.accessToken)
        let push = PushManager.shared.deviceToken
        accountEpoch += 1   // bootstrap/switch-shop в пути не запишут данные вышедшего
        if serverLogout { Task { await API.shared.logout(accessToken: tok, pushToken: push) } }
        Keychain.clearAll()
        API.clearCookies()
        UserDefaults.standard.removeObject(forKey: "seller_user")
        UserDefaults.standard.removeObject(forKey: "seller_permissions")
        UserDefaults.standard.removeObject(forKey: "seller_role_name")
        UserDefaults.standard.removeObject(forKey: "seller_staff_name")
        UserDefaults.standard.removeObject(forKey: "seller_shop_type")
        user = nil
        permissions = nil
        isOwner = true
        roleName = nil
        staffName = nil
        shops = []
        activeShopId = nil
        // Тип, режим, название и адрес витрины прежней организации: после входа
        // в другую (пока /me не ответил, а при ошибке — всю сессию) вкладки,
        // подписи статусов и QR-ссылка были от неё.
        shopType = "shop"
        shopMode = "shop"
        shopStatus = "active"
        shopName = ""
        shopSlug = ""
        OrderStatuses.shopType = "shop"
        // Поллер новых заказов и бейдж иконки — тоже прежнего аккаунта.
        NewOrderPoller.shared.resetAfterLogout()
        // Паритет с Android (cancelAll при выходе): уведомления этого аккаунта в
        // Центре уведомлений (суммы заказов, тексты клиентов) видел и открывал
        // следующий, кто войдёт на телефоне. Только при своём «Выйти»: при
        // истёкшей сессии (signOutNotice задан) вернётся тот же человек.
        if signOutNotice == nil {
            UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        }
        permsRefreshedAt = .distantPast
        DeepLinkRouter.shared.reset()
        isLoggedIn = false
    }

    /// Загрузка списка организаций + типа/статуса активной. Вызывается при старте и после switch-shop.
    func bootstrap() async {
        guard isLoggedIn else { return }
        // Ответ, пришедший после «Выйти» (или после входа в другой аккаунт),
        // не применяем: раньше он записывал магазины, тип и права прежнего
        // аккаунта — и в UserDefaults, откуда их читает следующий запуск.
        let epoch = accountEpoch
        // Запуск (вход + .task) идёт двумя bootstrap: поздний ответ того, что
        // начат до переключения магазина, возвращал прежний active_id, его тип
        // и имя — экраны нового магазина под названием прежнего.
        let shopEp = shopEpoch
        booting = true
        bootError = nil
        defer { booting = false }
        do {
            let res = try await API.shared.shops()
            guard epoch == accountEpoch, shopEp == shopEpoch, isLoggedIn else { return }
            shops = res.shops
            activeShopId = res.activeId ?? res.shops.first?.shopId
            // Тип организации и права берём из /api/seller/me, а не из settings:
            // settings отдаёт реквизиты и ИНН, сотруднику без права «Настройки»
            // она закрыта (403), и старт приложения падал в ошибку.
            // Права здесь же — роль могли изменить, пока приложение было закрыто.
            let me = try await API.shared.me()
            guard epoch == accountEpoch, shopEp == shopEpoch, isLoggedIn else { return }
            let prevType = shopType
            let prevPerms = permissions, prevOwner = isOwner
            applyMe(me)
            // Тип магазина пришёл другим (холодный старт: до /me он «shop») —
            // экраны пересоздаём, иначе у кафе подписи статусов магазина.
            // Права другие (после смены магазина роль своя) — тоже: экраны,
            // пересозданные сразу при переключении, собраны по правам прежнего.
            if shopType != prevType || permissions != prevPerms || isOwner != prevOwner { reloadKey = UUID() }
            // reloadKey здесь НЕ меняем: bootstrap идёт и при входе, и при
            // холодном старте из push — пересоздание вкладок закрывало только что
            // открытый из уведомления заказ. Меняем его при смене магазина/типа.
        } catch let e as APIError {
            if case .unauthorized = e { return }   // onUnauthorized уже разлогинил
            guard epoch == accountEpoch, shopEp == shopEpoch else { return }   // ошибка прежнего аккаунта/магазина
            bootError = e.localizedDescription
        } catch {
            guard epoch == accountEpoch, shopEp == shopEpoch else { return }
            bootError = error.localizedDescription
        }
    }

    /// Перечитать только список организаций (счётчик возвратов на вкладке «Ещё»):
    /// раньше он обновлялся лишь при запуске, и одобренный возврат висел в бейдже.
    func refreshShops() async {
        let epoch = accountEpoch
        let shopEp = shopEpoch
        let sg = statusGen
        guard isLoggedIn, let res = try? await API.shared.shops() else { return }
        // Пока шёл запрос, могли выйти или сменить аккаунт — чужой список не пишем.
        // Одной проверки isLoggedIn мало: «Выйти» и вход в другой аккаунт за время
        // запроса оставляют true, и новый аккаунт получал магазины прежнего.
        guard isLoggedIn, epoch == accountEpoch else { return }
        shops = res.shops
        // Статус активной организации тоже обновляем: новую (draft → review →
        // active) публикует администратор, а «Ещё» до перезапуска писала
        // «ещё не опубликована» и прятала переключатель паузы.
        // sg: пока шёл /shops, нажали паузу — старый ответ её не отменяет.
        if shopEp == shopEpoch, sg == statusGen, let id = activeShopId,
           let st = res.shops.first(where: { $0.shopId == id })?.status, !st.isEmpty {
            shopStatus = st
        }
    }

    /// Когда последний раз перечитывали права по 403.
    private var permsRefreshedAt = Date.distantPast

    /// Паритет с Android (Repo.onForbidden): сервер ответил сотруднику 403 —
    /// роль могли урезать, пока приложение открыто. Перечитываем /me не чаще
    /// раза в минуту, чтобы меню и кнопки спрятались сразу, а не после перезапуска.
    func onForbidden() {
        guard isLoggedIn, !isOwner, !booting else { return }
        guard Date().timeIntervalSince(permsRefreshedAt) > 60 else { return }
        permsRefreshedAt = Date()
        let epoch = accountEpoch, shopEp = shopEpoch
        Task {
            guard let me = try? await API.shared.me() else { return }
            // Пока шёл запрос, вышли или сменили магазин — чужие права не пишем.
            guard epoch == self.accountEpoch, shopEp == self.shopEpoch, self.isLoggedIn else { return }
            self.applyMe(me)
        }
    }

    /// Публичный адрес витрины — то же, что сервер зашивает в QR-код.
    /// Пока /me не пришёл, слага нет — вернём nil, а не битую ссылку на /shop/.
    var shopPublicUrl: String? {
        // П-27.13: /me не пришёл — slug активной точки из /api/seller/shops.
        // Только точное совпадение id: «первая точка» дала бы чужой адрес.
        let listed = activeShopId.flatMap { id in shops.first { $0.shopId == id }?.slug } ?? ""
        let slug = shopSlug.isEmpty ? listed.trimmingCharacters(in: .whitespaces) : shopSlug
        return slug.isEmpty ? nil : API.base + "/shop/" + slug
    }

    /// Активный магазин из уже загруженного списка (для лого/имени/бейджей во вью).
    var activeShop: ShopSummary? {
        guard let id = activeShopId else { return shops.first }
        return shops.first { $0.shopId == id } ?? shops.first
    }

    /// Переключение активной организации: сервер запоминает выбор в сессии,
    /// затем перечитываем shops + settings, чтобы обновить тип/статус/имя и перерисовать разделы.
    func switchShop(to id: Int) async {
        // Второе переключение, пока идёт первое (меню открыли ещё раз на
        // медленной сети): ответы приходили в любом порядке, и сервер мог
        // остаться на одном магазине, а экраны — показывать другой.
        guard id != activeShopId, !switching else { return }
        switching = true
        defer { switching = false }
        let epoch = accountEpoch
        let before = activeShopId
        do {
            _ = try await API.shared.switchShop(id: id)
            guard epoch == accountEpoch, isLoggedIn else { return }   // уже вышли
            await applySwitched(to: id)
        } catch let e as APIError {
            if case .unauthorized = e { return }   // onUnauthorized уже разлогинил
            // Ошибку переключения, начатого до выхода, новому аккаунту не показываем.
            guard epoch == accountEpoch else { return }
            bootError = e.localizedDescription
            // Отказ сервера (.server) — магазин точно прежний. Обрыв/таймаут —
            // сервер мог успеть переключиться: сверяемся, см. resyncAfterLostSwitch.
            if case .server(_) = e { return }
            Task { await self.resyncAfterLostSwitch(from: before, epoch: epoch) }
        } catch {
            guard epoch == accountEpoch else { return }
            bootError = error.localizedDescription
            Task { await self.resyncAfterLostSwitch(from: before, epoch: epoch) }
        }
    }

    /// Ответ switch-shop потерялся (обрыв, таймаут), а сервер уже переключил
    /// магазин: экраны и галочка в меню оставались на прежнем, а данные и
    /// «Принять» шли уже по новому; вернуться в прежний меню не давало (он «активный»).
    /// Спрашиваем у сервера, какой магазин активен, и догоняем его.
    private func resyncAfterLostSwitch(from before: Int?, epoch: Int) async {
        let ep = shopEpoch
        guard let res = try? await API.shared.shops() else { return }
        guard epoch == accountEpoch, ep == shopEpoch, !switching, isLoggedIn,
              let actual = res.activeId, actual != before else { return }
        shops = res.shops
        await applySwitched(to: actual)
    }

    /// Сервер уже на магазине id — переводим на него и приложение.
    private func applySwitched(to id: Int) async {
        activeShopId = id
        shopEpoch += 1   // ответы, начатые до переключения, больше не применяются
        DeepLinkRouter.shared.reset()
        NewOrderPoller.shared.shopChanged()
        // Экраны пересоздаём сразу, а не после /me: пока шли ещё два запроса,
        // под названием нового магазина висели заказы и товары прежнего, и
        // «Принять»/«Сохранить» уходили на сервер, который уже на новом.
        // Адрес витрины прежнего не держим (QR не того магазина, если /me не дойдёт).
        shopSlug = ""
        shopName = ""
        // П-27.13: /api/seller/shops теперь отдаёт тип точки — ставим его сразу,
        // чтобы вкладки и подписи статусов нового магазина были верными до /me
        // (и если /me не дойдёт). Нет поля (старый сервер) — как раньше, ждём /me.
        if let t = shops.first(where: { $0.shopId == id })?.type?.trimmingCharacters(in: .whitespaces),
           ["shop", "cafe", "service", "lodging"].contains(t) {
            shopType = t
            OrderStatuses.shopType = t
        }
        reloadKey = UUID()   // сервер уже на новом магазине, даже если bootstrap не пройдёт
        // Тип другой — bootstrap сам пересоздаст вкладки ещё раз.
        await bootstrap()
    }

    /// Смена типа организации. От типа зависят вкладки и половина разделов,
    /// поэтому после сохранения перечитываем /me целиком и меняем reloadKey —
    /// иначе у ресторана остались бы открыты экраны магазина.
    func setOrgType(_ type: OrgType) async throws {
        let shopEp = shopEpoch, acc = accountEpoch
        _ = try await API.shared.setOrgType(type)
        // Пока шёл запрос, переключили магазин или вышли — тип прежнего
        // магазина новому не присваиваем (вкладки стали бы чужого формата).
        guard shopEp == shopEpoch, acc == accountEpoch else { return }
        shopType = type.dbValue
        OrderStatuses.shopType = type.dbValue    // подписи статусов зависят от типа
        UserDefaults.standard.set(type.dbValue, forKey: "seller_shop_type")
        reloadKey = UUID()
        await bootstrap()
    }

    /// Смена режима витрины. Влияет только на витрину, разделы не двигает —
    /// поэтому просто запоминаем новое значение.
    func setOrgMode(_ mode: OrgMode) async throws {
        let shopEp = shopEpoch, acc = accountEpoch
        _ = try await API.shared.setOrgMode(mode)
        guard shopEp == shopEpoch, acc == accountEpoch else { return }   // магазин уже другой
        shopMode = mode.rawValue
    }

    /// Пауза/возобновление приёма заказов. Оптимистично двигаем локальный статус,
    /// на ошибке откатываем. Возвращаем во вью, чтобы Toggle мог показать сбой.
    func setShopStatus(_ status: String) async throws {
        statusGen += 1
        let previous = shopStatus
        let shopEp = shopEpoch, acc = accountEpoch
        shopStatus = status
        do {
            let ack = try await API.shared.setShopStatus(status)
            // Переключили магазин, пока шёл запрос: статус прежнего магазина
            // («на паузе»/«открыт») не пишем поверх статуса нового.
            guard shopEp == shopEpoch, acc == accountEpoch else { return }
            // Сервер может вернуть фактический статус — доверяем ему, если пришёл.
            if let s = ack.status, !s.isEmpty { shopStatus = s }
        } catch {
            if shopEp == shopEpoch && acc == accountEpoch { shopStatus = previous }
            throw error
        }
    }

    /// Раскладываем GET /api/seller/me: тип/статус/имя организации и права роли.
    private func applyMe(_ me: MeResponse) {
        if let shop = me.shop {
            if let t = shop.type, !t.isEmpty {
                shopType = t; OrderStatuses.shopType = t
                UserDefaults.standard.set(t, forKey: "seller_shop_type")
            }
            if let m = shop.mode, !m.isEmpty { shopMode = m }
            if let s = shop.status, !s.isEmpty { shopStatus = s }
            if let n = shop.name, !n.isEmpty { shopName = n }
            if let sl = shop.slug, !sl.isEmpty { shopSlug = sl }
        }
        // Тарифных планов в iOS-приложении нет: подписки продавцов живут
        // только на сайте и в Android. Выключатель features.plans с сервера
        // здесь сознательно не читается — раздела, который он прятал бы,
        // в этой сборке не существует.
        applyAccess(permissions: me.isOwner ? nil : (me.permissions ?? [:]),
                    isOwner: me.isOwner,
                    roleName: me.role?.name,
                    staffName: me.user?.name)
    }

    /// Единое место, где меняются права: и после логина, и после /me.
    /// permissions == nil означает «владелец, можно всё».
    private func applyAccess(permissions p: [String: Bool]?, isOwner owner: Bool, roleName: String?, staffName: String?) {
        permissions = p
        isOwner = owner
        self.roleName = roleName
        self.staffName = staffName
        let d = UserDefaults.standard
        if let p, let data = try? JSONEncoder().encode(p) {
            d.set(data, forKey: "seller_permissions")
        } else {
            d.removeObject(forKey: "seller_permissions")
        }
        if let roleName { d.set(roleName, forKey: "seller_role_name") } else { d.removeObject(forKey: "seller_role_name") }
        if let staffName { d.set(staffName, forKey: "seller_staff_name") } else { d.removeObject(forKey: "seller_staff_name") }
    }

}

// ── Сохранение профиля пользователя в UserDefaults ──────────────────────────
// SellerUser декодируем с сервера (Decodable), но для персиста нужен Encodable.
// Отдельная зеркальная структура — чтобы не навешивать Encodable на модель ответа.
private struct EncodableUser: Encodable {
    let id: Int?
    let name: String?
    let email: String?
    let phone: String?
    let accountType: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id, name, email, phone, status
        case accountType = "account_type"
    }

    init(from u: SellerUser) {
        id = u.id
        name = u.name
        email = u.email
        phone = u.phone
        accountType = u.accountType
        status = u.status
    }
}
