import SwiftUI

// ============================================================================
//  Деталь возврата — GET /api/seller/returns/{id}: позиции, фото клиента,
//  лог; одобрение POST .../approve {refund_method: bonus|manual, amount, note},
//  отклонение POST .../reject {reason}.
//  Бонусный возврат сервер сразу переводит в refunded (начисляет клиенту).
// ============================================================================

@MainActor
final class ReturnDetailViewModel: ObservableObject {
    @Published var detail: ReturnDetail?
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var notice: String?
    @Published var isActing = false

    let returnId: Int
    init(returnId: Int) { self.returnId = returnId }

    func load() async {
        if detail == nil { state = .loading }
        do {
            detail = try await API.shared.returnDetail(id: returnId)
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func approve(amount: Decimal?, method: String, note: String?) async -> Bool {
        guard !isActing else { return false }   // двойной тап — один возврат денег
        isActing = true
        error = nil
        defer { isActing = false }
        do {
            let ack = try await API.shared.approveReturn(id: returnId, amount: amount, method: method, note: note)
            if let d = ack.deducted, d > 0 {
                notice = "Клиент уже потратил \(Money.rub(d)) кешбэка/баллов с этого заказа — они вычтены. К возврату: \(Money.rub(ack.amount))."
            } else if let req = amount, let paid = ack.amount, paid < req {
                // паритет с Android: сервер урезает сумму до заявки и до ещё не
                // возвращённого по заказу (seller.php, approve) — говорим, сколько одобрено.
                notice = "Одобрено к выплате \(Money.rub(paid)), а не \(Money.rub(req)): больше по заявке и заказу вернуть нельзя."
            }
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            await reloadAfterFailure()
            return false
        }
    }

    /// «Деньги выплачены». Возврат бонусами закрывается сам в момент
    /// начисления, а возврат деньгами оставался «Одобрен» навсегда: ни продавец,
    /// ни покупатель не видели, отданы деньги или нет.
    func markPaid(note: String?) async -> Bool {
        guard !isActing else { return false }
        isActing = true
        error = nil
        defer { isActing = false }
        do {
            try await API.shared.markReturnPaid(id: returnId, note: note)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            await reloadAfterFailure()
            return false
        }
    }

    /// Отказ «заявка уже обработана» (решил другой сотрудник или кабинет) или
    /// обрыв связи, при котором решение могло пройти: перечитываем заявку.
    /// Раньше «Одобрить/Отклонить» оставались у закрытого возврата, и каждое
    /// нажатие давало ту же ошибку. Текст ошибки сохраняем.
    private func reloadAfterFailure() async {
        let msg = error
        await load()
        error = msg
    }

    func reject(reason: String) async -> Bool {
        guard !isActing else { return false }
        isActing = true
        error = nil
        defer { isActing = false }
        do {
            try await API.shared.rejectReturn(id: returnId, reason: reason)
            await load()
            return true
        } catch {
            self.error = error.localizedDescription
            await reloadAfterFailure()
            return false
        }
    }
}

struct ReturnDetailView: View {
    @StateObject private var vm: ReturnDetailViewModel
    var onChanged: (() -> Void)?
    @State private var showApprove = false
    @State private var showReject = false
    @State private var rejectReason = ""
    @State private var showPaid = false
    @State private var paidNote = ""

    init(returnId: Int, onChanged: (() -> Void)? = nil) {
        _vm = StateObject(wrappedValue: ReturnDetailViewModel(returnId: returnId))
        self.onChanged = onChanged
    }

    var body: some View {
        ScrollView {
            if let r = vm.detail {
                VStack(spacing: 14) {
                    headerCard(r)
                    if let err = vm.error {
                        Text(err).font(.footnote).foregroundColor(Brand.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let note = vm.notice {
                        Text(note).font(.footnote.weight(.semibold)).foregroundColor(Brand.accent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if r.status == "pending" { actions }
                    if r.refundMethod == "manual", r.status == "approved" || r.status == "refunded" { paidAction(r) }
                    itemsCard(r)
                    photosCard(r)
                    logCard(r)
                }
                .padding(16)
            }
        }
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Возврат #\(vm.returnId)")
        .navigationBarTitleDisplayMode(.inline)
        .listState(vm.state, isEmpty: vm.detail == nil,
                   emptyIcon: "arrow.uturn.left.circle", emptyTitle: "Возврат не найден",
                   retry: { Task { await vm.load() } })
        .refreshable { await vm.load() }
        .sheet(isPresented: $showApprove) {
            ApproveReturnSheet(vm: vm, onDone: { onChanged?() })
        }
        .alert("Отклонить возврат", isPresented: $showReject) {
            TextField("Причина отклонения", text: $rejectReason)
            Button("Отклонить", role: .destructive) {
                let r = rejectReason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !r.isEmpty else { vm.error = "Укажите причину отклонения"; return }
                Task {
                    if await vm.reject(reason: r) {
                        rejectReason = ""
                        onChanged?()
                    }
                }
            }
            Button("Закрыть", role: .cancel) {}
        } message: {
            Text("Причину увидит клиент")
        }
        .alert("Подтвердить выплату", isPresented: $showPaid) {
            TextField("Чем выплатили (необязательно)", text: $paidNote)
            Button("Да, выплачено") {
                Task {
                    if await vm.markPaid(note: paidNote.isEmpty ? nil : paidNote) {
                        paidNote = ""
                        onChanged?()
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Деньги переданы покупателю? Возврат будет закрыт.")
        }
        // П-27.15: причина и заметка возврата на сервере — до 255 знаков
        // (размер колонок); длиннее не даём набрать.
        .onChange(of: rejectReason) { v in
            let c = capReturnText(v)
            if c != v { rejectReason = c }
        }
        .onChange(of: paidNote) { v in
            let c = capReturnText(v)
            if c != v { paidNote = c }
        }
        .task { await vm.load() }
    }

    private func headerCard(_ r: ReturnDetail) -> some View {
        SectionCard {
            HStack {
                StatusBadge(text: ReturnLabels.status(r.status), color: ReturnLabels.color(r.status))
                Spacer()
                Text(DateFmt.short(r.createdAt)).font(.caption).foregroundColor(Brand.muted)
            }
            InfoRow(label: "Заказ", value: returnOrderLabel(number: r.orderNumber, orderId: r.orderId))
            InfoRow(label: "Тип", value: r.type == "partial" ? "Частичный" : "Полный")
            InfoRow(label: "Сумма к возврату", value: Money.rub(r.refundAmount))
            InfoRow(label: "Способ", value: r.refundMethod == "manual" ? "Ручной возврат" : "Бонусами")
            // Подпись вместо кода сервера («changed_mind» → «Передумал»).
            if let code = r.reasonCode, !code.isEmpty { InfoRow(label: "Причина", value: ReturnLabels.reason(code)) }
            if let text = r.reasonText, !text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Причина клиента").font(.subheadline).foregroundColor(Brand.muted)
                    Text(text).font(.subheadline).foregroundColor(Brand.text)
                }
            }
            if let note = r.moderatorNote, !note.isEmpty {
                InfoRow(label: "Комментарий модератора", value: note)
            }
            if let client = r.client, !client.isEmpty { InfoRow(label: "Клиент", value: client) }
            if let phone = r.clientPhone, !phone.isEmpty,
               let url = URL(string: "tel://" + phone.filter { "+0123456789".contains($0) }) {
                Link(destination: url) {
                    Label(phone, systemImage: "phone.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.green)
                }
            }
        }
    }

    // Решение по возврату — отдельное право: видеть заявку может весь зал,
    // а вернуть деньги — не каждый.
    @ViewBuilder
    private var actions: some View {
        if Session.shared.can("returns.decide") {
            HStack(spacing: 10) {
                Button {
                    showApprove = true
                } label: {
                    Text("Одобрить")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(Brand.green)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    showReject = true
                } label: {
                    Text("Отклонить")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(Brand.red.opacity(0.15))
                .foregroundColor(Brand.red)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(vm.isActing)
        }
    }

    /// Возврат деньгами не закрывается сам: пока выплату не подтвердили,
    /// непонятно, отдали покупателю деньги или нет.
    @ViewBuilder
    private func paidAction(_ r: ReturnDetail) -> some View {
        if Session.shared.can("returns.decide") {
            SectionCard {
                Text("Возврат одобрен на \(Money.rub(r.refundAmount)). Отдайте деньги покупателю и отметьте выплату — возврат закроется.")
                    .font(.footnote)
                    .foregroundColor(Brand.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    showPaid = true
                } label: {
                    Text("Деньги выплачены")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .background(Brand.green)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .disabled(vm.isActing)
            }
        }
    }

    private func itemsCard(_ r: ReturnDetail) -> some View {
        SectionCard(title: "Позиции заказа") {
            ForEach(r.orderItems ?? []) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "—")
                            .font(.subheadline)
                            .foregroundColor(Brand.text)
                        if let rq = item.returnQty, rq > 0 {
                            Text("Возвращено ранее: \(qty(rq))")
                                .font(.caption2).foregroundColor(Brand.amber)
                        }
                    }
                    Spacer()
                    Text("×\(qty(item.qty))").font(.caption).foregroundColor(Brand.muted)
                    Text(Money.rub(item.price)).font(.subheadline.weight(.semibold)).foregroundColor(Brand.text)
                }
                .padding(.vertical, 3)
            }
            if let reqItems = r.items, !reqItems.isEmpty {
                Divider().overlay(Brand.border)
                Text("Клиент просит вернуть:").font(.caption.weight(.semibold)).foregroundColor(Brand.muted)
                ForEach(reqItems) { it in
                    let name = r.orderItems?.first(where: { $0.rowId == it.itemId })?.name ?? it.name ?? "Позиция #\(it.itemId ?? 0)"
                    Text("• \(name) — \(qty(it.qty)) шт.")
                        .font(.caption)
                        .foregroundColor(Brand.text)
                }
            }
        }
    }

    private func photosCard(_ r: ReturnDetail) -> some View {
        Group {
            if let photos = r.photos, !photos.isEmpty {
                SectionCard(title: "Фото от клиента") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(photos, id: \.self) { path in
                                RemoteImage(path: path, size: 96, cornerRadius: 12)
                            }
                        }
                    }
                }
            }
        }
    }

    private func logCard(_ r: ReturnDetail) -> some View {
        Group {
            if let log = r.log, !log.isEmpty {
                SectionCard(title: "История") {
                    ForEach(log) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ReturnLabels.status(entry.status))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(Brand.text)
                                if let c = entry.comment, !c.isEmpty {
                                    Text(c).font(.caption).foregroundColor(Brand.muted)
                                }
                            }
                            Spacer()
                            Text(DateFmt.short(entry.createdAt)).font(.caption).foregroundColor(Brand.muted)
                        }
                    }
                }
            }
        }
    }

