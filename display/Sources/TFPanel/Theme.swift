import SwiftUI

/// 深色主题颜色常量（照抄原型 .screen 的 CSS 变量）
enum Theme {
    static let bg = color(0x0A, 0x0B, 0x0D)
    static let card = color(0x14, 0x16, 0x1A)
    static let cardLine = color(0x1D, 0x20, 0x25)
    static let text = color(0xF3, 0xF4, 0xF6)
    static let text2 = color(0xA7, 0xAD, 0xB6)
    static let muted = color(0x8C, 0x92, 0x9B)
    static let faint = color(0x55, 0x5B, 0x64)
    static let track = color(0x1D, 0x20, 0x25)
    static let accent = color(0x76, 0xE2, 0xB7)
    static let amber = color(0xF0, 0xB4, 0x4C)
    static let danger = color(0xE2, 0x7A, 0x72)
    static let ghost = color(0x59, 0x60, 0x6A)
    static let pillBg = accent.opacity(0.15)
    static let pillText = color(0x8E, 0xEA, 0xC5)

    /// 16 进制分量 → sRGB 颜色
    private static func color(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(.sRGB,
              red: Double(r) / 255,
              green: Double(g) / 255,
              blue: Double(b) / 255,
              opacity: 1)
    }
}
