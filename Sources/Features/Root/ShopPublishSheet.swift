import SwiftUI

// ============================================================================
//  Публикация организации по метке «Не опубликован ›» в шапке (паритет с
//  Android: Nav.kt PublishDialog). Чек-лист сервера — GET publish-status,
//  отправка — POST publish-request (seller_settings.php). Модель ответа —
//  ShopPublishStatus (DashboardView.swift), та же, что у карточки на Дашборде.
// ============================================================================

@MainActor
final class ShopPublishModel: ObservableObject {
    @Published var data: ShopPublishStatus?
    @Published var loading = false
    @Published var loadError: String?
    @Published var busy = false
    @Published var error: String?

    func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            data = try await API.shared.get("api/seller/publish-status", as: ShopPublishStatus.self)
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// true — заявка ушла (или сервер уже показывает «на проверке»).
    func submit() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        error = nil
        var ok = false
        do {
            _ = try await API.shared.post("api/seller/publish-request", as: BoolAck.self)
            ok = true
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        // И после обрыва: заявка могла дойти — статус покажет сервер.
        await load()
        if data?.inReview == 1 || data?.status == "review" { error = nil; ok = true }
        return ok
    }
}

struct ShopPublishSheet: View {
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ShopPublishModel()

    var body: some View {
        NavigationStack {
            List {
                if let d = model.data {
                    content(d)
                } else if let err = model.loadError {
                    Section {
                        Text(err).font(.footnote).foregroundColor(Brand.red)
                        Button("Повторить") { Task { await model.load() } }
                    }
                    .listRowBackground(Brand.card)
                } else {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                        .listRowBackground(Brand.card)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Публикация организации")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }.disabled(model.busy)
                }
            }
            .refreshable { await model.load() }
            .task {
                await model.load()
                // Шапка отстала (организацию уже отправили или опубликовали с сайта) —
                // перечитываем статус, как после отправки.
                if let s = model.data?.status, s != session.shopStatus { await session.refreshShops() }
            }
        }
        .interactiveDismissDisabled(model.busy)
    }

    @ViewBuilder
    private func content(_ d: ShopPublishStatus) -> some View {
        let isPublic = d.status == "active" || d.status == "paused"
        let inReview = d.inReview == 1 || d.status == "review"
        let items = d.checklist ?? []
        Section {
            if let label = d.statusLabel, !label.isEmpty {
                Text(label).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
            }
            Text(isPublic
                 ? "Организация опубликована — клиенты её видят."
                 : inReview
                 ? "Администратор проверяет организацию — после одобрения она появится на витрине."
                 : "Клиенты пока не видят организацию. Заполните пункты ниже и отправьте её на проверку.")
                .font(.footnote).foregroundColor(Brand.muted)
            if let note = d.publishNote, !note.isEmpty {
                Text("Замечание администратора: " + note)
                    .font(.footnote).foregroundColor(Brand.red)
            }
        }
        .listRowBackground(Brand.card)

        if !items.isEmpty && !isPublic {
            Section {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let ok = item.ok == true
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(ok ? Brand.green : Brand.muted)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label ?? item.key ?? "—")
                                .font(.subheadline).foregroundColor(Brand.text)
                            if !ok, let hint = item.hint, !hint.isEmpty {
                                Text(hint).font(.caption).foregroundColor(Brand.muted)
                            }
                        }
                    }
                }
            } header: {
                Text("Готово \(d.done ?? 0) из \(d.total ?? items.count)")
            }
            .listRowBackground(Brand.card)
        }

        if !isPublic && !inReview && d.canSubmit == 1 && session.can("settings") {
            Section {
                Button {
                    // Ушло — перечитываем /me и список: шапка, «Ещё» и Дашборд покажут «на проверке».
                    Task { if await model.submit() { await session.bootstrap() } }
                } label: {
                    HStack {
                        Spacer()
                        if model.busy { ProgressView() } else { Text("Отправить на проверку").bold() }
                        Spacer()
                    }
                }
                .disabled(model.busy)
            } footer: {
                if let err = model.error { Text(err).foregroundColor(Brand.red) }
            }
            .listRowBackground(Brand.card)
        } else if let err = model.error {
            Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                .listRowBackground(Brand.card)
        }
    }
}
