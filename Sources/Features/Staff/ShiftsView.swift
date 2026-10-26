import SwiftUI

// ============================================================================
//  Смены — GET /api/seller/staff/shifts (до 100), открытие POST .../shifts/open
//  {employee_id?, cash_open, note} (одна открытая на магазин — сервер вернёт
//  400 текстом), закрытие POST .../shifts/{id}/close {cash_counted?} →
//  выручка/заказы/ожидаемые наличные/расхождение.
// ============================================================================

@MainActor
final class ShiftsViewModel: ObservableObject {
    @Published var items: [StaffShift] = []
    @Published var employees: [Employee] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var closeResult: ShiftCloseResult?

    var openShift: StaffShift? { items.first { $0.status == "open" } }

    func load() async {
        if items.isEmpty { state = .loading }
        do {
            async let shifts = API.shared.staffShifts()
            async let emps = API.shared.employees(status: "active")
            items = try await shifts
            employees = (try? await emps) ?? employees
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func open(employeeId: Int?, cashOpen: Decimal, note: String?) async -> Bool {
        error = nil
        do {
            _ = try await API.shared.openShift(employeeId: employeeId, cashOpen: cashOpen, note: note)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            // «Смена уже открыта» (открыли на кассе или другом телефоне) или
            // обрыв, при котором смена могла открыться: перечитываем список —
            // раньше на экране оставалась кнопка «Открыть», и каждое нажатие
            // давало ту же ошибку, а открытой смены не было видно.
            let msg = self.error
            await load()
            self.error = msg
            return false
        }
    }

    func close(shift: StaffShift, cashCounted: Decimal?) async -> Bool {
        error = nil
        do {
            closeResult = try await API.shared.closeShift(id: shift.shiftId, cashCounted: cashCounted)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            // «Открытая смена не найдена» (её уже закрыли на кассе) или обрыв
            // связи: перечитываем, иначе «Закрыть смену» висела у закрытой.
            let msg = self.error
            await load()
            self.error = msg
            return false
        }
    }
}

struct ShiftsView: View {
    @StateObject private var vm = ShiftsViewModel()
    @State private var showOpenSheet = false
    @State private var closeTarget: StaffShift?

    var body: some View {
        List {
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            currentSection
            if let result = vm.closeResult {
                closedResultSection(result)
            }
            historySection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty && vm.state != .loaded,
                   emptyIcon: "clock", emptyTitle: "Загрузка…",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Смены")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showOpenSheet) { ShiftOpenSheet(vm: vm) }
        .sheet(item: $closeTarget) { shift in ShiftCloseSheet(shift: shift, vm: vm) }
        .task { await vm.load() }
    }

    // ── Текущая смена ────────────────────────────────────────────────────────
    private var currentSection: some View {
        Section("Текущая смена") {
            if let shift = vm.openShift {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        StatusBadge(text: "Открыта", color: Brand.green)
                        Text(shift.name ?? "Без сотрудника")
                            .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                        Spacer()
                    }
                    Text("С \(DateFmt.short(shift.startedAt)) · наличных на старте \(Money.rub(shift.cashOpen))")
                        .font(.caption).foregroundColor(Brand.muted)
                    Button {
                        // Ошибка прошлой попытки (открытия) не должна висеть в
                        // новом окне закрытия, будто закрыть уже не вышло.
                        vm.error = nil
                        closeTarget = shift
                    } label: {
                        Text("Закрыть смену")
                            .font(.subheadline.weight(.bold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.red)
                }
                .padding(.vertical, 4)
            } else {
                Button {
                    vm.closeResult = nil
                    vm.error = nil   // прежняя ошибка — не про новое открытие
                    showOpenSheet = true
                } label: {
                    Label("Открыть смену", systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.green)
            }
        }
        .listRowBackground(Brand.card)
    }

    private func closedResultSection(_ result: ShiftCloseResult) -> some View {
        Section("Итоги закрытой смены") {
            InfoRow(label: "Выручка", value: Money.rub(result.revenue))
            InfoRow(label: "Заказов", value: "\(result.orders ?? 0)")
            InfoRow(label: "Наличных ожидалось", value: Money.rub(result.cashExpected))
            if let counted = result.cashCounted {
                InfoRow(label: "Пересчитано", value: Money.rub(counted))
            }
            if let diff = result.cashDiff, diff != 0 {
                HStack {
                    Text("Расхождение").font(.subheadline).foregroundColor(Brand.muted)
                    Spacer()
                    Text(Money.signed(diff))
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(diff < 0 ? Brand.red : Brand.green)
                }
            }
        }
        .listRowBackground(Brand.card)
    }

    // ── История ──────────────────────────────────────────────────────────────
    private var historySection: some View {
        Section("История") {
            let closed = vm.items.filter { $0.status != "open" }
            if closed.isEmpty {
                Text("Закрытых смен пока нет")
                    .font(.subheadline).foregroundColor(Brand.muted)
            }
            ForEach(closed) { shift in
                ShiftRow(shift: shift)
            }
        }
        .listRowBackground(Brand.card)
    }
}

struct ShiftRow: View {
    let shift: StaffShift

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(shift.name ?? "Без сотрудника")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(Brand.text)
                Spacer()
                Text(Money.rub(shift.revenueDuringShift))
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Brand.text)
            }
            // «1 заказов» — склоняем.
            Text("\(DateFmt.short(shift.startedAt)) — \(DateFmt.short(shift.endedAt)) · \(Self.ordersText(shift.ordersCount ?? 0))")
                .font(.caption)
                .foregroundColor(Brand.muted)
            if let diff = shift.cashDiff, diff != 0 {
                Text("Расхождение по кассе: \(Money.signed(diff))")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(diff < 0 ? Brand.red : Brand.green)
            }
        }
        .padding(.vertical, 3)
    }

