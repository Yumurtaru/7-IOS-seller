import SwiftUI

// ============================================================================
//  QR витрины — GET /api/seller/marketing/qr.svg и qr.png.
//
//  Оба файла отдаёт сервер (core/Qr.php): печатные материалы не должны зависеть
//  от внешнего генератора. Ручки требуют Bearer, поэтому просто открыть ссылку
//  в браузере нельзя — качаем с заголовком и отдаём в системный share sheet,
//  как это уже сделано для выгрузок.
//
//  Право — «Маркетинг» (promotions).
// ============================================================================

@MainActor
final class ShopQRViewModel: ObservableObject {
    @Published var preview: UIImage?
    @Published var loading = false
    @Published var busy: String?
    @Published var error: String?
    @Published var shareFile: ShareFile?

    /// Предпросмотр — PNG поменьше: его же потом можно отправить в мессенджер.
    func loadPreview() async {
        guard preview == nil, !loading else { return }
        loading = true
        defer { loading = false }
        error = nil   // повтор: прошлая ошибка не висит над новой попыткой
        do {
            let url = try await API.shared.shopQrFile(svg: false, size: 512)
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                preview = img
            } else {
                error = "Не удалось прочитать QR-код"
            }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    func share(svg: Bool) async {
        guard busy == nil else { return }
        busy = svg ? "svg" : "png"
        defer { busy = nil }
        error = nil
        do {
            shareFile = ShareFile(url: try await API.shared.shopQrFile(svg: svg, size: 1024))
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ShopQRView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = ShopQRViewModel()

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    if let img = vm.preview {
                        Image(uiImage: img)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(maxWidth: 240, maxHeight: 240)
                    } else if vm.loading {
                        ProgressView().frame(height: 240)
                    } else {
                        Image(systemName: "qrcode")
                            .resizable().scaledToFit()
                            .frame(width: 120, height: 120)
                            .foregroundColor(Brand.muted)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let url = session.shopPublicUrl {
                        Text("Код ведёт на \(url)")
                    } else {
                        Text("Код ведёт на страницу вашей витрины на Yumurta.")
                    }
                    // Новая организация (draft/review) клиентам не видна: по коду
                    // открывалось «не найдено», и наклейки печатали впустую.
                    if ["draft", "review", "pending"].contains(session.shopStatus) {
                        Text("Организация ещё не опубликована — до публикации клиенты по этому коду её не увидят.")
                            .foregroundColor(Brand.amber)
                    }
                }
            }
            .listRowBackground(Brand.card)

            Section {
                button("Отправить PNG", icon: "square.and.arrow.up", key: "png") {
                    Task { await vm.share(svg: false) }
                }
                button("Отправить SVG для печати", icon: "printer", key: "svg") {
                    Task { await vm.share(svg: true) }
                }
                if let url = session.shopPublicUrl {
                    Button {
                        UIPasteboard.general.string = url
                    } label: {
                        Label("Скопировать ссылку на витрину", systemImage: "link")
                    }
                    .foregroundColor(Brand.text)
                }
            } footer: {
                Text("SVG — вектор: печатается в любом размере без потери качества. PNG удобнее отправить в мессенджере.")
            }
            .listRowBackground(Brand.card)

            if let err = vm.error {
                Section {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                    // QR не загрузился (нет связи) — раньше повторить можно было
                    // только выйдя с экрана и зайдя снова.
                    if vm.preview == nil && !vm.loading {
                        Button("Загрузить QR-код снова") { Task { await vm.loadPreview() } }
                            .font(.footnote.weight(.semibold))
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("QR витрины")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $vm.shareFile) { file in ShareSheet(items: [file.url]) }
        .task { await vm.loadPreview() }
    }

    private func button(_ title: String, icon: String, key: String, action: @escaping () -> Void) -> some View {
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
