import SwiftUI
import UIKit

private extension UIColor {
    convenience init(rgb: UInt) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Адаптивный цвет (light/dark). Приложение по умолчанию тёмное, но палитра честная для обеих тем.
private func dyn(_ light: UInt, _ dark: UInt) -> Color {
    Color(UIColor { tc in tc.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
}

/// Палитра Yumurta — как в клиентском iOS-приложении (Sources/App/Theme.swift референса).
enum Brand {
    static let accent = Color(red: 1.0, green: 0.231, blue: 0.0)    // #FF3B00
    static let amber  = Color(red: 1.0, green: 0.722, blue: 0.0)    // #FFB800
    static let bg     = dyn(0xF2F2F7, 0x111114)
    static let card   = dyn(0xFFFFFF, 0x1C1C1E)
    static let text   = dyn(0x1C1C1E, 0xEDEDED)
    static let muted  = dyn(0x8E8E93, 0x8E8E93)
    static let border = dyn(0xE5E5EA, 0x2A2A2E)
    static let chip   = dyn(0xE6E6EB, 0x2A2A2E)
    static let green  = Color(red: 0.20, green: 0.78, blue: 0.45)
    static let red    = Color(red: 1.0, green: 0.231, blue: 0.188)  // #FF3B30
}
