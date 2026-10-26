import SwiftUI

// ============================================================================
//  Хаб раздела «Услуги» (type=service): Услуги / Мастера / Расписание.
// ============================================================================

struct ServicesHubView: View {
    @State private var section = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Раздел", selection: $section) {
                    Text("Услуги").tag(0)
                    Text("Мастера").tag(1)
                    Text("Расписание").tag(2)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                switch section {
                case 1: MastersView()
                case 2: SlotsView()
                default: ServicesListView()
                }
            }
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Услуги")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .principal) { ShopSwitcherMenu() } }
        }
    }
}

// ============================================================================
//  Услуги — GET/POST/PUT/DELETE /api/seller/services.
// ============================================================================

@MainActor
final class ServicesViewModel: ObservableObject {
    @Published var items: [ServiceItem] = []
    @Published var masters: [Master] = []
    /// Категории организации — те же, что у товаров: в них кладут услуги.
    @Published var categories: [SellerCategory] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.services()
            masters = (try? await API.shared.masters()) ?? masters
            // Ошибку загрузки категорий НЕ показываем: без них услуги всё равно
            // редактируются, просто список в поле будет пустым.
            categories = (try? await API.shared.categories()) ?? categories
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func save(id: Int?, name: String, description: String?, duration: Int, buffer: Int,
              price: Decimal, masterId: Int?, isActive: Bool,
              categoryId: Int, sortOrder: Int) async -> Bool {
        error = nil
        // Снимок до создания: по нему узнаём новую услугу, если ответ не дошёл.
        let before = Set(items.map(\.serviceId))
        let listKnown = state == .loaded
        do {
            if let id = id {
                try await API.shared.updateService(id: id, name: name, description: description,
                                                   durationMin: duration, bufferMin: buffer,
                                                   price: price, masterId: masterId, isActive: isActive,
                                                   categoryId: categoryId, sortOrder: sortOrder)
            } else {
                _ = try await API.shared.createService(name: name, description: description,
                                                       durationMin: duration, bufferMin: buffer,
                                                       price: price, masterId: masterId,
                                                       categoryId: categoryId, sortOrder: sortOrder)
            }
            await load()
            return true
        } catch {
            let msg = error.localizedDescription
            // Обрыв, таймаут или непонятный ответ на создание (П-24: состав
            // ответа не подтверждён): услуга могла уже создаться, а повторное
            // «Сохранить» давало дубль. Перечитываем: появилась ровно одна новая
            // услуга с этим названием — это она, лист закрываем.
            if id == nil, listKnown, Self.maybeSaved(error) {
                await load()
                let wanted = name.trimmingCharacters(in: .whitespaces)
                let fresh = items.filter {
                    !before.contains($0.serviceId) && ($0.name ?? "").trimmingCharacters(in: .whitespaces) == wanted
                }
                if fresh.count == 1 { return true }
            }
            self.error = msg
            return false
        }
    }

    private static func maybeSaved(_ error: Error) -> Bool {
        guard let e = error as? APIError else { return false }
        switch e {
        case .network, .timeout, .decoding: return true
        default: return false
        }
    }

