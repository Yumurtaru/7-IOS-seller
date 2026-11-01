import SwiftUI

// ============================================================================
//  АZ (сайт А617): переключатель «Магазин открыт / на паузе» и окно «Пауза приёма
//  заказов». Один общий компонент для обоих мест, где меняется статус организации:
//  «Настройки магазина» (ShopSettingsView) и «Ещё» (MoreView).
//  Окно появляется, только если сервер новый (в GET /settings есть ключ pause —
//  Session.pauseKnown); на старом сервере переключатель, как раньше, сразу ставит
//  бессрочную паузу.
// ============================================================================

/// Окна над переключателем: один `.sheet(item:)` на обе (два `.sheet` на одной вью не работают).
private enum StatusSheet: String, Identifiable {
    case pause, support
    var id: String { rawValue }
}

struct ShopStatusControl: View {
    @EnvironmentObject var session: Session
    /// Шрифт заголовка строки (в «Ещё» мельче, чем в настройках).
    var titleFont: Font = .headline

    init(titleFont: Font = .headline) { self.titleFont = titleFont }

    /// Смена статуса в пути: быстрое вкл/выкл слало два запроса, ответы приходили
    /// в любом порядке, и магазин оставался не в том статусе, что на экране.
    @State private var statusBusy = false
    @State private var statusError: String?
    @State private var statusNote: String?
    @State private var sheet: StatusSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { session.shopStatus == "active" },
                set: { newValue in handleToggle(newValue) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(titleFont)
                    ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundColor(Brand.muted)
                    }
                }
            }
            .tint(Brand.green)
            .disabled(statusBusy || adminLocked)
            // ВВ (сайт А819): паузу поставил администратор площадки — снять её нельзя; выход — поддержка.
            if adminLocked {
                Text(Bb.adminPaused).font(.footnote).foregroundColor(Brand.red)
                Button(Bb.supportButton) { sheet = .support }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.accent)
                    .buttonStyle(.borderless)
            }
            if let note = statusNote {
                Text(note).font(.footnote.weight(.semibold)).foregroundColor(Brand.green)
            }
            if let err = statusError {
                Text(err).font(.footnote).foregroundColor(Brand.red)
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .pause:
                ShopPauseSheet { request in await confirmPause(request) }
            case .support:
                NavigationStack {
                    ShopSupportView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { sheet = nil } }
                        }
                }
            }
        }
        // Сервер новый и право «Настройки» есть, а настройки ещё не читали (на «Ещё» их не
        // читают) — один раз узнаём, есть ли пауза на время и до какого часа.
        .task {
            if !session.pauseChecked { await session.refreshPause() }
        }
        // Статус изменили не мы (список организаций, /me, конец паузы): старое сообщение убираем,
        // срок паузы перечитываем.
        .onChange(of: session.externalStatusTick) { _ in
            statusNote = nil
            if session.shopStatus == "paused" && !session.pauseChecked {
                Task { await session.refreshPause() }
            }
        }
        // Срок паузы кончается сам: крон сервера снимает её раз в минуту — через ~70 секунд
        // после срока (по часам МСК) один раз перечитываем настройки. Только пока экран открыт.
        .task(id: autoRefreshKey) {
            guard session.shopStatus == "paused", let until = session.pauseUntil,
                  let d = DateFmt.parse(until) else { return }
            let wait = d.timeIntervalSinceNow + 70
            if wait <= 0 {
                // Срок уже прошёл (открыли экран позже): сразу перечитываем — крон мог снять паузу.
                await session.refreshPause()
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }
            await session.refreshPause()
        }
    }

    private var autoRefreshKey: String { session.shopStatus + "|" + (session.pauseUntil ?? "") }

    private var isPaused: Bool { session.shopStatus != "active" }

    /// ВВ (А819): пауза администратором — тумблер и окно паузы недоступны.
    private var adminLocked: Bool { isPaused && session.pauseAdmin }

    /// Заголовок: «Магазин открыт» / «На паузе до ЧЧ:ММ» / «Магазин на паузе».
    private var title: String {
        if !isPaused { return "Магазин открыт" }
        if session.pauseKnown, let t = Az.pauseTitle(until: session.pauseUntil) { return t }
        return "Магазин на паузе"
    }

    /// Строки под заголовком: прежний текст; на новом сервере у паузы — причина и «Приём включится сам.».
    private var detailLines: [String] {
        guard isPaused, session.pauseKnown else {
            return ["На паузе клиенты не могут оформлять заказы"]
        }
        var out: [String] = []
        if let r = session.pauseReason, !r.isEmpty { out.append("Причина: " + r) }
        if Az.activeUntil(session.pauseUntil) != nil {
            out.append("Приём включится сам.")
        } else if out.isEmpty {
            out.append("На паузе клиенты не могут оформлять заказы")
        }
        return out
    }

    private func handleToggle(_ newValue: Bool) {
        guard !statusBusy, !adminLocked else { return }
        // Выключают приём на новом сервере — сначала окно «Пауза приёма заказов»;
        // «Отмена» оставляет переключатель «принимаем».
        if !newValue && session.pauseKnown && session.shopStatus == "active" {
            statusError = nil
            sheet = .pause
            return
        }
        statusBusy = true
        Task {
            defer { statusBusy = false }
            // Признак сервера ещё неизвестен (настройки не читались или чтение не удалось), а приём
            // выключают: молча бессрочную паузу не ставим — сперва узнаём, умеет ли сервер паузу на время.
            if !newValue && session.shopStatus == "active" && !session.pauseChecked && session.can("settings") {
                if let failure = await session.refreshPause() {
                    statusError = "Статус не изменён: " + failure
                    statusNote = nil
                    return
                }
                if !session.pauseChecked {
                    statusError = "Статус не изменён: не удалось узнать настройки паузы — попробуйте ещё раз"
                    statusNote = nil
                    return
                }
                if session.pauseKnown {
                    statusError = nil
                    sheet = .pause
                    return
                }
            }
            do {
                let message = try await session.setShopStatus(newValue ? "active" : "paused")
                statusError = nil
                statusNote = message.isEmpty ? nil : message
            } catch {
                statusError = error.localizedDescription
                statusNote = nil
            }
        }
    }

    /// Нажали «Поставить на паузу» в окне. nil — готово (окно закрывается), иначе текст
    /// ошибки сервера (422 «Сейчас по часам работы смена не идёт…»): окно остаётся открытым.
    private func confirmPause(_ request: ShopPauseRequest) async -> String? {
        guard !statusBusy else { return "Подождите, статус ещё меняется" }
        statusBusy = true
        defer { statusBusy = false }
        do {
            let message = try await session.setShopStatus("paused", pause: request)
            statusError = nil
            statusNote = message.isEmpty ? nil : message
            sheet = nil
            return nil
        } catch {
            // ВВ (А819): 409 admin_paused — паузу поставил администратор: окно закрываем, текст сервера — под тумблером.
            if Bb.isAdminPaused(error) {
                statusError = error.localizedDescription
                statusNote = nil
                sheet = nil
                return nil
            }
            return error.localizedDescription
        }
    }
}

