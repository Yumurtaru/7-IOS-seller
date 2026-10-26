import SwiftUI

// ============================================================================
//  Туристический налог.
// ----------------------------------------------------------------------------
//  С 2025 года курортный сбор заменён туристическим налогом: его ставку
//  устанавливает муниципалитет, и платит его объект размещения. В расчёте
//  брони он показывается гостю отдельной строкой и не входит в сервисный сбор
//  площадки. Пределы — до 10 % и до 10 000 ₽ (сервер их молча обрезает,
//  поэтому проверяем до сохранения).
// ============================================================================

@MainActor
final class LodgingTaxViewModel: ObservableObject {
    @Published var pct = ""
    @Published var minSum = ""
    @Published var hint: String?
    @Published var state: LoadState = .idle
    /// Ошибка ЧТЕНИЯ настроек — её «Повторить» перечитывает настройки.
    @Published var loadError: String?
    /// Ошибка СОХРАНЕНИЯ — её «Повторить» повторяет сохранение. Раньше это была
    /// одна переменная с одной кнопкой: продавец менял ставку, сохранение падало
    /// по сети, он жал «Повторить» — и экран перечитывал настройки, затирая
    /// введённое старым значением.
    @Published var saveError: String?
    @Published var saved = false
    @Published var isSaving = false
    /// Текущая ставка прочитана с сервера. Пока нет — сохранять НЕЛЬЗЯ: пустые
    /// поля ушли бы как «0» и обнулили налог, настроенный в веб-кабинете.
    @Published var loaded = false

    func load() async {
        state = .loading
        loadError = nil
        do {
            let s = try await API.shared.lodgingSettings()
            pct = (s.touristTaxPct ?? 0) == 0 ? "" : trimZeros(s.touristTaxPct ?? 0)
            minSum = (s.touristTaxMin ?? 0) == 0 ? "" : NSDecimalNumber(decimal: s.touristTaxMin ?? 0).stringValue
            hint = s.hint
            loaded = true
            state = .loaded
        } catch is CancellationError {
        } catch {
            state = .failed(error.localizedDescription)
            // Форма без этого текста выглядела как «налог не настроен», и
            // «Сохранить» затирало настоящую ставку нулём.
            loadError = error.localizedDescription
        }
    }

    private func trimZeros(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    func save() async {
        // Два тапа в одном кадре (кнопка гаснет только к следующему) слали
        // два одинаковых сохранения — второе пропускаем.
        guard loaded, !isSaving else { return }
        isSaving = true
        saveError = nil
        saved = false
        defer { isSaving = false }
        let pRaw = pct.trimmingCharacters(in: .whitespaces)
        // «5,5,» раньше молча становилось 0 — сбор обнулялся с «Сохранено».
        guard pRaw.isEmpty || Money.strict(pRaw) != nil else {
            saveError = "Процент — число, например 2 или 2,5"
            return
        }
        let mRaw = minSum.trimmingCharacters(in: .whitespaces)
        guard mRaw.isEmpty || Money.strict(mRaw) != nil else {
            saveError = "Минимальная сумма — число, например 100"
            return
        }
        // Значения — из строгого разбора: «1 000» раньше давало 1 ₽.
        let p = pRaw.isEmpty ? 0 : NSDecimalNumber(decimal: Money.strict(pRaw) ?? 0).doubleValue
        let m = mRaw.isEmpty ? Decimal(0) : (Money.strict(mRaw) ?? 0)
        // Сервер не отказывает, а молча режет до 10 % и 10 000 ₽
        // (seller_lodging.php, PUT lodging-settings) — с ответом «Сохранено».
        guard p <= 10 else {
            saveError = "Ставка — не больше 10 %"
            return
        }
        guard m <= 10_000 else {
            saveError = "Минимальная сумма — не больше 10 000 ₽"
            return
        }
        do {
            try await API.shared.saveLodgingSettings(taxPct: p, taxMin: m)
            saved = true
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct LodgingTaxView: View {
    @StateObject private var vm = LodgingTaxViewModel()

    var body: some View {
        Form {
            if let err = vm.loadError {
                Section {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                    Button("Загрузить снова") { Task { await vm.load() } }.font(.footnote)
                }
            }
            Section {
                HStack {
                    Text("Ставка, %").foregroundColor(Brand.text)
                    Spacer()
                    TextField("0", text: $vm.pct)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
                        .disabled(!vm.loaded)
                }
                HStack {
                    Text("Минимум за сутки, ₽").foregroundColor(Brand.text)
                    Spacer()
                    TextField("0", text: $vm.minSum)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 100)
                        .disabled(!vm.loaded)
                }
            } header: {
                Text("Туристический налог")
            } footer: {
                Text(vm.hint ?? "Ставку устанавливает муниципалитет. Налог показывается гостю отдельной строкой и в сервисный сбор площадки не входит. Ноль — налог не начисляется.")
            }
            Section {
                if let err = vm.saveError {
                    Text(err).font(.footnote).foregroundColor(Brand.red)
                }
                Button {
                    Task { await vm.save() }
                } label: {
                    HStack { Spacer(); if vm.isSaving { ProgressView() } else { Text("Сохранить").bold() }; Spacer() }
                }
                .disabled(vm.isSaving || !vm.loaded)
                if vm.saved {
                    Text("Сохранено. Новые брони считаются по этой ставке — уже созданные не меняются.")
                        .font(.caption).foregroundColor(Brand.green)
                }
            }
        }
        // «Сохранено» не должно висеть над уже изменёнными полями.
        .onChange(of: vm.pct) { _ in vm.saved = false }
        .onChange(of: vm.minSum) { _ in vm.saved = false }
        .scrollContentBackground(.hidden)
        .background(Brand.bg.ignoresSafeArea())
        .navigationTitle("Туристический налог")
        .navigationBarTitleDisplayMode(.inline)
        // listState здесь не подходит: он рисует состояние ТОЛЬКО поверх
        // пустого списка, а это форма — ошибку и спиннер показываем сами.
        .overlay {
            if vm.state == .loading && !vm.loaded {
                ProgressView().padding().background(Brand.card).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        // Один раз: возврат на вкладку затирал несохранённый процент.
        .task { if !vm.loaded { await vm.load() } }
    }
}
