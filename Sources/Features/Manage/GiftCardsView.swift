import SwiftUI

// ============================================================================
//  Подарочные карты — GET/POST /api/seller/giftcards,
//  DELETE /api/seller/giftcards/{id}.
//
//  Право — «Клиенты» (customers): карты продаются покупателям, это работа зала,
//  а не настройка магазина. Так же размечено на сервере.
//
//  Код карты придумывает сервер (GC-XXXXXXXX) — в приложении его нельзя задать,
//  иначе два продавца создали бы одинаковый код (в базе он UNIQUE).
//  DELETE не удаляет карту, а гасит её (status=expired): по оплаченной карте
//  должна остаться история.
// ============================================================================

@MainActor
final class GiftCardsViewModel: ObservableObject {
    @Published var items: [GiftCard] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    /// Код только что созданной карты — показываем, чтобы продавец мог его продиктовать.
    @Published var createdCode: String?

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.giftCards()
            state = .loaded
            // Удачное перечитывание снимает старую красную строку — раньше
            // ошибка прошлого обновления висела над свежим списком.
            error = nil
        } catch is CancellationError {
        } catch {
            if items.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    /// keys — ключи повтора окна выпуска (живут, пока окно открыто).
    func create(amount: Decimal, expiresAt: Date?, keys: IdempotencyKeys? = nil) async -> Bool {
        error = nil
        var expires: String?
        if let d = expiresAt {
            // «Действует до 31.12» — это КАЛЕНДАРНАЯ дата устройства,
            // включительно до конца дня. Раньше дата без времени (пикер .date
            // оставляет текущее локальное время) пересчитывалась в МСК: во
            // Владивостоке утром карта гасла на день раньше, в Калининграде
            // вечером — жила лишний день. DateFmt.ymd для того и существует.
            expires = DateFmt.ymd(d) + " 23:59:59"
        }
        let before = Set(items.map(\.cardId))
        // Список не был загружен — «before» пуст, и любая старая карта сошла бы
        // за новую: после обрыва показали бы чужой код. Сверяем только по загруженному.
        let listKnown = state == .loaded
        do {
            let ack = try await API.shared.createGiftCard(amount: amount, expiresAt: expires, keys: keys)
            createdCode = ack.code
            await load()
            return true
        } catch {
            let msg = error.localizedDescription
            // Обрыв связи или таймаут: карта могла уже выпуститься. Раньше окно
            // оставалось с ошибкой, и повторное «Выпустить» давало вторую карту
            // с деньгами. Перечитываем: появилась ровно одна новая карта этого
            // номинала — это она, показываем её код.
            var dropped = false
            if let e = error as? APIError {
                switch e {
                case .network, .timeout: dropped = true
                default: break
                }
            }
            if dropped && listKnown {
                await load()
                let fresh = items.filter { !before.contains($0.cardId) && $0.amount == amount && $0.isActive }
                if fresh.count == 1 {
                    createdCode = fresh[0].code
                    self.error = nil
                    return true
                }
            }
            self.error = msg
            return false
        }
    }

    /// Погашение этой карты уже в пути: пока ответа нет, карта всё ещё
    /// «Активна», её гасили второй раз — и в журнал безопасности уходило
    /// два «гашения» одной карты. Повтор во время запроса пропускаем.
    private var deactivatingIds: Set<Int> = []

    func deactivate(_ card: GiftCard) async {
        guard !deactivatingIds.contains(card.cardId) else { return }
        deactivatingIds.insert(card.cardId)
        defer { deactivatingIds.remove(card.cardId) }
        error = nil
        do {
            try await API.shared.deactivateGiftCard(id: card.cardId)
            await load()
        } catch {
            // Карту уже погасили или потратили на кассе, либо связь оборвалась
            // после погашения: перечитываем, иначе она оставалась «Активна» с
            // кнопкой «Погасить», дающей ту же ошибку. Текст — после load().
            let msg = error.localizedDescription
            await load()
            self.error = msg
        }
    }
}

struct GiftCardsView: View {
    @StateObject private var vm = GiftCardsViewModel()
    @State private var showCreate = false
    /// Погашение необратимо (включить карту обратно нельзя), а на ней деньги
    /// клиента — спрашиваем.
    @State private var deactivateTarget: GiftCard?

    /// Выпуск и гашение карты — деньги, как ручное начисление баллов: сервер
    /// пускает только с правом «Начислять бонусы» (StaffAccess::actionPerms →
    /// customers.bonus). Без него «Выпустить» и «Погасить» вели к 403.
    private var canMoney: Bool { Session.shared.can("customers.bonus") }

