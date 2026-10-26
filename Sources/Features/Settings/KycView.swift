import SwiftUI

// ============================================================================
//  Готовность организации — GET /api/seller/kyc.
//
//  Сервер сам считает, что заполнено: название, адрес, логотип, часы работы,
//  зона доставки, хотя бы один товар, способы оплаты, одобренные документы.
//  Проценты и список приходят готовыми — приложение ничего не досчитывает,
//  иначе цифра в кабинете и в приложении разошлись бы.
//
//  Право — «Настройки» (settings).
// ============================================================================

@MainActor
final class KycViewModel: ObservableObject {
    @Published var data: KycResponse?
    @Published var state: LoadState = .idle
    /// Паритет с Android: неудачное обновление при уже показанных данных.
    @Published var error: String?

    func load() async {
        if data == nil { state = .loading }
        do {
            data = try await API.shared.kyc()
            state = .loaded
            error = nil
        } catch is CancellationError {
        } catch {
            // Раньше при данных на экране ошибка не показывалась нигде, и
            // прежние проценты выглядели свежими.
            if data == nil { state = .failed(error.localizedDescription) }
            else { self.error = error.localizedDescription }
        }
    }
}

struct KycView: View {
    @StateObject private var vm = KycViewModel()

    var body: some View {
        List {
            if let err = vm.error, vm.data != nil {
                Text("Не обновилось: \(err). Ниже — прежние данные.")
                    .font(.footnote).foregroundColor(Brand.red)
                    .listRowBackground(Brand.card)
            }
            if let d = vm.data {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(d.percent ?? 0)%")
                                .font(.largeTitle.weight(.bold))
                                .foregroundColor(color(d.percent ?? 0))
                            Spacer()
                            StatusBadge(text: statusTitle(d.shopStatus),
                                        color: d.shopStatus == "active" ? Brand.green
                                            : (d.shopStatus == "blocked" ? Brand.red : Brand.amber))
                        }
                        // Больше 100 ProgressView не принимает (пишет в лог и рисует полной).
                        ProgressView(value: Double(min(max(d.percent ?? 0, 0), 100)), total: 100)
                            .tint(color(d.percent ?? 0))
                        Text("Готово \(d.done ?? 0) из \(d.total ?? 0)")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("Чем полнее карточка, тем выше организация в поиске и тем меньше вопросов у покупателя.")
                }
                .listRowBackground(Brand.card)

                Section("Что проверяется") {
                    ForEach(d.checks ?? []) { c in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: c.done == true ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(c.done == true ? Brand.green : Brand.muted)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.label ?? c.key ?? "—")
                                    .font(.subheadline)
                                    .foregroundColor(Brand.text)
                                if c.done != true, let hint = c.hint, !hint.isEmpty {
                                    Text(hint).font(.caption).foregroundColor(Brand.muted)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .refreshable { await vm.load() }
        .listState(vm.state, isEmpty: vm.data == nil,
                   emptyIcon: "checklist", emptyTitle: "Нет данных",
                   emptySubtitle: "Проверка готовности пока недоступна",
                   retry: { Task { await vm.load() } })
        .navigationTitle("Готовность организации")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
    }

    private func color(_ percent: Int) -> Color {
        switch percent {
        case 100: return Brand.green
        case 60...: return Brand.amber
        default: return Brand.red
        }
    }

    private func statusTitle(_ s: String?) -> String {
        switch s ?? "" {
        case "active": return "Работает"
        case "paused": return "На паузе"
        // Магазин на проверке и заблокированный показывались голым кодом
        // «pending» / «blocked» — подписи как на Android.
        case "pending": return "На проверке"
        case "blocked": return "Заблокирован"
        // Новая организация (draft) и отправленная на проверку (review)
        // показывались голым кодом «draft» / «review».
        case "draft": return "Не опубликована"
        case "review": return "На проверке"
        default: return s ?? "—"
        }
    }
}
