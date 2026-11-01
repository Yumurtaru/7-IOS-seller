import SwiftUI

/// Плашка над списком: сервер чего-то ещё не умеет (поиск на старом сайте), а список
/// показан без этого. Не ошибка — янтарная полоса с текстом.
struct ServerNoticeBar: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundColor(Brand.text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Brand.amber.opacity(0.18))
    }
}