    /// Весовой товар показывался «2.5» — с точкой, как в коде, а не «2,5».
    private func qty(_ q: Decimal?) -> String {
        QtyFmt.qty(q)
    }
}

// ── Одобрение: способ (бонусы/ручной) + сумма + комментарий ─────────────────
struct ApproveReturnSheet: View {
    @ObservedObject var vm: ReturnDetailViewModel
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var method = "bonus"
    @State private var amountText = ""
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Способ возврата") {
                    Picker("Способ", selection: $method) {
                        Text("Бонусами (сразу на счёт клиента)").tag("bonus")
                        Text("Ручной возврат (наличные/перевод)").tag("manual")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Сумма") {
                    TextField("По умолчанию — вся сумма заявки", text: $amountText)
                        .keyboardType(.decimalPad)
                    if let max = vm.detail?.refundAmount, max > 0 {
                        Text("Не больше суммы заявки — \(Money.rub(max))")
                            .font(.caption).foregroundColor(Brand.muted)
                    }
                }
                Section("Комментарий (необязательно)") {
                    TextField("Комментарий клиенту", text: $note)
                        // П-27.15: заметка возврата на сервере — до 255 знаков.
                        .onChange(of: note) { v in
                            let c = capReturnText(v)
                            if c != v { note = c }
                        }
                }
                if let err = localError {
                    Section { Text(err).font(.footnote).foregroundColor(Brand.red) }
                }
                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack { Spacer(); if isSubmitting { ProgressView() } else { Text("Одобрить возврат").bold() }; Spacer() }
                    }
                    .disabled(isSubmitting)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.bg.ignoresSafeArea())
            .navigationTitle("Одобрение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
            // паритет с Android: способ по умолчанию — тот, что выбрал клиент в заявке.
            .onAppear {
                if let m = vm.detail?.refundMethod, m == "bonus" || m == "manual" { method = m }
            }
        }
    }

    private func submit() async {
        var amount: Decimal?
        // Пробелы (в т.ч. неразрывные) внутри «1 500» убираем целиком:
        // Decimal(string:) читает префикс и молча вернул бы 1.
        let t = String(amountText.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            .replacingOccurrences(of: ",", with: ".")
        if !t.isEmpty {
            // паритет с Android: деньги — не больше двух знаков после запятой.
            guard let a = Money.strict(t),
                  // Ноль не принимаем: «0» бонусами закрывал возврат как выплаченный
                  // на 0 ₽ без возможности исправить. Полный возврат — пустое поле.
                  a > 0 else {
                localError = "Некорректная сумма"
                return
            }
            // паритет с Android: больше суммы заявки сервер не вернёт (min(amount, refund_amount)).
            if let cap = vm.detail?.refundAmount, cap > 0, a > cap {
                localError = "Не больше суммы заявки — \(Money.rub(cap))"
                return
            }
            amount = a
        }
        isSubmitting = true
        localError = nil
        let ok = await vm.approve(amount: amount, method: method, note: note.isEmpty ? nil : note)
        isSubmitting = false
        if ok {
            dismiss()
            onDone()
        } else if let s = vm.detail?.status, s != "pending" {
            // Заявку уже решили (другим устройством или до обрыва связи) — окно
            // одобрения больше не нужно: закрываем, итог и текст ошибки — на экране.
            dismiss()
            onDone()
        } else {
            localError = vm.error
        }
    }
}

/// П-27.15: обрезка текста возврата до 255 знаков — считаем символы Юникода,
/// как MySQL считает длину VARCHAR(255) (эмодзи-флаг — два знака).
fileprivate func capReturnText(_ s: String, max: Int = 255) -> String {
    guard s.unicodeScalars.count > max else { return s }
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s.unicodeScalars.prefix(max))
    return String(v)
}