    /// Сервер деактивирует услугу и удаляет свободные слоты (занятые записи не трогает).
    func remove(_ service: ServiceItem) async {
        error = nil
        do {
            try await API.shared.deleteService(id: service.serviceId)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ServicesListView: View {
    @StateObject private var vm = ServicesViewModel()
    @State private var editTarget: ServiceItem?
    @State private var showCreate = false
    /// Паритет с Android: удаление услуги (и её свободного расписания) — с вопросом.
    @State private var deleteTarget: ServiceItem?

    var body: some View {
        List {
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
            }
            ForEach(vm.items) { service in
                Button { editTarget = service } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(service.name ?? "Услуга")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(Brand.text)
                            if service.isActive != true {
                                StatusBadge(text: "Выключена", color: Brand.muted)
                            }
                            Spacer()
                            // Цена 0 — бесплатная услуга (так и сказано в форме):
                            // в списке стояло «0 ₽».
                            Text((service.price ?? 0) > 0 ? Money.rub(service.price) : "Бесплатно")
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(Brand.text)
                        }
                        HStack(spacing: 10) {
                            Label("\(service.durationMin ?? 30) мин", systemImage: "clock")
                            if let buffer = service.bufferMin, buffer > 0 {
                                Label("буфер \(buffer) мин", systemImage: "hourglass")
                            }
                            if let m = service.master, !m.isEmpty {
                                Label(m, systemImage: "person")
                            }
                            // Место услуги в списке задаёт порядок КАТЕГОРИИ —
                            // пусть продавец видит, в какой она лежит.
                            if let cat = service.categoryName, !cat.isEmpty {
                                Label(cat, systemImage: "folder")
                            }
                        }
                        .font(.caption)
                        .foregroundColor(Brand.muted)
                    }
                }
                .listRowBackground(Brand.card)
                // Без полного свайпа: длинный жест удалял услугу (и её расписание)
                // без вопроса — только нажатием кнопки.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = service
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Удалить услугу?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { service in
            Button("Удалить «\(service.name ?? "услугу")»", role: .destructive) {
                let s = service
                deleteTarget = nil
                Task { await vm.remove(s) }
            }
            Button("Отмена", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("Свободные окна расписания этой услуги удалятся. Записи клиентов останутся.")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "scissors", emptyTitle: "Услуг пока нет",
                   emptySubtitle: "Добавьте первую услугу",
                   retry: { Task { await vm.load() } })
        .safeAreaInset(edge: .bottom) {
            Button { showCreate = true } label: {
                Label("Новая услуга", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .background(Brand.accent)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
        .sheet(item: $editTarget) { service in
            ServiceEditSheet(vm: vm, service: service)
                .errorAlert($vm.error)
        }
        .sheet(isPresented: $showCreate) {
            ServiceEditSheet(vm: vm, service: nil)
                .errorAlert($vm.error)
        }
        .task { await vm.load() }
    }
}

struct ServiceEditSheet: View {
    @ObservedObject var vm: ServicesViewModel
    let service: ServiceItem?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var descriptionText = ""
    @State private var duration = 30
    @State private var buffer = 0
    @State private var price = ""
    @State private var masterId: Int?
    @State private var isActive = true
    @State private var isSaving = false
    /// 0 — «без категории» (см. API.createService).
    @State private var categoryId = 0
    @State private var sortOrder = 0
    @State private var didInit = false

    /// Длительность или буфер существующей услуги изменены.
    private var gridChanged: Bool {
        guard let s = service else { return false }
        return duration != (s.durationMin ?? 30) || buffer != (s.bufferMin ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Услуга") {
                    TextField("Название", text: $name)
                    TextField("Описание", text: $descriptionText, axis: .vertical).lineLimit(2...5)
                    TextField("Цена, ₽", text: $price).keyboardType(.decimalPad)
                }
                Section {
                    // Паритет с Android: сервер требует только ≥ 5 мин (seller_services.php,
                    // max(5, duration_min)), предел 1440 — как на Android. Услугу на 10 ч,
                    // заведённую на Android или сайте, iOS урезал до 480 при любой правке.
                    Stepper("Длительность: \(duration) мин", value: $duration, in: 5...1440, step: 5)
                    Stepper("Буфер: \(buffer) мин", value: $buffer, in: 0...1440, step: 5)
                } header: {
                    Text("Время")
                } footer: {
                    // Сервер при смене длительности или буфера удаляет СВОБОДНЫЕ
                    // будущие окна (routes/seller_services.php, PUT services/{id}),
                    // а приложение об этом молчало — запись у клиентов пропадала.
                    if gridChanged {
                        Text("После сохранения свободные будущие окна этой услуги удалятся — создайте расписание заново во вкладке «Расписание». Окна с записями останутся.")
                            .foregroundColor(Brand.amber)
                    }
                }
                Section("Мастер") {
                    Picker("Мастер", selection: $masterId) {
                        Text("Не назначен").tag(Int?.none)
                        ForEach(vm.masters) { m in
                            Text(m.name ?? "—").tag(Int?.some(m.masterId))
                        }
                    }
                }
                // Категория — та же, что у товаров. Место услуги в списке у
                // клиента задаёт ПОРЯДОК КАТЕГОРИИ (меняется в «Категориях»),
                // а Stepper ниже — порядок внутри самой категории.
                Section {
                    Picker("Категория", selection: $categoryId) {
                        Text("Без категории").tag(0)
                        ForEach(vm.categories) { cat in
                            Text(cat.name ?? "—").tag(cat.categoryId)
                        }
                    }
                    Stepper("Порядок в категории: \(sortOrder)", value: $sortOrder, in: 0...999)
                } header: {
                    Text("Категория")
                } footer: {
                    Text(vm.categories.isEmpty
                         ? "Категорий пока нет — создайте их в разделе «Категории»."
                         : "Место в списке задаёт порядок категории.")
                }
                if service != nil {
                    Section { Toggle("Услуга активна", isOn: $isActive) }
                }
                Section {
                    Button {
                        guard !isSaving, let p = Money.strict(price) else { return }
                        isSaving = true
                        Task {
                            let ok = await vm.save(id: service?.serviceId, name: name,
                                                   // Правка: пустое описание шлём строкой, иначе
                                                   // ключ выпадает и старое описание остаётся.
                                                   description: (descriptionText.isEmpty && service == nil) ? nil : descriptionText,
                                                   duration: duration, buffer: buffer,
                                                   price: p, masterId: masterId, isActive: isActive,
                                                   categoryId: categoryId, sortOrder: sortOrder)
                            isSaving = false
                            if ok { dismiss() }
                        }
                    } label: {
                        HStack { Spacer(); if isSaving { ProgressView() } else { Text("Сохранить").bold() }; Spacer() }
                    }
                    // Цена обязательна и разбирается строго: пустое поле раньше
                    // сохранялось как 0 ₽, а «1 500» — как 1 ₽.
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || Money.strict(price) == nil)
                } footer: {
                    // Серая «Сохранить» без причины выглядела сломанной: чаще
                    // всего не заполнена цена (у бесплатной услуги — 0).
                    if name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Укажите название услуги.").foregroundColor(Brand.amber)
                    } else if Money.strict(price) == nil {
                        Text("Укажите цену числом, например 1500 или 1500,50 (0 — бесплатно).").foregroundColor(Brand.amber)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(service == nil ? "Новая услуга" : "Услуга")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
            .onAppear {
                guard !didInit else { return }
                didInit = true
                if let s = service {
                    name = s.name ?? ""
                    descriptionText = s.description ?? ""
                    duration = s.durationMin ?? 30
                    buffer = s.bufferMin ?? 0
                    price = s.price.map { "\($0)" } ?? ""
                    masterId = s.masterId
                    isActive = s.isActive ?? true
                    categoryId = s.categoryId ?? 0
                    sortOrder = s.sortOrder ?? 0
                }
            }
        }
        // Смахивание листа вниз стирало заполненную услугу (название, описание,
        // цену) без вопроса. С правками закрыть — только кнопкой «Отмена».
        .interactiveDismissDisabled(isSaving || hasChanges)
    }

    /// Что-то изменено относительно открытой услуги (или новой).
    private var hasChanges: Bool {
        let n0: String = service?.name ?? ""
        let d0: String = service?.description ?? ""
        let p0: String = service?.price.map { "\($0)" } ?? ""
        return name != n0 || descriptionText != d0 || price != p0
    }
}
