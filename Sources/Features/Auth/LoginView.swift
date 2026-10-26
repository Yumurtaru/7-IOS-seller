import SwiftUI

// ============================================================================
//  Вход в кабинет: email/телефон + пароль, выбор типа кабинета.
//  POST /api/seller/login | /api/kafe/login | /api/service/login
//  (все три принимают любой из account_type seller/kafe/service — выбор
//  панели влияет только на endpoint, сервер проверяет права одинаково).
// ============================================================================

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var login = ""
    @Published var password = ""
    @Published var panel = "seller"          // seller | kafe | service | lodging
    @Published var isLoading = false
    @Published var error: String?

    func submit() async {
        // «Войти» на клавиатуре не гасится вместе с кнопкой: второй ввод слал
        // второй вход — две сессии на сервере и два bootstrap подряд.
        guard !isLoading else { return }
        let l = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty, !password.isEmpty else {
            error = "Введите логин и пароль"
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let res = try await API.shared.login(panel: panel, login: l, password: password)
            // Заявка на организацию ещё не одобрена (или отклонена): вход проходит,
            // а организации нет — первый же запрос кабинета отвечал 401, и новый
            // продавец видел «Сессия истекла — войдите снова». Признак: не владелец
            // и без прав и роли; тогда спрашиваем статус заявки.
            // Сотрудник (сервер прислал `employee`) статус своей старой заявки не проверяет:
            // иначе удалённая когда-то своя организация закрыла бы ему вход в чужую.
            if res.isOwner == false && !res.hasEmployee && (res.permissions ?? [:]).isEmpty && res.role == nil,
               let note = await pendingRegistrationNote() {
                Session.shared.signOut()   // токен этого входа не оставляем
                error = note
                return
            }
            Session.shared.signIn(response: res)
            PushManager.shared.requestAuthorization()
        } catch let e as APIError {
            error = e.localizedDescription
        } catch {
            self.error = "Не удалось войти. Попробуйте ещё раз"
        }
    }

    /// Текст для экрана входа, если организация ещё не заведена. nil — заявки
    /// нет или статус не узнать: входим как раньше (сотрудник без роли и т.п.).
    private func pendingRegistrationNote() async -> String? {
        guard let reg = try? await API.shared.registrationStatus() else { return nil }
        let name = (reg.shopName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? "Заявка на регистрацию" : "Заявка «\(name)»"
        switch reg.status {
        case "pending":
            return title + " ещё на проверке у администратора (обычно до 24 часов). Войдите после одобрения — кабинет откроется сам."
        case "rejected":
            let why = (reg.adminNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title + " отклонена." + (why.isEmpty ? "" : " Причина: " + why + ".") + " Подать заново можно на yumurta.ru."
        case "more_info_needed":
            // Администратор вернул заявку на доработку — иначе вход молча пускал в пустой кабинет.
            let why = (reg.adminNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title + " требует уточнений." + (why.isEmpty ? "" : " " + why + ".") + " Дополните заявку на yumurta.ru."
        case "approved":
            // Волна А75: заявка одобрена (в т.ч. сразу при регистрации). Организация
            // есть — входим как обычно (черновик открывает кабинет, публикация — там).
            // Сервер явно сказал, что организации с панелью нет (удалили или
            // заблокировали) — объясняем, а не пускаем в кабинет, где всё отвечает 401.
            if reg.shopExists == false {
                let org = name.isEmpty ? "Организация" : "Организация «\(name)»"
                return org + " не найдена или заблокирована. Напишите в поддержку на yumurta.ru."
            }
            return nil
        default:
            return nil
        }
    }
}

struct LoginView: View {
    @StateObject private var vm = LoginViewModel()
    /// Причина выхода (сессия истекла) — иначе экран входа появлялся посреди
    /// работы без объяснения, а набранная форма просто пропадала.
    @EnvironmentObject private var session: Session
    @FocusState private var focus: Field?
    enum Field { case login, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Yumurta")
                        .font(.system(size: 40, weight: .heavy, design: .rounded))
                        .foregroundColor(Brand.accent)
                    Text("Бизнес")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(Brand.text)
                    Text("Кабинет продавца, кафе, услуг и жилья")
                        .font(.subheadline)
                        .foregroundColor(Brand.muted)
                }
                .padding(.top, 60)

                VStack(spacing: 14) {
                    // Выбор влияет только на ручку входа: права сервер
                    // проверяет во всех одинаково. «Жильё» входит как магазин
                    // (у владельца жилья account_type = seller), а разделы
                    // после входа берутся из shops.type.
                    Picker("Тип кабинета", selection: $vm.panel) {
                        Text("Магазин").tag("seller")
                        Text("Кафе").tag("kafe")
                        Text("Услуги").tag("service")
                        Text("Жильё").tag("lodging")
                    }
                    .pickerStyle(.segmented)

                    // А107: «+7 8928…» (лишняя 8 после +7) — цифра убирается при вводе (PhoneInput.fix).
                    TextField("Email или телефон", text: $vm.login.phoneInput)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .login)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                        .padding(14)
                        .background(Brand.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    SecureField("Пароль", text: $vm.password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { Task { await vm.submit() } }
                        .padding(14)
                        .background(Brand.card)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if let error = vm.error {
                        Text(error)
                            .font(.footnote)
                            .foregroundColor(Brand.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let note = session.signOutNotice {
                        Text(note)
                            .font(.footnote)
                            .foregroundColor(Brand.amber)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await vm.submit() }
                    } label: {
                        Group {
                            if vm.isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Войти").font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .background(Brand.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .disabled(vm.isLoading)
                }
                .padding(.horizontal, 20)

                // Новый продавец без кабинета: раньше адрес был простым текстом,
                // и с телефона до регистрации нужно было добираться вручную.
                VStack(spacing: 4) {
                    Text("Ещё нет кабинета?")
                        .font(.footnote)
                        .foregroundColor(Brand.muted)
                    Link("Зарегистрировать организацию на yumurta.ru",
                         destination: URL(string: "https://yumurta.ru/register-seller")!)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Brand.accent)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Brand.bg.ignoresSafeArea())
    }
}