    var body: some View {
        List {
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            if let code = vm.createdCode {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Карта создана").font(.caption).foregroundColor(Brand.muted)
                        Text(code).font(.headline.monospaced()).foregroundColor(Brand.text)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("Копировать", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                }
                .listRowBackground(Brand.card)
            }
            ForEach(vm.items) { card in
                GiftCardRow(card: card)
                    .listRowBackground(Brand.card)
                    // Без полного свайпа: длинный жест сразу гасил оплаченную
                    // карту клиента (обратно не включить) — только кнопкой.
                    .swipeActions(allowsFullSwipe: false) {
                        if card.isActive && canMoney {
                            Button(role: .destructive) {
                                deactivateTarget = card
                            } label: {
                                Label("Погасить", systemImage: "xmark.circle")
                            }
                        }
                    }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "giftcard", emptyTitle: "Карт нет",
                   emptySubtitle: canMoney ? "Выпустите карту на нужный номинал — код сгенерирует сервер"
                                           : "Выпускает карты владелец или сотрудник с правом начислять бонусы",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Подарочные карты")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // Ошибка прошлого действия (погашение, обновление) показывалась
                // в новом окне выпуска, будто отказали в выпуске карты.
                if canMoney {
                    Button { vm.error = nil; showCreate = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .confirmationDialog(
            "Погасить карту?",
            isPresented: Binding(get: { deactivateTarget != nil }, set: { if !$0 { deactivateTarget = nil } }),
            titleVisibility: .visible,
            presenting: deactivateTarget
        ) { card in
            Button("Погасить \(card.code ?? "карту")", role: .destructive) {
                let c = card
                deactivateTarget = nil
                Task { await vm.deactivate(c) }
            }
            Button("Отмена", role: .cancel) { deactivateTarget = nil }
        } message: { card in
            Text("Остаток \(Money.rub(card.balance)) сгорит, включить карту обратно будет нельзя.")
        }
        .sheet(isPresented: $showCreate) { GiftCardCreateSheet(vm: vm) }
        .task { await vm.load() }
    }
}

private struct GiftCardRow: View {
    let card: GiftCard
    /// Код только что скопирован — галочка вместо значка на пару секунд.
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(card.code ?? "—")
                    .font(.subheadline.weight(.bold).monospaced())
                    .foregroundColor(Brand.text)
                    .textSelection(.enabled)
                // Паритет с Android: «Копировать код» у каждой карты, а не только
                // у только что выпущенной (клиент звонит и просит продиктовать код).
                if let code = card.code, !code.isEmpty {
                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                            .foregroundColor(copied ? Brand.green : Brand.accent)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Копировать код")
                }
                Spacer()
                StatusBadge(text: card.statusTitle, color: color)
            }
            HStack(spacing: 10) {
                Text("номинал \(Money.rub(card.amount))")
                Text("остаток \(Money.rub(card.balance))")
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
            if let exp = card.expiresAt, !exp.isEmpty {
                Text("действует до " + Self.expiryText(exp))
                    .font(.caption2).foregroundColor(Brand.muted)
            }
        }
        .padding(.vertical, 3)
    }

    /// Срок карты. «Конец дня» (23:59, так ставит выпуск из приложения) — это
    /// календарный день: показываем его без перевода в пояс телефона, иначе
    /// восточнее Москвы он «переезжал» на следующий день. Остальные сроки —
    /// как все даты приложения (DateFmt.short; другой год — с годом).
    private static func expiryText(_ exp: String) -> String {
        let time = exp.count >= 16 ? String(exp.dropFirst(11).prefix(5)) : ""
        if time.isEmpty || time == "23:59" { return DateFmt.day(String(exp.prefix(10))) }
        return DateFmt.short(exp)
    }

    private var color: Color {
        switch card.status ?? "" {
        case "active": return Brand.green
        case "used":   return Brand.muted
        default:       return Brand.amber
        }
    }
}

private struct GiftCardCreateSheet: View {
    @ObservedObject var vm: GiftCardsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var amountText = ""
    @State private var hasExpiry = false
    @State private var expiresAt = Date().addingTimeInterval(365 * 86400)
    @State private var sending = false
    /// Ключ повтора — на это окно: закрыли — пропал, следующая карта того же номинала — новая.
    @State private var idem = IdempotencyKeys.form()

    /// Предел номинала на сервере.
    private static let maxAmount: Decimal = 100_000

    // Строго: «1 500» с неразрывным пробелом раньше давало карту на 1 ₽.
    private var amount: Decimal? { Money.strict(amountText.trimmingCharacters(in: .whitespaces)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Номинал, ₽", text: $amountText).keyboardType(.decimalPad)
                    Toggle("Ограничить срок", isOn: $hasExpiry)
                    if hasExpiry {
                        // Уже просроченную карту выпустить нельзя.
                        DatePicker("Действует до", selection: $expiresAt, in: Date()..., displayedComponents: .date)
                    }
                } footer: {
                    // Номинал больше 100 000 ₽ сервер не примет (seller_settings.php,
                    // POST giftcards) — говорим об этом до нажатия «Выпустить».
                    if let a = amount, a > Self.maxAmount {
                        Text("Номинал — не больше 100 000 ₽.").foregroundColor(Brand.red)
                    } else {
                        Text("Код карты сгенерирует сервер — задать свой нельзя, коды должны быть уникальными.")
                    }
                }
                .listRowBackground(Brand.card)

                if let err = vm.error {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Новая карта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Пока карта выпускается, окно не закрываем: ключ повтора живёт с окном, и
                // повтор из нового окна ушёл бы с новым ключом — вторая карта.
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(sending) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Выпустить") {
                        // Флаг — сразу, до Task: два тапа в одном кадре выпускали две карты.
                        guard !sending, let a = amount else { return }
                        sending = true
                        Task {
                            let ok = await vm.create(amount: a, expiresAt: hasExpiry ? expiresAt : nil, keys: idem)
                            sending = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(sending || (amount ?? 0) <= 0 || (amount ?? 0) > Self.maxAmount)
                }
            }
            .interactiveDismissDisabled(sending)
        }
    }
}
