import SwiftUI
import UIKit

private extension Color {
    /// One token that resolves per appearance. Hex values are 0xRRGGBB.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        func ui(_ hex: UInt32, _ alpha: Double) -> UIColor {
            UIColor(
                red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark, darkAlpha) : ui(light, lightAlpha) })
    }
}

/// The same tokens as the Mac app and the design mockup. Screens use these, never raw colors.
enum Theme {
    static let accent = Color(light: 0xb45309, dark: 0xf5a623)
    static let onAccent = Color(light: 0xffffff, dark: 0x1c1206)
    static let accentSoft = Color(light: 0xb45309, dark: 0xf5a623, lightAlpha: 0.11, darkAlpha: 0.16)

    static let screen = Color(light: 0xf3efea, dark: 0x100e0d)
    static let card = Color(light: 0xffffff, dark: 0x221e1b)
    static let line = Color(light: 0x1a1612, dark: 0xfff0dc, lightAlpha: 0.06, darkAlpha: 0.07)
    static let fill = Color(light: 0x1a1612, dark: 0xfff0dc, lightAlpha: 0.055, darkAlpha: 0.08)

    static let text = Color(light: 0x1b1714, dark: 0xf4efe8)
    static let secondary = Color(light: 0x6f675e, dark: 0xa79f95)
    static let faint = Color(light: 0xa8a199, dark: 0x6f675e)

    static let good = Color(light: 0x2f9e6e, dark: 0x6fdba8)
    static let caution = Color(light: 0xa97800, dark: 0xecc456)
    static let cautionSoft = Color(light: 0xc99600, dark: 0xecc456, lightAlpha: 0.16, darkAlpha: 0.17)
    static let bad = Color(light: 0xc43d3d, dark: 0xf07a7a)
    static let badSoft = Color(light: 0xc43d3d, dark: 0xf07a7a, lightAlpha: 0.12, darkAlpha: 0.17)

    /// The 12 calendar colors the Mac offers. A calendar stores its position in this list.
    static let palette: [Color] = [
        Color(light: 0xe5604d, dark: 0xff8a78), Color(light: 0xe07a1f, dark: 0xffa552),
        Color(light: 0xd4a017, dark: 0xf5c542), Color(light: 0x7aa62e, dark: 0xb5e062),
        Color(light: 0x25a06a, dark: 0x7ee0b0), Color(light: 0x1e9aa0, dark: 0x6fd6da),
        Color(light: 0x2b7fd6, dark: 0x8ec5f5), Color(light: 0x5a5fd6, dark: 0xa0a6ff),
        Color(light: 0x8a55d6, dark: 0xc4a0ff), Color(light: 0xd4478c, dark: 0xf5a0c8),
        Color(light: 0x6b6b73, dark: 0xb4b0ab), Color(light: 0xa8794f, dark: 0xd8b48c),
    ]

    static func calendarColor(_ index: Int?) -> Color {
        guard let index, palette.indices.contains(index) else { return faint }
        return palette[index]
    }

    enum Fonts {
        static let title = Font.system(.largeTitle, design: .serif).weight(.semibold)
        static let heading = Font.system(.title3, design: .serif).weight(.semibold)
        static let body = Font.subheadline
        static let bodyStrong = Font.subheadline.weight(.semibold)
        static let secondary = Font.footnote
        static let caption = Font.caption.weight(.semibold)
        static let sectionLabel = Font.caption.weight(.semibold)
    }

    static let cardRadius: CGFloat = 18
    static let headerRadius: CGFloat = 30
    static let sidePadding: CGFloat = 16
}
