import SwiftUI
import UIKit

// ============================================================================
//  «О приложении»: версия и номер сборки (CFBundleShortVersionString /
//  CFBundleVersion), версия iOS. Поддержка первым делом спрашивает «какая у
//  вас версия» — раньше её нигде в приложении не было видно.
// ============================================================================

struct AboutAppView: View {
    @EnvironmentObject var session: Session
    @State private var copied = false

    private var version: String { InstallInfo.appVersion ?? "—" }
    private var build: String { InstallInfo.appBuild.map(String.init) ?? "—" }
    private var os: String { InstallInfo.osVersion ?? "—" }

    /// Одна строка для поддержки: версия, сборка, iOS, организация.
    private var supportLine: String {
        var parts = ["Yumurta Seller \(version) (сборка \(build))", os]
        if let id = session.activeShopId { parts.append("организация №\(id)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 6) {
                    Text("Yumurta")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundColor(Brand.accent)
                    Text("Бизнес — кабинет продавца, кафе, услуг и жилья")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Brand.card)

            Section {
                InfoRow(label: "Версия", value: version)
                InfoRow(label: "Сборка", value: build)
                InfoRow(label: "Система", value: os)
            } footer: {
                Text("Эти данные спросит поддержка, если что-то работает не так.")
            }
            .listRowBackground(Brand.card)

            Section {
                Button {
                    UIPasteboard.general.string = supportLine
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Скопировано" : "Скопировать для поддержки",
                          systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                }
                if let url = URL(string: API.base) {
                    Link(destination: url) {
                        Label("Сайт yumurta.ru", systemImage: "safari")
                    }
                }
            }
            .listRowBackground(Brand.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("О приложении")
        .navigationBarTitleDisplayMode(.inline)
    }
}
