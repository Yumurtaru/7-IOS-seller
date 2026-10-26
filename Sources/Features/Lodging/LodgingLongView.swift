import SwiftUI

// ============================================================================
//  Заявки на длительную аренду.
// ----------------------------------------------------------------------------
//  Аренда на месяцы не бронируется календарём и не оплачивается на площадке:
//  гость оставляет заявку, дальше стороны договариваются сами. Поэтому здесь
//  только воронка статусов и заметка — ни денег, ни занятия дат.
// ============================================================================

@MainActor
final class LodgingLongViewModel: ObservableObject {
    @Published var items: [LodgingLongRequest] = []
    @Published var state: LoadState = .idle
    @Published var error: String?

    func load() async {
        if items.isEmpty { state = .loading }
        error = nil
        do {
            items = try await API.shared.lodgingLongRequests()
            state = .loaded
        } catch is CancellationError {
        } catch {
            if items.isEmpty { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }

    /// Смена статуса в пути: пока ответа нет, второй статус (другая кнопка или
    /// повторное «Сохранить») не уходит — два запроса приходили в любом порядке.
    @Published var acting = false

    /// true — статус сохранён. Окно заметки ждёт ответа, а не закрывается сразу.
    @discardableResult
    func setStatus(_ req: LodgingLongRequest, _ status: String, note: String) async -> Bool {
        // Старую ошибку сбрасываем: окно статуса показывает error, и при
        // занятости вместо «Дождитесь…» всплывала прошлая ошибка.
        guard !acting else { error = nil; return false }
        acting = true
        defer { acting = false }
        error = nil
        do {
            try await API.shared.setLodgingLongStatus(id: req.id, status: status, note: note)
            await load()
            return true
        } catch {
            // Заявку уже перевели (другой сотрудник, веб-кабинет) или связь
            // оборвалась после записи: перечитываем — иначе кнопки прежнего
            // статуса оставались. load() начинает с error = nil, поэтому текст —
            // после перечитывания.
            let msg = error.localizedDescription
            await load()
            self.error = msg
            return false
        }
    }
}

struct LodgingLongView: View {
    @StateObject private var vm = LodgingLongViewModel()
    @State private var noteTarget: LodgingLongTarget?

    var body: some View {
        List {
            if let err = vm.error {
                Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
            }
            ForEach(vm.items) { r in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(r.unitTitle ?? "Объект")
                                    .font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                                Text("\(r.months ?? 1) мес. с \(LodgingFormat.fullDate(r.desiredFrom))")
                                    .font(.caption).foregroundColor(Brand.muted)
                                Text(LodgingFormat.guests(r.adults, r.children)
                                     + ((r.pets ?? 0) == 1 ? " · с животными" : ""))
                                    .font(.caption).foregroundColor(Brand.muted)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 4) {
                                if (r.priceMonth ?? 0) > 0 {
                                    Text("\(Money.rub(r.priceMonth))/мес")
                                        .font(.footnote.weight(.semibold)).foregroundColor(Brand.text)
                                }
                                LodgingPill(text: statusTitle(r), color: statusColor(r.status))
                            }
                        }
                        Text(joinedNonEmpty([r.name, r.phone], separator: " · "))
                            .font(.footnote).foregroundColor(Brand.text)
                        if let m = r.message, !m.isEmpty {
                            Text(m).font(.caption).foregroundColor(Brand.muted)
                        }
                        if let n = r.sellerNote, !n.isEmpty {
                            Text("Заметка: \(n)").font(.caption).foregroundColor(Brand.muted)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(actions(for: r), id: \.0) { status, title, color in
                                    LodgingActionButton(title: title, color: color) {
                                        noteTarget = LodgingLongTarget(request: r, status: status)
                                    }
                                }
                            }
                        }
                        .disabled(vm.acting)
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.items.isEmpty,
                   emptyIcon: "doc.text", emptyTitle: "Заявок нет",
                   emptySubtitle: "Здесь появятся заявки на аренду на месяцы — по объектам, где включена длительная аренда",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Длительная аренда")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $noteTarget) { t in
            LodgingLongNoteSheet(target: t, vm: vm)
        }
        .task { await vm.load() }
    }

    private func actions(for r: LodgingLongRequest) -> [(String, String, Color)] {
        switch r.status ?? "new" {
        case "new":
            return [("contacted", "Связались", Brand.accent),
                    ("agreed", "Договорились", Brand.green),
                    ("declined", "Отказать", Brand.red)]
        case "contacted":
            return [("agreed", "Договорились", Brand.green),
                    ("declined", "Отказать", Brand.red)]
        case "agreed":
            return [("closed", "Закрыть", Brand.muted)]
        // Закрытую заявку закрывать нечего — кнопка «Закрыть» у неё была мёртвой.
        case "closed":
            return []
        default:
            return [("closed", "Закрыть", Brand.muted)]
        }
    }

    private func statusTitle(_ r: LodgingLongRequest) -> String {
        if let l = r.statusLabel, !l.isEmpty { return l }
        switch r.status ?? "new" {
        case "new": return "Новая"
        case "contacted": return "Связались"
        case "agreed": return "Договорились"
        case "declined": return "Отказ"
        case "closed": return "Закрыта"
        default: return r.status ?? "—"
        }
    }

    private func statusColor(_ s: String?) -> Color {
        switch s ?? "new" {
        case "new": return Brand.amber
        case "contacted": return Brand.accent
        case "agreed": return Brand.green
        case "declined": return Brand.red
        default: return Brand.muted
        }
    }
}

struct LodgingLongTarget: Identifiable {
    let request: LodgingLongRequest
    let status: String
    var id: String { "\(request.id)-\(status)" }
}

private struct LodgingLongNoteSheet: View {
    let target: LodgingLongTarget
    @ObservedObject var vm: LodgingLongViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var note: String = ""
    /// Окно ждёт ответа сервера: раньше закрывалось сразу, отказ терялся
    /// в строке над списком, а набранная заметка пропадала.
    @State private var sending = false
    @State private var sendError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Заметка для себя", text: $note, axis: .vertical).lineLimit(2...5)
                } footer: {
                    Text("Заметку видят только сотрудники организации, она сохранится вместе со статусом. Гостю по длительной аренде площадка ничего не отправляет — свяжитесь с ним сами.")
                }
                Section {
                    if let e = sendError {
                        Text(e).font(.footnote).foregroundColor(Brand.red)
                    }
                    Button {
                        guard !sending else { return }
                        sending = true
                        sendError = nil
                        let text = note
                        Task {
                            let ok = await vm.setStatus(target.request, target.status, note: text)
                            sending = false
                            if ok { dismiss() } else { sendError = vm.error ?? "Дождитесь завершения предыдущего действия" }
                        }
                    } label: {
                        HStack {
                            Text("Сохранить статус").bold()
                            if sending { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(sending)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Статус заявки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } } }
            // Заметку подставляем: сервер перезаписывает её при каждой смене
            // статуса, и пустое поле стёрло бы набранное раньше.
            .onAppear { if note.isEmpty { note = target.request.sellerNote ?? "" } }
        }
        .interactiveDismissDisabled(sending)
    }
}