/// Окно «Пауза приёма заказов»: срок (один из пяти), причина до 120 знаков с чипами-подсказками.
struct ShopPauseSheet: View {
    /// Возвращает nil при успехе, иначе текст ошибки.
    let onConfirm: (ShopPauseRequest) async -> String?

    init(onConfirm: @escaping (ShopPauseRequest) async -> String?) { self.onConfirm = onConfirm }

    @Environment(\.dismiss) private var dismiss
    @State private var choice: PauseChoice = .min20
    @State private var reason = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(PauseChoice.allCases) { option in
                        Button {
                            choice = option
                        } label: {
                            HStack {
                                Text(option.title).foregroundColor(Brand.text)
                                Spacer()
                                Image(systemName: choice == option ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(choice == option ? Brand.accent : Brand.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Brand.card)

                Section {
                    TextField("Причина (необязательно)", text: $reason)
                        .onChange(of: reason) { value in
                            if value.count > 120 { reason = String(value.prefix(120)) }
                        }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Az.reasonChips, id: \.self) { chip in
                                FilterChip(title: chip, selected: reason == chip) { reason = chip }
                            }
                        }
                    }
                } footer: {
                    Text(choice.hint)
                }
                .listRowBackground(Brand.card)

                if let err = error {
                    Section {
                        Text(err).font(.footnote).foregroundColor(Brand.red)
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView() }
                            Text("Поставить на паузу").font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(busy)
                    Button("Отмена", role: .cancel) { dismiss() }
                        .frame(maxWidth: .infinity)
                        .disabled(busy)
                }
                .listRowBackground(Brand.card)
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Пауза приёма заказов")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(busy)
    }

    private func submit() async {
        guard !busy else { return }
        busy = true
        error = nil
        let failure = await onConfirm(choice.request(reason: reason))
        busy = false
        if let failure {
            error = failure   // окно остаётся открытым — можно выбрать другой срок
        } else {
            dismiss()
        }
    }
}
