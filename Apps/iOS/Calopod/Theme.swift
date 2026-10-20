import CalopodDomain
import CalopodSnapshot
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

    /// Built once per palette entry; the Mac's palette, so both apps show the same colors.
    private static let calendarColors: [String: Color] = Dictionary(
        uniqueKeysWithValues: CalendarPalette.entries.map { ($0.id, Color(light: $0.light, dark: $0.dark)) })

    static func calendarColor(_ calendar: CalendarEntry?) -> Color {
        calendarColors[(calendar?.paletteEntry ?? CalendarPalette.neutral).id] ?? faint
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

extension SyncIssueKind {
    var color: Color { self == .failed ? Theme.bad : Theme.caution }
}
