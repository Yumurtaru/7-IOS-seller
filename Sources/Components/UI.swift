import SwiftUI

// ============================================================================
//  UI.swift — общие компоненты: состояния загрузки/ошибки/пустоты, чипы,
//  карточки, удалённые изображения, бейджи статусов.
// ============================================================================

/// Универсальное состояние экрана со списком.
enum LoadState: Equatable {
    case idle, loading, loaded
    case failed(String)
}

/// Баннер ошибки с кнопкой «Повторить» (текст — от сервера).
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(Brand.amber)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(Brand.text)
            if let retry = retry {
                Button("Повторить", action: retry)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    /// Кнопка следующего шага («Добавить первый товар»): новому продавцу
    /// пустой экран без действия не подсказывал, что делать дальше.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundColor(Brand.muted)
            Text(title)
                .font(.headline)
                .foregroundColor(Brand.text)
            if let s = subtitle {
                Text(s)
                    .font(.subheadline)
                    .foregroundColor(Brand.muted)
                    .multilineTextAlignment(.center)
            }
            if let t = actionTitle, let action = action {
                Button(t, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.accent)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
    }
}

/// Чип-фильтр.
struct FilterChip: View {
    let title: String
    let selected: Bool
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(selected ? Color.white.opacity(0.25) : Brand.accent)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(selected ? Brand.accent : Brand.chip)
            .foregroundColor(selected ? .white : Brand.text)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Карточка-секция.
struct SectionCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title {
                Text(t).font(.headline).foregroundColor(Brand.text)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Бейдж статуса.
struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}

/// Удалённое изображение с плейсхолдером (пути сервера — /assets/uploads/...).
struct RemoteImage: View {
    let path: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat = 10
    var placeholderIcon: String = "photo"

    var body: some View {
        Group {
            if let url = API.imageURL(path) {
                // Своя сессия на 16 соединений и кэш: AsyncImage (URLSession.shared,
                // 6 соединений без HTTP/2) ставил фото списков в очередь.
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    default:
                        ProgressView()
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .background(Brand.chip)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: placeholderIcon)
            .foregroundColor(Brand.muted)
    }
}

/// Строка «ключ — значение».
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(.subheadline).foregroundColor(Brand.muted)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundColor(Brand.text)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Модификатор обработки состояний списка: loading / failed / empty / content.
struct ListStateOverlay: ViewModifier {
    let state: LoadState
    let isEmpty: Bool
    let emptyIcon: String
    let emptyTitle: String
    var emptySubtitle: String? = nil
    var retry: (() -> Void)? = nil
    var emptyActionTitle: String? = nil
    var emptyAction: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.overlay {
            switch state {
            case .loading where isEmpty:
                ProgressView().controlSize(.large)
            case .failed(let msg) where isEmpty:
                ErrorBanner(message: msg, retry: retry)
            case .loaded where isEmpty, .idle where isEmpty:
                EmptyState(icon: emptyIcon, title: emptyTitle, subtitle: emptySubtitle,
                           actionTitle: emptyActionTitle, action: emptyAction)
            default:
                EmptyView()
            }
        }
        // Данные на экране есть, а перечитать не вышло (смена периода или
        // фильтра, обновление жестом). Раньше ошибка не показывалась вовсе, и
        // под новым чипом молча оставались старые цифры.
        .overlay(alignment: .bottom) {
            if case .failed(let msg) = state, !isEmpty {
                Button { retry?() } label: {
                    Text("Не обновилось: " + msg + (retry == nil ? "" : " · Повторить"))
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Brand.red, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
        }
    }
}

extension View {
    /// Ошибка поверх открытой шторки: alert экрана-списка, который сейчас под
    /// шторкой, SwiftUI не показывает — сохранение «молча» не срабатывало.
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert("Не получилось", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("Понятно", role: .cancel) { error.wrappedValue = nil }
        } message: { Text(error.wrappedValue ?? "") }
    }

    func listState(_ state: LoadState, isEmpty: Bool, emptyIcon: String, emptyTitle: String,
                   emptySubtitle: String? = nil, retry: (() -> Void)? = nil,
                   emptyActionTitle: String? = nil, emptyAction: (() -> Void)? = nil) -> some View {
        modifier(ListStateOverlay(state: state, isEmpty: isEmpty, emptyIcon: emptyIcon,
                                  emptyTitle: emptyTitle, emptySubtitle: emptySubtitle, retry: retry,
                                  emptyActionTitle: emptyActionTitle, emptyAction: emptyAction))
    }
}

/// Тонкий баннер ошибки поверх контента (когда данные уже есть).
struct InlineErrorBar: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote.weight(.semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Brand.red)
    }
}

/// АY (сайт А616): сравнение с прошлым периодом — «▲ 12% · было N» (рост, зелёный) /
/// «▼ 5% · было N» (падение, красный). В прошлом периоде ноль (или меньше) или
/// процент округлился до нуля — без стрелки и процента, только «было N»
/// (как revenue_change сервера: процент только при прошлом > 0).
enum TrendLogic {
    /// up: true — рост, false — падение, nil — без процента.
    static func text(current: Decimal, previous: Decimal, format: (Decimal) -> String) -> (text: String, up: Bool?) {
        let was = "было " + format(previous)
        guard previous > 0 else { return (was, nil) }
        let ratio = NSDecimalNumber(decimal: (current - previous) / previous * 100).doubleValue
        guard ratio.isFinite else { return (was, nil) }
        let pct = Int(abs(ratio).rounded())
        guard pct != 0 else { return (was, nil) }
        return ratio > 0 ? ("▲ \(pct)% · " + was, true) : ("▼ \(pct)% · " + was, false)
    }
}

/// Строка тренда под цифрой. previous nil — ничего (старый сервер или нет права).
struct TrendText: View {
    let current: Decimal?
    let previous: Decimal?
    let format: (Decimal) -> String

    var body: some View {
        if let prev = previous {
            let t = TrendLogic.text(current: current ?? 0, previous: prev, format: format)
            Text(t.text)
                .font(.caption2.weight(.semibold))
                .foregroundColor(t.up == true ? Brand.green : (t.up == false ? Brand.red : Brand.muted))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