    private static func ordersText(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "\(n) заказов" }
        if m10 == 1 { return "\(n) заказ" }
        if m10 >= 2 && m10 <= 4 { return "\(n) заказа" }
        return "\(n) заказов"
    }
}

// ── Открытие смены ────────────────────────────────────────────────────────────
private struct ShiftOpenSheet: View {
    @ObservedObject var vm: ShiftsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var employeeId = 0
    @State private var cashText = ""
    @State private var note = ""
    @State private var sending = false
    @State private var didPrefill = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Открытие смены") {
                    Picker("Сотрудник", selection: $employeeId) {
                        Text("Не указан").tag(0)
                        ForEach(vm.employees) { emp in
                            Text(emp.fullName ?? emp.phone ?? "Сотрудник").tag(emp.employeeId)
                        }
                    }
                    TextField("Наличных в кассе на старте, ₽", text: $cashText)
                        .keyboardType(.decimalPad)
                    TextField("Заметка", text: $note)
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Открыть смену")
            .navigationBarTitleDisplayMode(.inline)
            // Размен в ящике = пересчитанные наличные прошлой смены (так их берёт
            // сервер, если поле не прислали: seller_staff.php, shifts/open).
            // Пустое поле приложение слало нулём — размен выпадал из сверки, и
            // смена закрывалась с «излишком», маскирующим недостачу.
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                let last = vm.items.first { $0.status == "closed" && $0.cashCounted != nil }
                if cashText.isEmpty, let c = last?.cashCounted {
                    cashText = NSDecimalNumber(decimal: c).stringValue
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "…" : "Открыть") {
                        // Строгий разбор: «12 500» раньше читалось как 12, а от
                        // суммы на старте считается расхождение всей смены.
                        let raw = cashText.trimmingCharacters(in: .whitespaces)
                        guard !sending, let cash = raw.isEmpty ? 0 : Money.strict(raw) else { return }
                        sending = true
                        Task {
                            let ok = await vm.open(employeeId: employeeId > 0 ? employeeId : nil,
                                                   cashOpen: cash,
                                                   note: note.isEmpty ? nil : note)
                            sending = false
                            // Отказ, а смена после перечитывания открыта — окно не
                            // нужно: открытая смена и текст ошибки видны на экране.
                            if ok || vm.openShift != nil { dismiss() }
                        }
                    }
                    .disabled(sending || (!cashText.trimmingCharacters(in: .whitespaces).isEmpty
                                          && Money.strict(cashText) == nil))
                }
            }
        }
    }
}

// ── Закрытие смены (пересчёт наличных) ───────────────────────────────────────
private struct ShiftCloseSheet: View {
    let shift: StaffShift
    @ObservedObject var vm: ShiftsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var countedText = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Наличных в кассе по факту, ₽", text: $countedText)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("Пересчёт наличных")
                } footer: {
                    Text("Можно оставить пустым — смена закроется без сверки. Сервер сам посчитает выручку и ожидаемые наличные.")
                }
                if let err = vm.error {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Закрыть смену")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "…" : "Закрыть смену") {
                        // Пусто — закрываем без сверки. Непустое — только целиком
                        // разобранное число: «12 500» как 12 давало расхождение
                        // −12 488 ₽, которое потом не исправить.
                        let raw = countedText.trimmingCharacters(in: .whitespaces)
                        let counted: Decimal? = raw.isEmpty ? nil : Money.strict(raw)
                        guard !sending, raw.isEmpty || counted != nil else { return }
                        sending = true
                        Task {
                            let ok = await vm.close(shift: shift, cashCounted: counted)
                            sending = false
                            // Смену уже закрыли в другом месте — закрывать нечего.
                            if ok || vm.openShift?.shiftId != shift.shiftId { dismiss() }
                        }
                    }
                    .disabled(sending || (!countedText.trimmingCharacters(in: .whitespaces).isEmpty
                                          && Money.strict(countedText) == nil))
                }
            }
        }
    }
}
