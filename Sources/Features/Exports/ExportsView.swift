import SwiftUI

// ============================================================================
//  Экспорты — скачивание с Bearer во временный файл + системный share sheet:
//   • заказы XLSX: GET /api/seller/orders/export-xlsx?from=&to= (yyyy-MM-dd)
//   • кошелёк XLSX: GET /api/seller/wallet/export-xlsx
//   • кошелёк CSV:  GET /api/seller/wallet/export
//   • каталог и справочники: GET /api/seller/export/{products|clients|orders|
//     stock|ingredients|1c|template}
//
//  Выгрузки каталога закрыты правом «Товары» (products), выгрузки заказов и
//  кошелька — своими правами; сотруднику без права ручка ответит 403, и здесь
//  покажется текст сервера, а не пустой файл.
//
//  Ингредиенты есть только у ресторана, склад — не у услуг: лишние строки
//  прячем по типу организации, чтобы не предлагать заведомо пустой файл.
// ============================================================================

@MainActor
final class ExportsViewModel: ObservableObject {
    @Published var busy: String?          // какой экспорт сейчас качается
    @Published var error: String?
    @Published var shareFile: ShareFile?

    func exportOrders(from: Date, to: Date) async {
        await run("orders") {
            try await API.shared.exportOrdersXlsx(from: DateFmt.ymd(from), to: DateFmt.ymd(to))
        }
    }

    func exportWallet(xlsx: Bool) async {
        await run(xlsx ? "wallet-xlsx" : "wallet-csv") {
            try await API.shared.exportWallet(xlsx: xlsx)
        }
    }

    /// key совпадает с последним сегментом пути: products, clients, 1c и т.д.
    func exportData(_ key: String, fileName: String) async {
        await run("data-" + key) {
            try await API.shared.exportData(key, fallbackName: fileName)
        }
    }

    private func run(_ key: String, _ op: @escaping () async throws -> URL) async {
        guard busy == nil else { return }
        error = nil
        busy = key
        defer { busy = nil }
        do {
            let url = try await op()
            shareFile = ShareFile(url: url)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ExportsView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = ExportsViewModel()
    @State private var from = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var to = Date()

    var body: some View {
        Form {
            // Сервер закрывает выгрузку правом по её СОДЕРЖИМОМУ: заказы —
            // «Заказы», клиенты — «Клиенты», склад — «Склад», кошелёк —
            // «Финансы», остальное — «Товары». Раньше экран рисовал всё подряд,
            // и половина кнопок отвечала «Недостаточно прав».
            if session.can("orders") {
                Section {
                    DatePicker("С", selection: $from, displayedComponents: .date)
                    DatePicker("По", selection: $to, in: from..., displayedComponents: .date)
                        // Сдвинули «С» позже «По» — подтягиваем «По», иначе
                        // выгрузка уходила с from > to и приходила пустой.
                        .onChange(of: from) { f in if to < f { to = f } }
                    exportButton("Заказы за период (XLSX)", icon: "doc.badge.arrow.up", key: "orders") {
                        Task { await vm.exportOrders(from: from, to: to) }
                    }
                } header: {
                    Text("Заказы")
                } footer: {
                    Text("Номер, дата, статус, способ получения и оплаты, суммы, промокод.")
                }
                .listRowBackground(Brand.card)
            }

            // Сотрудник только с «Финансами» видел пустую секцию — показываем её,
            // только если доступна хоть одна выгрузка внутри.
            if hasCatalogExports {
            Section {
                if session.can("products") {
                    exportButton("Товары (XLSX)", icon: "shippingbox", key: "data-products") {
                        Task { await vm.exportData("products", fileName: "products.xlsx") }
                    }
                }
                if session.can("orders") {
                    exportButton("Все заказы (CSV)", icon: "list.bullet.rectangle", key: "data-orders") {
                        Task { await vm.exportData("orders", fileName: "orders.csv") }
                    }
                }
                if session.can("customers") {
                    exportButton("Клиенты (CSV)", icon: "person.2", key: "data-clients") {
                        Task { await vm.exportData("clients", fileName: "clients.csv") }
                    }
                }
                // У жилья склада нет, как и у услуг (в «Ещё» раздел склада ему не
                // показывается) — выгрузка остатков была заведомо пустой.
                if session.shopType != "service" && session.shopType != "lodging" && session.can("warehouse") {
                    exportButton("Остатки склада (XLSX)", icon: "archivebox", key: "data-stock") {
                        Task { await vm.exportData("stock", fileName: "stock.xlsx") }
                    }
                }
                if session.shopType == "cafe" && session.can("warehouse") {
                    exportButton("Ингредиенты (XLSX)", icon: "leaf", key: "data-ingredients") {
                        Task { await vm.exportData("ingredients", fileName: "ingredients.xlsx") }
                    }
                }
            } header: {
                Text("Каталог и справочники")
            } footer: {
                Text("Файлы формирует сервер — те же, что скачиваются в веб-кабинете.")
            }
            .listRowBackground(Brand.card)
            }

            if session.can("products") {
                Section {
                    exportButton("Выгрузка для 1С (XML)", icon: "doc.badge.gearshape", key: "data-1c") {
                        Task { await vm.exportData("1c", fileName: "1c_products.xml") }
                    }
                    exportButton("Шаблон для импорта (XLSX)", icon: "square.and.arrow.down", key: "data-template") {
                        Task { await vm.exportData("template", fileName: "import_template_products.xlsx") }
                    }
                } header: {
                    Text("Обмен")
                } footer: {
                    // В приложении есть свой импорт («Импорт из файла») — текст отправлял только в кабинет.
                    Text("Заполненный шаблон загружается в «Импорт из файла» или в веб-кабинете: импорт разбирает файл по шагам с предпросмотром.")
                }
                .listRowBackground(Brand.card)
            }

            if session.can("finance") {
                Section {
                    exportButton("История кошелька (XLSX)", icon: "tablecells", key: "wallet-xlsx") {
                        Task { await vm.exportWallet(xlsx: true) }
                    }
                    exportButton("История кошелька (CSV)", icon: "doc.plaintext", key: "wallet-csv") {
                        Task { await vm.exportWallet(xlsx: false) }
                    }
                } header: {
                    Text("Кошелёк")
                } footer: {
                    Text("Все операции: пополнения, комиссии, сервисные сборы, тариф, продвижение.")
                }
                .listRowBackground(Brand.card)
            }

            if let err = vm.error {
                Section {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Экспорт данных")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $vm.shareFile) { file in
            ShareSheet(items: [file.url])
        }
        // Отказ («Недостаточно прав», нет связи) писался строкой в самом низу
        // формы — после нажатия кнопки вверху его не видно, и выгрузка будто
        // молча не сработала.
        .errorAlert($vm.error)
    }

    /// Есть ли хоть одна кнопка в «Каталог и справочники». У услуг и жилья
    /// склада нет: сотрудник только со «Складом» видел там пустую секцию.
    private var hasCatalogExports: Bool {
        if session.can("products") || session.can("orders") || session.can("customers") { return true }
        let noStock = session.shopType == "service" || session.shopType == "lodging"
        return session.can("warehouse") && !noStock
    }

    private func exportButton(_ title: String, icon: String, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if vm.busy == key { ProgressView() }
            }
        }
        .disabled(vm.busy != nil)
        .foregroundColor(Brand.text)
    }
}
