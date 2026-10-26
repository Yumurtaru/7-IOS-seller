import SwiftUI

// ============================================================================
//  Тип и режим организации — POST /api/seller/settings/type и /settings/mode.
//
//  Тип (магазин / кафе / услуги) определяет, какие разделы вообще существуют:
//  у ресторана появляются меню, столы и тех. карты, у услуг — мастера и записи.
//  Поэтому после смены типа приложение перечитывает /me и перерисовывает вкладки.
//
//  Сервер при смене типа чистит связи с категориями каталога — иначе магазин
//  остался бы висеть в категориях услуг. Об этом честно предупреждаем.
//
//  Право — «Настройки» (settings).
// ============================================================================

struct OrgTypeView: View {
    @EnvironmentObject private var session: Session
    @State private var pendingType: OrgType?
    @State private var saving = false
    @State private var error: String?
    @State private var savedNote: String?

    private var currentType: OrgType { OrgType.fromDb(session.shopType) }
    private var currentMode: OrgMode { OrgMode(rawValue: session.shopMode) ?? .shop }
    /// Смена типа перекраивает весь кабинет — отдельное право внутри «Настроек».
    private var canChange: Bool { session.can("settings.type") }

    var body: some View {
        Form {
            Section {
                ForEach(OrgType.allCases) { type in
                    Button {
                        guard type != currentType, !saving, canChange else { return }
                        pendingType = type
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.title).foregroundColor(Brand.text)
                                Text(type.hint).font(.caption).foregroundColor(Brand.muted)
                            }
                            Spacer()
                            if type == currentType {
                                Image(systemName: "checkmark").foregroundColor(Brand.accent)
                            }
                        }
                    }
                    .disabled(saving || !canChange)
                }
            } header: {
                Text("Тип организации")
            } footer: {
                Text(canChange
                     ? "От типа зависит набор разделов. При смене типа связи с категориями каталога очищаются — их нужно будет выбрать заново."
                     : "Тип и режим меняет владелец или сотрудник с правом «Менять тип и режим организации».")
            }
            .listRowBackground(Brand.card)

            Section {
                ForEach(OrgMode.allCases) { mode in
                    Button {
                        guard mode != currentMode, !saving, canChange else { return }
                        Task { await saveMode(mode) }
                    } label: {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title).foregroundColor(Brand.text)
                                Text(mode.hint).font(.caption).foregroundColor(Brand.muted)
                            }
                            Spacer()
                            if mode == currentMode {
                                Image(systemName: "checkmark").foregroundColor(Brand.accent)
                            }
                        }
                    }
                    .disabled(saving || !canChange)
                }
            } header: {
                Text("Режим витрины")
            } footer: {
                Text("Режим меняет только витрину для покупателя, разделы кабинета остаются те же.")
            }
            .listRowBackground(Brand.card)

            if let savedNote {
                Section { Text(savedNote).font(.footnote).foregroundColor(Brand.green) }
                    .listRowBackground(Color.clear)
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundColor(Brand.red) }
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Тип организации")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Сменить тип?", isPresented: Binding(
            get: { pendingType != nil },
            set: { if !$0 { pendingType = nil } }
        ), presenting: pendingType) { type in
            Button("Отмена", role: .cancel) { pendingType = nil }
            Button("Сменить", role: .destructive) {
                let t = type
                pendingType = nil
                Task { await saveType(t) }
            }
        } message: { type in
            // Что именно появится после смены типа: без этой строки продавец
            // менял тип и не понимал, куда делись прежние разделы.
            Text("Организация станет «\(type.title)». Разделы кабинета изменятся, а связи с категориями каталога очистятся."
                 + (type == .lodging
                    ? "\n\nВместо «Заказов» и «Товаров» появятся «Брони» и «Объекты»: календарь цен, тарифы, заявки на длительную аренду и туристический налог — всё в приложении."
                    : ""))
        }
    }

    private func saveType(_ type: OrgType) async {
        saving = true
        defer { saving = false }
        error = nil; savedNote = nil
        do {
            try await session.setOrgType(type)
            savedNote = type == .lodging
                ? "Тип изменён на «\(type.title)». Разделы «Брони» и «Объекты» уже в приложении."
                : "Тип изменён на «\(type.title)»"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveMode(_ mode: OrgMode) async {
        saving = true
        defer { saving = false }
        error = nil; savedNote = nil
        do {
            try await session.setOrgMode(mode)
            savedNote = "Режим витрины: «\(mode.title)»"
        } catch {
            self.error = error.localizedDescription
        }
    }
}
