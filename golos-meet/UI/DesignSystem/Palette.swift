import SwiftUI

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

struct Palette {
    let bg, sidebar, content, card, cardSel, border, borderSoft, fieldBorder: Color
    let ink, muted, muted2, selection, accent, link, btn, btnInk, danger, dangerBg: Color

    static let light = Palette(
        bg: Color(hex: 0xfbfbfb), sidebar: Color(hex: 0xfbfbfb), content: .white,
        card: .white, cardSel: Color(hex: 0xf3f3f1), border: Color(hex: 0xe6e6e3),
        borderSoft: Color(hex: 0xececea), fieldBorder: Color(hex: 0xd9d9d5),
        ink: Color(hex: 0x1d1d1f), muted: Color(hex: 0x7c7c80), muted2: Color(hex: 0x9c9ca0),
        selection: Color(hex: 0xececea), accent: Color(hex: 0x0a84ff), link: Color(hex: 0x0a84ff),
        btn: Color(hex: 0x1d1d1f), btnInk: .white, danger: Color(hex: 0xe5484d), dangerBg: Color(hex: 0xfdecec))

    static let dark = Palette(
        bg: Color(hex: 0x242426), sidebar: Color(hex: 0x242426), content: Color(hex: 0x1c1c1e),
        card: Color(hex: 0x242426), cardSel: Color(hex: 0x2d2d30), border: Color(hex: 0x343436),
        borderSoft: Color(hex: 0x2c2c2e), fieldBorder: Color(hex: 0x3a3a3c),
        ink: Color(hex: 0xf2f2f4), muted: Color(hex: 0x98989d), muted2: Color(hex: 0x6c6c70),
        selection: Color(hex: 0x323234), accent: Color(hex: 0x0a84ff), link: Color(hex: 0x4aa3ff),
        btn: Color(hex: 0xf2f2f4), btnInk: Color(hex: 0x1a1a1c), danger: Color(hex: 0xff5c5c), dangerBg: Color(hex: 0x3a2526))

    static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? dark : light }
}

private struct PaletteKey: EnvironmentKey { static let defaultValue = Palette.light }
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}
