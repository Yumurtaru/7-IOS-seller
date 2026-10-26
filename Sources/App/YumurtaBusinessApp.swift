import SwiftUI

@main
struct YumurtaBusinessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var session = Session.shared
    @StateObject private var router = DeepLinkRouter.shared
    @StateObject private var poller = NewOrderPoller.shared
    /// П-52: «Вышла новая версия» — проверка при запуске и возврате на передний план.
    @StateObject private var updates = AppUpdateCenter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                // П-52: обязательное обновление — экран вместо всего (и входа тоже):
                // под ним ничего не открыто, закрыть его нельзя.
                if let info = updates.force {
                    ForceUpdateView(info: info)
                } else if session.isLoggedIn {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
            .environmentObject(session)
            .environmentObject(router)
            .environmentObject(poller)
            .tint(Brand.accent)
            .preferredColorScheme(.dark)   // кабинет — тёмная тема
            .onOpenURL { url in router.handle(url: url) }
            // id: session.isLoggedIn — блок обязан отработать ЗАНОВО после входа.
            // Без id он выполнялся один раз при появлении окна, то есть на экране
            // логина, и после успешного входа ни bootstrap, ни регистрация
            // push-токена, ни поллер уже не запускались.
            .task(id: session.isLoggedIn) {
                PushManager.shared.refreshAuthorizationStatus()
                guard session.isLoggedIn else { return }
                await session.bootstrap()
                await PushManager.shared.registerIfPossible()
                poller.start()
            }
            // П-52: запрос в фоне, запуск не ждёт; не чаще раза в 6 часов.
            .task { await updates.onForeground() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await updates.onForeground() } }
            }
        }
    }
}
