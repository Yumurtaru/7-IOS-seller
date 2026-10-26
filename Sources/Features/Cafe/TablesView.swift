import SwiftUI

// ============================================================================
//  Столы (cafe) — /api/seller/tables (routes/tables.php): список, создание,
//  правка, включение и удаление. QR-ссылка стола: https://yumurta.ru/t/{token}
//  — ею можно поделиться, гость попадает в меню «в зале».
//
//  Печать самих QR-кодов осталась в веб-кабинете: там макет на лист, а не
//  одна ссылка. Всё остальное теперь делается здесь.
//
//  Право — «Настройки» (settings), как размечено на сервере.
// ============================================================================

@MainActor
final class TablesViewModel: ObservableObject {
    @Published var tables: [RestaurantTable] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    func load() async {
        if tables.isEmpty { state = .loading }
        do {
            tables = try await API.shared.tables()
            state = .loaded
            // Прошлая ошибка обновления («нет сети») висела красной строкой и
            // после удачного повтора — казалось, что список всё ещё старый.
            error = nil
        } catch is CancellationError {
        } catch {
            if tables.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    func save(id: Int?, number: String, seats: Int, zone: String, isActive: Bool) async -> String? {
        do {
            if let id {
                try await API.shared.updateTable(id: id, number: number, seats: seats,
                                                 zone: zone, isActive: isActive)
            } else {
                _ = try await API.shared.createTable(number: number, seats: seats, zone: zone)
            }
            await load()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Быстрый тумблер прямо из списка: остальные поля шлём как есть,
    /// иначе сервер их не тронет, но и в теле их не будет.
    func toggle(_ t: RestaurantTable) async {
        error = nil
        do {
            try await API.shared.updateTable(id: t.id, number: t.number ?? "",
                                             seats: t.seats ?? 1, zone: t.zone ?? "",
                                             isActive: !(t.isActive == true))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func delete(_ t: RestaurantTable) async {
        error = nil
        do {
            try await API.shared.deleteTable(id: t.id)
            tables.removeAll { $0.id == t.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Обёртка для .sheet(item:) — nil внутри означает «добавляем стол».
struct TableEditTarget: Identifiable {
    let table: RestaurantTable?
    var id: Int { table?.id ?? 0 }
}

struct TablesView: View {
    @StateObject private var vm = TablesViewModel()
    @State private var shareURL: URL?
    @State private var editing: TableEditTarget?
    /// паритет с Android: удаление стола — только после вопроса.
    @State private var confirmDelete: RestaurantTable?

    var body: some View {
        List {
            if let err = vm.error {
                Text(err).font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            ForEach(vm.tables) { t in
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(t.isActive == true ? Brand.accent.opacity(0.15) : Brand.chip)
                            .frame(width: 40, height: 40)
                        Text(t.number ?? "—")
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(t.isActive == true ? Brand.accent : Brand.muted)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Стол \(t.number ?? "—")")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(Brand.text)
                        Text(joinedNonEmpty([t.zone, "мест: \(t.seats ?? 0)"], separator: " · "))
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                    Spacer()
                    if t.isActive != true {
                        StatusBadge(text: "выкл", color: Brand.muted)
                    }
                    if let token = t.qrToken, !token.isEmpty {
                        Button {
                            shareURL = URL(string: "https://yumurta.ru/t/\(token)")
                        } label: {
                            Image(systemName: "qrcode")
                                .foregroundColor(Brand.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(Brand.card)
                // Без полного свайпа: длинный жест удалял стол (и его QR на
                // столе переставал работать) без вопроса — только кнопкой.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        confirmDelete = t
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                    Button {
                        editing = TableEditTarget(table: t)
                    } label: {
                        Label("Изменить", systemImage: "pencil")
                    }
                    .tint(Brand.accent)
                    Button {
                        Task { await vm.toggle(t) }
                    } label: {
                        Label(t.isActive == true ? "Выключить" : "Включить",
                              systemImage: t.isActive == true ? "pause.circle" : "play.circle")
                    }
                    .tint(Brand.amber)
                }
            }
            Section {
                Link(destination: URL(string: "https://yumurta.ru/seller/tables.php")!) {
                    Label("Печать QR-кодов — в веб-кабинете", systemImage: "printer")
                }
            } footer: {
                Text("Здесь — столы, зоны и ссылка QR-меню. Макет для печати кодов на лист остался в веб-кабинете.")
            }
            .listRowBackground(Brand.card)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Столы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editing = TableEditTarget(table: nil) } label: { Image(systemName: "plus") }
            }
        }
        .sheet(item: $editing) { target in
            TableEditSheet(target: target, vm: vm)
        }
        // паритет с Android: раньше кнопка в свайпе удаляла стол сразу, и его QR переставал работать.
        .alert("Удалить стол?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        ), presenting: confirmDelete) { t in
            Button("Отмена", role: .cancel) { confirmDelete = nil }
            Button("Удалить", role: .destructive) {
                confirmDelete = nil
                Task { await vm.delete(t) }
            }
        } message: { t in
            Text("Стол \(t.number ?? "") и его QR-ссылка перестанут работать.")
        }
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.tables.isEmpty,
                   emptyIcon: "tablecells", emptyTitle: "Столов нет",
                   emptySubtitle: "Добавьте стол — у него сразу появится QR-меню",
                   retry: { Task { await vm.load() } })
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ShareSheet(items: [url])
            }
        }
        .task { await vm.load() }
    }
}

private struct TableEditSheet: View {
    let target: TableEditTarget
    @ObservedObject var vm: TablesViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var number = ""
    @State private var seatsText = "2"
    @State private var zone = ""
    @State private var isActive = true
    @State private var sending = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Номер стола", text: $number)
                    TextField("Мест", text: $seatsText).keyboardType(.numberPad)
                    TextField("Зона (терраса, второй зал)", text: $zone)
                    if target.table != nil {
                        Toggle("Стол работает", isOn: $isActive)
                    }
                } footer: {
                    Text("Номер попадает в ссылку QR-меню: гость сканирует код и видит меню именно этого стола.")
                }
                .listRowBackground(Brand.card)

                if let error {
                    Section { Text(error).font(.footnote).foregroundColor(Brand.red) }
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle(target.table == nil ? "Новый стол" : "Стол")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await save() } }
                        .disabled(sending || number.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let t = target.table else { return }
                number = t.number ?? ""
                seatsText = "\(t.seats ?? 2)"
                zone = t.zone ?? ""
                isActive = t.isActive == true
            }
        }
    }

    @MainActor private func save() async {
        guard !sending else { return }   // двойной тап создавал два стола
        sending = true
        defer { sending = false }
        error = nil
        // «4 » или пусто раньше молча давали 2 места, «0» и минус — 1.
        guard let seats = Int(seatsText.filter { !$0.isWhitespace }), seats >= 1 else {
            error = "Мест — целое число от 1"
            return
        }
        error = await vm.save(id: target.table?.id, number: number.trimmingCharacters(in: .whitespaces),
                              seats: seats, zone: zone.trimmingCharacters(in: .whitespaces),
                              isActive: isActive)
        if error == nil { dismiss() }
    }
}
