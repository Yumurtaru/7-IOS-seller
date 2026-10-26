import SwiftUI

// ============================================================================
//  Вакансии и отклики — GET/POST /api/seller/vacancies,
//  PUT/DELETE /api/seller/vacancies/{id},
//  GET /api/seller/vacancies/{id}/applications,
//  POST /api/seller/applications/{id}/status.
//
//  Право — «Сотрудники» (employees), так размечено на сервере: наём это работа
//  кадровика, а не продавца зала.
// ============================================================================

@MainActor
final class VacanciesViewModel: ObservableObject {
    @Published var items: [Vacancy] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.vacancies()
            state = .loaded
            // Удачное перечитывание снимает старую ошибку: раньше красная
            // строка прошлого сбоя висела над свежим списком навсегда.
            error = nil
        } catch is CancellationError {
        } catch {
            if items.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    /// Удаление вакансии в пути: строка висит до ответа, второе «Удалить»
    /// получало 404 «Вакансия не найдена» поверх удачного удаления.
    private var deletingIds: Set<Int> = []

    func delete(_ v: Vacancy) async {
        guard !deletingIds.contains(v.vacancyId) else { return }
        deletingIds.insert(v.vacancyId)
        defer { deletingIds.remove(v.vacancyId) }
        error = nil
        do {
            try await API.shared.deleteVacancy(id: v.vacancyId)
            items.removeAll { $0.vacancyId == v.vacancyId }
        } catch {
            // Вакансию уже удалили (сайт, другой телефон) или связь оборвалась
            // после удаления: перечитываем, иначе строка оставалась, и каждое
            // «Удалить» давало ту же ошибку. load() снимает ошибку — текст после.
            let msg = error.localizedDescription
            await load()
            self.error = msg
        }
    }
}

struct VacanciesView: View {
    @StateObject private var vm = VacanciesViewModel()
    @State private var editing: VacancyEditTarget?
    /// Паритет с Android: удаление вакансии вместе с откликами — с подтверждением.
    @State private var deleteTarget: Vacancy?

    var body: some View {
        List {
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            ForEach(vm.items) { v in
                NavigationLink {
                    ApplicationsView(vacancy: v)
                } label: {
                    VacancyRow(vacancy: v)
                }
                .listRowBackground(Brand.card)
                // Без полного свайпа: длинный жест удалял вакансию вместе с
                // откликами без вопроса — только кнопкой.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deleteTarget = v
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                    Button {
                        editing = VacancyEditTarget(vacancy: v)
                    } label: {
                        Label("Изменить", systemImage: "pencil")
                    }
                    .tint(Brand.accent)
                }
            }
        }
        .confirmationDialog(
            "Удалить вакансию?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { v in
            Button("Удалить «\(v.title ?? "вакансию")»", role: .destructive) {
                let target = v
                deleteTarget = nil
                Task { await vm.delete(target) }
            }
            Button("Отмена", role: .cancel) { deleteTarget = nil }
        } message: { _ in
            Text("Вакансия и её отклики перестанут показываться на витрине.")
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "person.badge.plus", emptyTitle: "Вакансий нет",
                   emptySubtitle: "Опубликуйте вакансию — отклики придут сюда",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Вакансии")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editing = VacancyEditTarget(vacancy: nil) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { target in
            VacancyEditSheet(target: target) { await vm.load() }
        }
        .task { await vm.load() }
    }
}

/// Обёртка для .sheet(item:) — nil внутри означает «создаём новую».
struct VacancyEditTarget: Identifiable {
    let vacancy: Vacancy?
    var id: Int { vacancy?.vacancyId ?? 0 }
}

private struct VacancyRow: View {
    let vacancy: Vacancy

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(vacancy.title ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Spacer()
                StatusBadge(text: vacancy.state.title, color: statusColor)
            }
            Text(vacancy.salaryLabel)
                .font(.caption.weight(.medium))
                .foregroundColor(Brand.text)
            HStack(spacing: 8) {
                Text(vacancy.kind.title)
                Text(vacancy.employment.title)
                if let s = vacancy.schedule, !s.isEmpty { Text(s) }
            }
            .font(.caption)
            .foregroundColor(Brand.muted)
            HStack(spacing: 10) {
                Label("\(vacancy.apps ?? 0)", systemImage: "tray.full")
                if (vacancy.newApps ?? 0) > 0 {
                    StatusBadge(text: "новых: \(vacancy.newApps ?? 0)", color: Brand.accent)
                }
                Label("\(vacancy.viewsCount ?? 0)", systemImage: "eye")
            }
            .font(.caption2)
            .foregroundColor(Brand.muted)
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch vacancy.state {
        case .open:   return Brand.green
        case .paused: return Brand.amber
        case .closed: return Brand.muted
        }
    }
}

