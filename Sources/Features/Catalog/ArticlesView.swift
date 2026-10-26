import SwiftUI

// ============================================================================
//  Артикулы и штрихкоды — раздела в приложении не было, а без штрихкода товар
//  не пробить сканером на кассе.
//
//  Сохранение пакетное (POST /articles/bulk): отправляем только изменённые
//  строки. Сервер проверяет уникальность артикула в магазине и возвращает
//  список того, что не прошло, — показываем его как есть, не переписывая.
//
//  Пустая строка = очистить поле (сервер приводит её к NULL).
// ============================================================================

@MainActor
final class ArticlesViewModel: ObservableObject {
    @Published var rows: [ArticleRow] = []
    @Published var state: LoadState = .idle
    @Published var error: String?
    @Published var saving = false
    @Published var savedMessage: String?

    /// Правки пользователя: id → (артикул, штрихкод). Отправляем только их.
    @Published var edits: [Int: (article: String, barcode: String)] = [:]

    var hasChanges: Bool { !edits.isEmpty }

    func load() async {
        if rows.isEmpty { state = .loading }
        do {
            let fresh = try await API.shared.articles()
            rows = fresh
            // Оставляем правки, которые не совпали с сервером: строки, которые
            // сервер отклонил (дубль артикула), раньше стирались вместе с
            // остальными, и значение приходилось вводить заново по памяти.
            edits = edits.filter { id, e in
                guard let r = fresh.first(where: { $0.rowId == id }) else { return false }
                // Без пробелов по краям: сервер их обрезает, и сохранённая
                // правка иначе «висела» бы несохранённой.
                return e.article.trimmingCharacters(in: .whitespaces) != (r.article ?? "").trimmingCharacters(in: .whitespaces)
                    || e.barcode.trimmingCharacters(in: .whitespaces) != (r.barcode ?? "").trimmingCharacters(in: .whitespaces)
            }
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func article(for row: ArticleRow) -> String { edits[row.rowId]?.article ?? row.article ?? "" }
    func barcode(for row: ArticleRow) -> String { edits[row.rowId]?.barcode ?? row.barcode ?? "" }

    func setArticle(_ row: ArticleRow, _ value: String) {
        let current = edits[row.rowId] ?? (row.article ?? "", row.barcode ?? "")
        edits[row.rowId] = (value, current.barcode)
    }

    func setBarcode(_ row: ArticleRow, _ value: String) {
        let current = edits[row.rowId] ?? (row.article ?? "", row.barcode ?? "")
        edits[row.rowId] = (current.article, value)
    }

    func save() async {
        guard hasChanges, !saving else { return }   // двойной тап — один запрос
        saving = true; defer { saving = false }
        let payload = edits.map { ArticleEdit(id: $0.key, article: $0.value.article, barcode: $0.value.barcode) }
        do {
            let ack = try await API.shared.saveArticles(payload)
            if let errs = ack.errors, !errs.isEmpty {
                // Сервер отвечает построчно: часть могла сохраниться.
                error = errs.joined(separator: "\n")
            } else {
                savedMessage = "Сохранено строк: \(ack.saved ?? payload.count)"
            }
            await load()
        } catch { self.error = error.localizedDescription }
    }

    /// EAN-13 из внутреннего диапазона 200… — считает сервер и сразу пишет в товар.
    func generate(_ row: ArticleRow) async {
        do {
            let ack = try await API.shared.generateBarcode(productId: row.rowId)
            if let code = ack.barcode {
                // Пишем в правки, а не в rows: экран мог быть уже отредактирован,
                // и перезагрузка списка потеряла бы несохранённое.
                setBarcode(row, code)
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct ArticlesView: View {
    @StateObject private var vm = ArticlesViewModel()
    @State private var query = ""

    private var filtered: [ArticleRow] {
        guard !query.isEmpty else { return vm.rows }
        let q = query.lowercased()
        return vm.rows.filter {
            ($0.name ?? "").lowercased().contains(q)
                || ($0.article ?? "").lowercased().contains(q)
                || ($0.barcode ?? "").contains(q)
        }
    }

    var body: some View {
        List {
            ForEach(filtered) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.name ?? "—")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(Brand.text)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        TextField("Артикул", text: Binding(
                            get: { vm.article(for: row) },
                            set: { vm.setArticle(row, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                        TextField("Штрихкод", text: Binding(
                            get: { vm.barcode(for: row) },
                            set: { vm.setBarcode(row, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()

                        Button {
                            Task { await vm.generate(row) }
                        } label: {
                            Image(systemName: "barcode")
                        }
                        .buttonStyle(.borderless)
                        .help("Сгенерировать EAN-13")
                    }
                }
                .padding(.vertical, 2)
                .listRowBackground(Brand.card)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .searchable(text: $query, prompt: "Поиск по названию, артикулу, штрихкоду")
        .navigationTitle("Артикулы")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Сохранить") { Task { await vm.save() } }
                    .disabled(!vm.hasChanges || vm.saving)
            }
        }
        .refreshable { await vm.load() }
        // Не только .idle: ушли с экрана посреди первой загрузки — она отменилась,
        // состояние осталось .loading, и при возврате спиннер висел навсегда.
        .task { if vm.state != .loaded { await vm.load() } }
        .listState(vm.state, isEmpty: vm.rows.isEmpty,
                   emptyIcon: "barcode", emptyTitle: "Товаров нет",
                   emptySubtitle: "Артикулы и штрихкоды проставляются товарам магазина",
                   retry: { Task { await vm.load() } })
        .alert("Не всё сохранилось", isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } })) {
            Button("Понятно", role: .cancel) { vm.error = nil }
        } message: { Text(vm.error ?? "") }
        .alert("Готово", isPresented: Binding(get: { vm.savedMessage != nil }, set: { if !$0 { vm.savedMessage = nil } })) {
            Button("Хорошо", role: .cancel) { vm.savedMessage = nil }
        } message: { Text(vm.savedMessage ?? "") }
    }
}
