import SwiftUI

// ============================================================================
//  Буст-продвижение — GET /api/seller/boost (цены/день, баланс, статус буста
//  магазина), покупка POST /api/seller/boost {days 1–30, product_id?}.
//  Оплата — с предоплаченного кошелька (walletApply, type='promo');
//  при нехватке средств сервер отвечает 402 с текстом — показываем как есть.
//  Сумма подтверждается явным диалогом ДО списания.
// ============================================================================

@MainActor
final class BoostViewModel: ObservableObject {
    @Published var info: BoostInfo?
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var success: String?
    @Published var isBuying = false
    /// Исход последней оплаты неизвестен (обрыв, таймаут, 5xx): параметры покупки
    /// заблокированы, «Повторить оплату» уходит тем же телом с тем же ключом —
    /// сервер второй раз не спишет. nil — обычное состояние.
    @Published var pending: BoostPending?

    func load() async {
        if info == nil { state = .loading }
        do {
            info = try await API.shared.boostInfo()
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// keys — ключи экрана (IdempotencyKeys.form()): один ключ на одну покупку,
    /// тот же при повторе после обрыва; после ответа сервера ключ забыт (postKeyed).
    func buy(days: Int, productId: Int?, expectedCost: Decimal, keys: IdempotencyKeys) async {
        // Двойной тап по «Оплатить» не должен списать деньги дважды.
        guard !isBuying else { return }
        isBuying = true
        defer { isBuying = false }
        error = nil
        success = nil
        let balanceBefore = info?.balance
        do {
            let ack = try await API.shared.buyBoost(days: days, productId: productId, keys: keys)
            pending = nil
            success = "Продвижение включено до \(DateFmt.short(ack.boostUntil)), списано \(Money.rub(ack.charged))"
            await load()
        } catch {
            let msg = error.localizedDescription
            // Обрыв связи, таймаут, 5xx в любом виде или «первый запрос ещё идёт»:
            // деньги могли уже списаться, ключ postKeyed сохранил. Перечитываем:
            // баланс уменьшился ровно на сумму — оплата прошла.
            if API.keyedOutcomeUnknown(error) {
                await load()
                // Оплатой считаем только списание ровно на сумму буста: баланс мог
                // упасть и по другой причине (другое списание) — тогда не обещаем «прошла».
                if let b = balanceBefore, let now = info?.balance, now < b, b - now == expectedCost {
                    pending = nil
                    keys.forgetAll()   // оплата видна — ключ больше не нужен
                    success = "Связь прервалась, но оплата прошла: списано \(Money.rub(b - now)). Повторять не нужно."
                    return
                }
                // Исход неизвестен: ключ остаётся (postKeyed его не забыл), параметры
                // блокируем — «Повторить оплату» уйдёт тем же телом с тем же ключом.
                pending = BoostPending(days: days, productId: productId, cost: expectedCost)
                self.error = msg + ". Списания пока не видно — нажмите «Повторить оплату»: второй раз не спишется."
                return
            }
            pending = nil
            self.error = msg
        }
    }
}

/// Параметры покупки с неизвестным исходом — повтор уходит ровно с ними.
struct BoostPending: Equatable {
    let days: Int
    let productId: Int?
    let cost: Decimal
}

struct BoostView: View {
    @EnvironmentObject var session: Session
    @StateObject private var vm = BoostViewModel()
    @State private var days = 7
    @State private var boostProduct = false
    @State private var selectedProduct: ProductSummary?
    @State private var showProductPicker = false
    @State private var showConfirm = false
    /// Ключ повтора — на этот экран (закрыли — пропал): повтор оплаты после обрыва
    /// уходит с тем же Idempotency-Key, и сервер не списывает второй раз.
    @State private var idem = IdempotencyKeys.form()

    private var pricePerDay: Decimal {
        (boostProduct ? vm.info?.priceDayProduct : vm.info?.priceDayShop) ?? 0
    }
    private var totalCost: Decimal { pricePerDay * Decimal(days) }
    /// Сервер продаёт продвижение только организации со статусом active
    /// (seller_promotions.php, POST boost → 409 для draft/review/paused).
    private var notOnShowcase: Bool { session.shopStatus != "active" }
    /// Параметры покупки не правим, пока оплата в пути или её исход неизвестен.
    private var locked: Bool { vm.isBuying || vm.pending != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let info = vm.info {
                    statusCard(info)
                    configCard(info)
                    if let msg = vm.success {
                        Text(msg).font(.footnote.weight(.semibold)).foregroundColor(Brand.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let err = vm.error {
                        Text(err).font(.footnote.weight(.semibold)).foregroundColor(Brand.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Продвижение")
        .navigationBarTitleDisplayMode(.inline)
        // Пока оплата в пути — с экрана не уходим (ключ повтора живёт с экраном):
        // без кнопки «Назад» не работает и жест смахивания.
        .navigationBarBackButtonHidden(vm.isBuying)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.info == nil,
                   emptyIcon: "arrow.up.circle", emptyTitle: "Нет данных",
                   retry: { Task { await vm.load() } })
        .confirmationDialog(
            "Списать \(Money.rub(vm.pending?.cost ?? totalCost)) с кошелька за \(vm.pending?.days ?? days) дн. продвижения?",
            isPresented: $showConfirm, titleVisibility: .visible
        ) {
            Button((vm.pending == nil ? "Оплатить " : "Повторить оплату ") + Money.rub(vm.pending?.cost ?? totalCost)) {
                // Повтор после неизвестного исхода — ровно те же параметры (и тот же ключ).
                let p = vm.pending
                let cost = p?.cost ?? totalCost
                let d = p?.days ?? days
                let pid = p != nil ? p?.productId : (boostProduct ? selectedProduct?.productId : nil)
                Task { await vm.buy(days: d, productId: pid, expectedCost: cost, keys: idem) }
            }
        }
        .sheet(isPresented: $showProductPicker) {
            BoostProductPicker(onPick: { selectedProduct = $0 })
        }
        .task { await vm.load() }
    }

    private func statusCard(_ info: BoostInfo) -> some View {
        SectionCard(title: "Статус") {
            if info.shopBoostActive == true, let until = info.shopBoostUntil {
                Label("Магазин в топе до \(DateFmt.short(until))", systemImage: "flame.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.green)
            } else {
                Label("Продвижение магазина не активно", systemImage: "flame")
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
            }
            InfoRow(label: "Баланс кошелька", value: Money.rub(info.balance))
        }
    }

    private func configCard(_ info: BoostInfo) -> some View {
        SectionCard(title: "Включить продвижение") {
            if session.shopType != "service" {
                Picker("Что продвигаем", selection: $boostProduct) {
                    Text("Магазин · \(Money.rub(info.priceDayShop))/дн").tag(false)
                    Text("Товар · \(Money.rub(info.priceDayProduct))/дн").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(locked)
            }
            if boostProduct {
                Button {
                    showProductPicker = true
                } label: {
                    HStack {
                        Text(selectedProduct?.name ?? "Выберите товар")
                            .foregroundColor(selectedProduct == nil ? Brand.muted : Brand.text)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundColor(Brand.muted)
                    }
                    .padding(10)
                    .background(Brand.chip)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(locked)
            }
            Stepper("Дней: \(days)", value: $days, in: 1...30)
                .disabled(locked)
            HStack {
                Text("Итого к списанию").font(.subheadline).foregroundColor(Brand.muted)
                Spacer()
                Text(Money.rub(totalCost))
                    .font(.title3.weight(.bold))
                    .foregroundColor(Brand.text)
            }
            Button {
                showConfirm = true
            } label: {
                Text(vm.pending == nil ? "Оплатить с кошелька" : "Повторить оплату")
                    .font(.subheadline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            // Покупка продвижения — отдельное право (как на Android): без него
            // сотрудник проходил путь до оплаты и получал 403.
            .disabled(vm.isBuying || totalCost <= 0 || (boostProduct && selectedProduct == nil)
                      || !Session.shared.can("promotions.boost") || notOnShowcase)
            // Кнопка без права была просто серой — сотрудник не понимал почему.
            if !Session.shared.can("promotions.boost") {
                Text("Покупка продвижения недоступна вашей роли — попросите владельца или администратора.")
                    .font(.caption)
                    .foregroundColor(Brand.amber)
            }
            // Новая (не опубликованная) или приостановленная организация: сервер
            // отвечает 409 «продвижение не даст показов» — уже после диалога оплаты.
            if notOnShowcase {
                Text("Организация сейчас не показывается клиентам (не опубликована или на паузе) — продвижение станет доступно, когда она появится на витрине.")
                    .font(.caption)
                    .foregroundColor(Brand.amber)
            } else if let bal = info.balance, totalCost > 0, bal < totalCost {
                // Нулевой кошелёк новой организации: причину отказа (402) видно заранее.
                Text("На кошельке не хватает \(Money.rub(totalCost - bal)) — пополните его в разделе «Кошелёк».")
                    .font(.caption)
                    .foregroundColor(Brand.amber)
            }
            // Исход прошлой оплаты неизвестен: параметры заблокированы до повтора.
            // «Отменить повтор» — как закрыть окно: ключ забыт, следующая оплата — новая.
            if vm.pending != nil && !vm.isBuying {
                Button("Отменить повтор (сначала проверьте баланс)") {
                    idem.forgetAll()
                    vm.pending = nil
                    vm.error = nil
                }
                .font(.caption)
                .foregroundColor(Brand.muted)
            }
            // Экран везде говорит «продвижение» — жаргонное «буст» убрано.
            Text("Списание с предоплаченного кошелька. Продление прибавляет дни к текущему продвижению.")
                .font(.caption2)
                .foregroundColor(Brand.muted)
        }
    }
}

/// Выбор товара для буста — GET /api/seller/products?q=&page= (первая страница + поиск).
private struct BoostProductPicker: View {
    let onPick: (ProductSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ProductSummary] = []
    @State private var query = ""
    @State private var state: LoadState = .idle
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List(items) { product in
                Button {
                    onPick(product)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        RemoteImage(path: product.photo, size: 40, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(product.name ?? "—")
                                .font(.subheadline).foregroundColor(Brand.text).lineLimit(1)
                            Text(Money.rub(product.price))
                                .font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                }
                .listRowBackground(Brand.card)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Поиск товара")
            .onChange(of: query) { _ in
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled else { return }
                    await load()
                }
            }
            .listState(state, isEmpty: items.isEmpty,
                       emptyIcon: "square.grid.2x2", emptyTitle: "Товары не найдены",
                       // Новая организация без товаров: подсказываем, откуда они берутся.
                       emptySubtitle: query.isEmpty ? "Продвигать можно только товары на витрине — добавьте или включите товар в каталоге" : nil,
                       retry: { Task { await load() } })
            .navigationTitle("Товар для продвижения")   // было жаргонное «буста»
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        if items.isEmpty { state = .loading }
        // Запрос по прежнему тексту, пришедший позже нового, перетирал выдачу:
        // ищешь «сыр», а в списке — товары по «с». Чужой ответ не применяем.
        let asked = query
        do {
            let page = try await API.shared.products(category: nil, status: "active", q: asked, page: 1)
            guard asked == query else { return }
            items = page.items
            state = .loaded
        } catch is CancellationError {
        } catch {
            guard asked == query else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