// ── Редактирование вакансии ──────────────────────────────────────────────────

private struct VacancyEditSheet: View {
    let target: VacancyEditTarget
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var category: VacancyCategory = .other
    @State private var employment: VacancyEmployment = .full
    @State private var experience: VacancyExperience = .none
    @State private var status: VacancyStatus = .open
    @State private var schedule = ""
    @State private var address = ""
    @State private var salaryFrom = ""
    @State private var salaryTo = ""
    @State private var descriptionText = ""
    @State private var requirements = ""
    @State private var conditions = ""
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Вакансия") {
                    TextField("Название (например, Повар горячего цеха)", text: $title)
                    Picker("Профессия", selection: $category) {
                        ForEach(VacancyCategory.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Занятость", selection: $employment) {
                        ForEach(VacancyEmployment.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Опыт", selection: $experience) {
                        ForEach(VacancyExperience.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Статус", selection: $status) {
                        ForEach(VacancyStatus.allCases) { Text($0.title).tag($0) }
                    }
                }
                .listRowBackground(Brand.card)

                Section {
                    TextField("Зарплата от", text: $salaryFrom).keyboardType(.numberPad)
                    TextField("Зарплата до", text: $salaryTo).keyboardType(.numberPad)
                    TextField("График (2/2, с 9:00 до 21:00)", text: $schedule)
                    TextField("Адрес", text: $address)
                } header: {
                    Text("Условия")
                } footer: {
                    Text("Пустая зарплата покажется соискателю как «по договорённости».")
                }
                .listRowBackground(Brand.card)

                Section("Описание") {
                    TextEditor(text: $descriptionText).frame(minHeight: 90)
                }
                .listRowBackground(Brand.card)

                Section("Требования") {
                    TextEditor(text: $requirements).frame(minHeight: 70)
                }
                .listRowBackground(Brand.card)

                Section("Что предлагаем") {
                    TextEditor(text: $conditions).frame(minHeight: 70)
                }
                .listRowBackground(Brand.card)

                if let error {
                    Section { Text(error).font(.footnote).foregroundColor(Brand.red) }
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(target.vacancy == nil ? "Новая вакансия" : "Вакансия")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }
                        .disabled(sending || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: fill)
            // Сохранить — вверху, ошибка — внизу под тремя полями текста: её не
            // было видно, и казалось, что кнопка не сработала.
            .errorAlert($error)
        }
        // Смахивание вниз закрывало лист и стирало описание, требования и
        // условия без вопроса — закрыть можно кнопкой «Отмена».
        .interactiveDismissDisabled(sending || !title.isEmpty || !descriptionText.isEmpty)
    }

    private func fill() {
        guard let v = target.vacancy else { return }
        title = v.title ?? ""
        category = v.kind
        employment = v.employment
        experience = v.exp
        status = v.state
        schedule = v.schedule ?? ""
        address = v.address ?? ""
        salaryFrom = (v.salaryFrom ?? 0) > 0 ? "\(NSDecimalNumber(decimal: v.salaryFrom ?? 0).intValue)" : ""
        salaryTo = (v.salaryTo ?? 0) > 0 ? "\(NSDecimalNumber(decimal: v.salaryTo ?? 0).intValue)" : ""
        descriptionText = v.description ?? ""
        requirements = v.requirements ?? ""
        conditions = v.conditions ?? ""
    }

