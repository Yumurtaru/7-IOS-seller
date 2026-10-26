import SwiftUI
import UIKit

// ============================================================================
//  П-52: «Вышла новая версия — обновите». Проверка — при запуске и при каждом
//  возврате на передний план (scenePhase в YumurtaBusinessApp), не чаще раза в
//  6 часов; запрос в фоне и запуск не задерживает. Любая ошибка (нет сети, 404
//  старого сервера, 429, не JSON) — молча ничего: всё как раньше.
//  Обязательное — экран вместо всего (YumurtaBusinessApp); мягкое — окно на
//  сводке (MainTabView), не поверх входа. Логика — Core/AppUpdate.swift.
// ============================================================================

@MainActor
final class AppUpdateCenter: ObservableObject {
    static let shared = AppUpdateCenter()

    /// Обязательное обновление — экран «Нужно обновить приложение».
    @Published private(set) var force: AppVersionInfo?
    /// Мягкое окно «Вышла новая версия» — ждёт главного экрана.
    @Published private(set) var soft: AppVersionInfo?

    private var checking = false

    // Настройки — UserDefaults, как переключатели уведомлений (PushManager):
    // выход из аккаунта их не стирает.
    private enum Key {
        static let checkedAt = "app_update_checked_at"
        static let force = "app_update_force"
        static let snoozeKey = "app_update_snooze_key"
        static let snoozeAt = "app_update_snooze_at"
    }

    private init() {}

    /// Установленная версия (CFBundleShortVersionString).
    nonisolated static var installedVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// Запуск или возврат на передний план.
    func onForeground() async {
        guard !checking else { return }
        let d = UserDefaults.standard
        // Обязательное, если уже было, проверяем каждый раз: после обновления экран исчезнет.
        let pending = force != nil || d.bool(forKey: Key.force)
        guard AppUpdateLogic.shouldCheck(lastOkAt: d.double(forKey: Key.checkedAt),
                                         now: Date().timeIntervalSince1970, forcePending: pending) else { return }
        checking = true
        defer { checking = false }
        // А105: сведения об установке. Новый id — только когда данные телефона открыты
        // (InstallInfo.deviceId): до первой разблокировки файл id не прочитать.
        let install = InstallInfo.versionQuery(canCreate: UIApplication.shared.isProtectedDataAvailable)
        guard let info = await API.shared.appVersion(install: install) else { return }
        let now = Date().timeIntervalSince1970
        let decision = AppUpdateLogic.decide(info, version: AppUpdateCenter.installedVersion)
        d.set(now, forKey: Key.checkedAt)
        d.set(decision == .force, forKey: Key.force)
        force = decision == .force ? info : nil
        let snoozed = AppUpdateLogic.isSnoozed(key: AppUpdateLogic.softKey(info), snoozedKey: d.string(forKey: Key.snoozeKey),
                                               snoozedAt: d.double(forKey: Key.snoozeAt), now: now)
        soft = decision == .soft && !snoozed ? info : nil
    }

    /// «Позже» или «Обновить» в мягком окне: эту версию не показываем 24 часа.
    func snoozeSoft() {
        guard let info = soft else { return }
        soft = nil
        let d = UserDefaults.standard
        d.set(AppUpdateLogic.softKey(info), forKey: Key.snoozeKey)
        d.set(Date().timeIntervalSince1970, forKey: Key.snoozeAt)
    }

    /// Открыть App Store.
    func openStore(_ link: String) {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        UIApplication.shared.open(url)
    }
}

/// «Нужно обновить приложение» — во весь экран, закрыть нельзя.
struct ForceUpdateView: View {
    let info: AppVersionInfo
    @ObservedObject private var center = AppUpdateCenter.shared

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 16) {
                    Spacer(minLength: 24)
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 56))
                        .foregroundColor(Brand.accent)
                        .accessibilityHidden(true)
                    Text("Нужно обновить приложение")
                        .font(.title2.weight(.bold))
                        .foregroundColor(Brand.text)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(AppUpdateLogic.forceText(info))
                        .font(.body)
                        .foregroundColor(Brand.muted)
                        .multilineTextAlignment(.center)
                    Button {
                        center.openStore(info.storeUrl)
                    } label: {
                        Text("Обновить")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
                    .controlSize(.large)
                    .padding(.top, 8)
                    Text(AppUpdateLogic.forceVersionLine(info, installed: AppUpdateCenter.installedVersion))
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                        .multilineTextAlignment(.center)
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .background(Brand.bg.ignoresSafeArea())
    }
}

/// Мягкое окно «Вышла новая версия»: «Обновить» и «Позже», оба откладывают его на сутки.
/// Показываем только на главном экране (сводке — своих окон у неё нет); пока открыт
/// другой раздел, окно ждёт возврата на сводку.
struct SoftUpdatePrompt: ViewModifier {
    let isMainScreen: Bool
    @ObservedObject private var center = AppUpdateCenter.shared
    @State private var shown: AppVersionInfo?

    private struct Key: Equatable {
        let main: Bool
        let soft: AppVersionInfo?
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(main: isMainScreen, soft: center.soft)) {
                if isMainScreen, shown == nil, let info = center.soft { shown = info }
            }
            .alert(shown.map { AppUpdateLogic.softTitle($0) } ?? "",
                   isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } }),
                   presenting: shown) { info in
                Button("Обновить") {
                    center.snoozeSoft()
                    shown = nil
                    center.openStore(info.storeUrl)
                }
                Button("Позже", role: .cancel) {
                    center.snoozeSoft()
                    shown = nil
                }
            } message: { info in
                Text(AppUpdateLogic.softText(info))
            }
    }
}