    @MainActor private func save() async {
        guard !sending else { return }   // двойной тап создавал две вакансии
        sending = true
        defer { sending = false }
        error = nil
        // Decimal(string:) понимает только точку и молча читает префикс:
        // «60 000» с неразрывным пробелом давало 60, «45000,5» — 45000.
        // Строго: «50тыс» раньше давало 50 ₽, «от 30000» — пусто (стирало оклад).
        for (raw, label) in [(salaryFrom, "Зарплата от"), (salaryTo, "Зарплата до")] {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && Money.strict(t) == nil { error = "\(label) — число, например 45000"; return }
        }
        let from = Money.strict(salaryFrom.trimmingCharacters(in: .whitespaces))
        let to = Money.strict(salaryTo.trimmingCharacters(in: .whitespaces))
        // «от 80 000 до 50 000» соискатель видел как есть.
        if let f = from, let t = to, f > t { error = "«Зарплата от» больше, чем «до»"; return }
        do {
            if let v = target.vacancy {
                try await API.shared.updateVacancy(
                    id: v.vacancyId, title: title, category: category,
                    description: descriptionText, requirements: requirements,
                    conditions: conditions, schedule: schedule,
                    salaryFrom: from, salaryTo: to, employment: employment,
                    experience: experience, address: address, status: status)
            } else {
                _ = try await API.shared.createVacancy(
                    title: title, category: category,
                    description: descriptionText, requirements: requirements,
                    conditions: conditions, schedule: schedule,
                    salaryFrom: from, salaryTo: to, employment: employment,
                    experience: experience, address: address, status: status)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// ── Отклики ──────────────────────────────────────────────────────────────────

@MainActor
final class ApplicationsViewModel: ObservableObject {
    @Published var items: [JobApplication] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    private let vacancyId: Int
    init(vacancyId: Int) { self.vacancyId = vacancyId }

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            items = try await API.shared.vacancyApplications(vacancyId: vacancyId)
            state = .loaded
            // Как в списке вакансий: старая ошибка не висит над свежими откликами
            // (setStatus ставит свою ошибку уже после перечитывания).
            error = nil
        } catch is CancellationError {
        } catch {
            if items.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    /// Отклик, статус которого сейчас меняется. Переключатель статуса до
    /// перечитывания отскакивал на старое значение — его жали ещё раз, и два
    /// запроса приходили в любом порядке (оставался не тот статус).
    @Published var busyId: Int?

    func setStatus(_ app: JobApplication, _ status: ApplicationStatus) async {
        guard busyId == nil else { return }
        busyId = app.applicationId
        defer { busyId = nil }
        error = nil
        do {
            let actual = try await API.shared.setApplicationStatus(id: app.applicationId, status: status)
            await load()
            // Сервер подменяет неизвестный статус на viewed — показываем факт.
            if actual != status.rawValue {
                error = "Сервер записал статус «\(ApplicationStatus(rawValue: actual)?.title ?? actual)»"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ApplicationsView: View {
    let vacancy: Vacancy
    @StateObject private var vm: ApplicationsViewModel

    init(vacancy: Vacancy) {
        self.vacancy = vacancy
        _vm = StateObject(wrappedValue: ApplicationsViewModel(vacancyId: vacancy.vacancyId))
    }

    var body: some View {
        List {
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            ForEach(vm.items) { app in
                ApplicationRow(app: app) { status in
                    Task { await vm.setStatus(app, status) }
                }
                .disabled(vm.busyId != nil)
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "tray", emptyTitle: "Откликов нет",
                   emptySubtitle: "Соискатели откликаются с витрины и из приложения",
                   retry: { Task { await vm.load() } })
        .navigationTitle(vacancy.title ?? "Отклики")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }
}

private struct ApplicationRow: View {
    let app: JobApplication
    let onStatus: (ApplicationStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(app.name ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Spacer()
                StatusBadge(text: app.state.title, color: color)
            }
            if let phone = app.phone, !phone.isEmpty {
                // Звонок прямо из отклика — самое частое действие кадровика.
                // Только цифры и «+»: номер с пробелами и скобками давал nil, и
                // тап открывал сайт вместо звонка.
                Link(destination: URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) ?? URL(string: "https://yumurta.ru")!) {
                    Label(phone, systemImage: "phone")
                        .font(.caption.weight(.semibold))
                }
                // Без стиля ссылка в строке List ловит тап по всей строке —
                // касание по письму или статусу звонило соискателю.
                .buttonStyle(.borderless)
            }
            if let email = app.email, !email.isEmpty {
                Text(email).font(.caption).foregroundColor(Brand.muted)
            }
            if let letter = app.coverLetter, !letter.isEmpty {
                Text(letter).font(.caption).foregroundColor(Brand.muted).lineLimit(4)
            }
            Text(DateFmt.short(app.createdAt))
                .font(.caption2).foregroundColor(Brand.muted)

            Picker("Статус", selection: Binding(
                get: { app.state },
                set: { onStatus($0) }
            )) {
                ForEach(ApplicationStatus.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 3)
    }

    private var color: Color {
        switch app.state {
        case .new:      return Brand.accent
        case .viewed:   return Brand.muted
        case .invited:  return Brand.green
        case .rejected: return Brand.red
        }
    }
}
