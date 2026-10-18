import SwiftUI

extension Color {
    /// Resolves per appearance, so one token covers light and dark.
    init(light: Color, dark: Color) {
        let light = NSColor(light), dark = NSColor(dark)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

enum Theme {
    /// The type scale. Screens use these, never raw sizes.
    enum Fonts {
        static let pageTitle = Font.system(size: 30, weight: .semibold, design: .serif)
        static let heading = Font.system(size: 22, weight: .semibold, design: .serif)
        static let sectionTitle = Font.system(size: 19, weight: .semibold, design: .serif)
        static let body = Font.system(size: 15)
        static let bodyMedium = Font.system(size: 15, weight: .medium)
        static let bodySemibold = Font.system(size: 15, weight: .semibold)
        static let secondary = Font.system(size: 13)
        static let secondaryMedium = Font.system(size: 13, weight: .medium)
        static let secondarySemibold = Font.system(size: 13, weight: .semibold)
        static let tiny = Font.system(size: 12)
        static let tinyMedium = Font.system(size: 12, weight: .medium)
        static let tinySemibold = Font.system(size: 12, weight: .semibold)
        static let tinyBold = Font.system(size: 12, weight: .bold)
        /// Hour labels and day headers in the calendar.
        static let label = Font.system(size: 14)
        static let eventTitle = Font.system(size: 13, weight: .semibold)
        static let button = Font.system(size: 15, weight: .semibold)
        static let chip = Font.system(size: 14, weight: .medium)
        static let icon = Font.system(size: 20)
        static let railIcon = Font.system(size: 22)
        static let smallIcon = Font.system(size: 12, weight: .semibold)
        static let glyph = Font.system(size: 34, weight: .medium)
        static let emptyGlyph = Font.system(size: 30, weight: .medium)
    }

    /// Control sizes.
    enum Control {
        static let height: CGFloat = 36
        static let chipHeight: CGFloat = 32
        static let smallChipHeight: CGFloat = 28
        static let rowHeight: CGFloat = 44
        static let popoverRowHeight: CGFloat = 36
        static let circle: CGFloat = 36
    }

    static let accent = Color(
        light: Color(red: 0xb4 / 255, green: 0x53 / 255, blue: 0x09 / 255),
        dark: Color(red: 0xf5 / 255, green: 0xa6 / 255, blue: 0x23 / 255))
    /// Text and icons on top of a filled accent.
    static let onAccent = Color(light: .white, dark: Color(red: 0.13, green: 0.08, blue: 0.02))

    // Status colors stay clear of the accent hue.
    static let good = Color(red: 0.20, green: 0.62, blue: 0.40)
    static let caution = Color(red: 0.80, green: 0.66, blue: 0.10)
    static let bad = Color(red: 0.80, green: 0.28, blue: 0.28)

    // Window, panels and glass. From most to least see-through: the frame around the
    // panels, then the sidebar, then the content card (and the inner fill on it). Each
    // step is gentle. ThemeTests keeps this order.
    /// The behind-window material, the one Zen Browser defaults to. The sidebar and
    /// underWindowBackground materials both washed the desktop out.
    static let windowMaterial: NSVisualEffectView.Material = .hudWindow
    // The five see-through fills read their opacity from AppSettings, so the Settings
    // sliders move them live. GlassBase holds the defaults.
    @MainActor static var frameTint: Color {
        let scale = AppSettings.shared.frameScale
        return Color(
            light: Color(red: 1, green: 0.56, blue: 0.28).opacity(clamped(GlassBase.frame.light * scale)),
            dark: Color(red: 0.92, green: 0.43, blue: 0.16).opacity(clamped(GlassBase.frame.dark * scale)))
    }
    static let pane = Color(light: .white, dark: Color(red: 0x17 / 255, green: 0x14 / 255, blue: 0x12 / 255))
    static let group = Color(
        light: Color(red: 0xf6 / 255, green: 0xf4 / 255, blue: 0xf1 / 255),
        dark: Color(red: 0x20 / 255, green: 0x1c / 255, blue: 0x19 / 255))
    static let paneLine = Color(
        light: Color(red: 0.10, green: 0.09, blue: 0.07).opacity(0.06),
        dark: Color(red: 1, green: 0.94, blue: 0.86).opacity(0.06))
    // Inactive windows flatten to near solid, which also makes them cheap to composite.
    @MainActor static var sidebarSheen: Color {
        let scale = AppSettings.shared.sidebarScale
        return Color(
            light: Color.white.opacity(clamped(GlassBase.sidebarSheen.light * scale)),
            dark: Color(red: 0.30, green: 0.26, blue: 0.22).opacity(clamped(GlassBase.sidebarSheen.dark * scale)))
    }
    @MainActor static var sidebarFill: Color {
        let scale = AppSettings.shared.sidebarScale
        return Color(
            light: Color.white.opacity(clamped(GlassBase.sidebarFill.light * scale)),
            dark: Color(red: 0.12, green: 0.10, blue: 0.09).opacity(clamped(GlassBase.sidebarFill.dark * scale)))
    }
    @MainActor static var contentFill: Color {
        let scale = AppSettings.shared.contentScale
        return Color(
            light: Color.white.opacity(clamped(GlassBase.content.light * scale)),
            dark: Color(red: 0x17 / 255, green: 0x14 / 255, blue: 0x12 / 255).opacity(clamped(GlassBase.content.dark * scale)))
    }
    @MainActor static var innerFill: Color {
        let scale = AppSettings.shared.contentScale
        return Color(
            light: Color.white.opacity(clamped(GlassBase.inner.light * scale)),
            dark: Color(red: 0x20 / 255, green: 0x1c / 255, blue: 0x19 / 255).opacity(clamped(GlassBase.inner.dark * scale)))
    }
    private static func clamped(_ alpha: Double) -> Double { min(1, max(0, alpha)) }
    static let sidebarInactive = Color(
        light: Color.white.opacity(0.80), dark: Color(red: 0x1b / 255, green: 0x17 / 255, blue: 0x15 / 255).opacity(0.86))
    static let cardInactive = Color(
        light: Color.white.opacity(0.94), dark: Color(red: 0x17 / 255, green: 0x14 / 255, blue: 0x12 / 255).opacity(0.94))
    static let innerInactive = Color(
        light: Color(red: 0xf6 / 255, green: 0xf4 / 255, blue: 0xf1 / 255).opacity(0.96),
        dark: Color(red: 0x20 / 255, green: 0x1c / 255, blue: 0x19 / 255).opacity(0.96))
    // Sidebar text sits straight on the wallpaper, so it uses firmer colors than the defaults.
    static let sidebarLabel = Color(
        light: Color(red: 0.09, green: 0.06, blue: 0.03), dark: Color(red: 0.99, green: 0.97, blue: 0.94))
    static let sidebarSecondary = Color(
        light: Color(red: 0.09, green: 0.06, blue: 0.03).opacity(0.68),
        dark: Color(red: 0.99, green: 0.97, blue: 0.94).opacity(0.72))
    // Edge highlight: crisp on the top and left, fading toward the bottom right.
    static let glassEdge = Color(
        light: Color.white.opacity(0.95), dark: Color(red: 1, green: 0.94, blue: 0.86).opacity(0.34))
    static let glassEdgeFade = Color(
        light: Color.white.opacity(0.25), dark: Color(red: 1, green: 0.94, blue: 0.86).opacity(0.07))
    static let panelShadow = Color(
        light: Color(red: 0.28, green: 0.13, blue: 0).opacity(0.30), dark: Color.black.opacity(0.45))

    /// The corner of a card, the inner panels of the pages and the popover cards.
    static let cardRadius: CGFloat = 16
    static let controlRadius: CGFloat = 12
    static let pagePadding: CGFloat = 28

}

/// Frosted fill for a panel, or the solid pane when Reduce Transparency is on.
struct PanelFill<S: Shape>: ViewModifier {
    enum Level { case card, inner }
    let level: Level
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.background {
            if AppSettings.shared.isSolid(reduceTransparency: reduceTransparency) {
                shape.fill(level == .card ? Theme.pane : Theme.group)
            } else if activeState == .inactive {
                shape.fill(level == .card ? Theme.cardInactive : Theme.innerInactive)
            } else {
                shape.fill(level == .card ? Theme.contentFill : Theme.innerFill)
            }
        }
    }
}

/// Highlighted edge and a soft shadow that lifts a panel off the window. The shadow is
/// cut out under the panel so it does not darken the translucent fill.
struct PanelChrome<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .overlay {
                if AppSettings.shared.isSolid(reduceTransparency: reduceTransparency) {
                    shape.strokeBorder(Theme.paneLine, lineWidth: 1)
                } else {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [Theme.glassEdge, Theme.glassEdgeFade],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
                }
            }
            .background {
                // No shadow while the window is in the background.
                if activeState != .inactive {
                    shape.fill(Theme.panelShadow).shadow(color: Theme.panelShadow, radius: 9, y: 3)
                        .mask {
                            Rectangle().padding(-40).overlay { shape.fill(.black).blendMode(.destinationOut) }
                                .compositingGroup()
                        }
                }
            }
    }
}

extension View {
    /// The app's base text size and plain button look, for a window, sheet or popover root.
    func appTypography() -> some View {
        font(Theme.Fonts.body).buttonStyle(.neutral)
    }

    func panelChrome<S: InsettableShape>(_ shape: S) -> some View { modifier(PanelChrome(shape: shape)) }

    func panelFill<S: Shape>(_ level: PanelFill<S>.Level, in shape: S) -> some View {
        modifier(PanelFill(level: level, shape: shape))
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(Theme.Fonts.bodyMedium)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: Theme.Control.chipHeight)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Fonts.secondaryMedium)
            .padding(.horizontal, 12).frame(minHeight: Theme.Control.smallChipHeight)
            .background(Capsule().fill(.quaternary))
    }
}

struct Banner: View {
    enum Kind { case info, caution, error }
    let kind: Kind
    let text: String
    var lineLimit: Int?

    private var color: Color {
        switch kind {
        case .info: Theme.accent
        case .caution: Theme.caution
        case .error: Theme.bad
        }
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(Theme.Fonts.body).lineLimit(lineLimit).help(lineLimit == nil ? "" : text)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(color.opacity(0.10)))
    }
}

/// Segmented control drawn as pills.
struct PillPicker<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value
    /// A white selected pill instead of the accent fill, for toolbars.
    var quiet = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(Theme.Fonts.bodyMedium)
                        .foregroundStyle(selected && !quiet ? Theme.onAccent : .primary)
                        .padding(.horizontal, quiet ? 14 : 16).frame(height: Theme.Control.height - 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selected, quiet {
                                Capsule().fill(Color(nsColor: .windowBackgroundColor))
                                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
                            } else {
                                Capsule().fill(selected ? Theme.accent : .clear)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary))
    }
}

struct BusyLine: View {
    let text: String?

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            }
        }
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accentFilled: AccentButtonStyle { AccentButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var neutral: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// The default look for a plain button: a neutral capsule at the standard control height.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let tint = configuration.role == .destructive ? Theme.bad : Color.primary
        let fill = configuration.isPressed ? 0.18 : hovering ? 0.12 : 0.08
        return configuration.label
            .font(Theme.Fonts.button)
            .foregroundStyle(configuration.role == .destructive ? Theme.bad : .primary)
            .padding(.horizontal, 18)
            .frame(minHeight: Theme.Control.height)
            .background(Capsule().fill(tint.opacity(fill)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

extension ButtonStyle where Self == CircleToolbarButtonStyle {
    static var circleToolbar: CircleToolbarButtonStyle { CircleToolbarButtonStyle() }
}

struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.button)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 20)
            .frame(minHeight: Theme.Control.height)
            .background(
                Capsule().fill(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35))
            )
    }
}

/// A low-key capsule button. A destructive role turns the text red, whatever the container is.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let tint = configuration.role == .destructive ? Theme.bad : Color.primary
        let fill = configuration.isPressed ? 0.18 : hovering ? 0.12 : 0.07
        return configuration.label
            .font(Theme.Fonts.bodyMedium)
            .foregroundStyle(configuration.role == .destructive ? Theme.bad : .primary)
            .padding(.horizontal, 16)
            .frame(minHeight: Theme.Control.height)
            .background(Capsule().fill(tint.opacity(fill)))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct CircleToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let fill = configuration.isPressed ? 0.14 : hovering ? 0.10 : 0.06
        return configuration.label
            .labelStyle(.iconOnly)
            .font(Theme.Fonts.bodyMedium)
            .foregroundStyle(.primary)
            .frame(width: Theme.Control.circle, height: Theme.Control.circle)
            .background(Circle().fill(Color.primary.opacity(fill)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// The toolbar refresh button. Shows a spinner while it works, without looking disabled.
struct RefreshButton: View {
    let busy: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
        }
        .buttonStyle(.circleToolbar)
        .allowsHitTesting(!busy)
        .help(help)
        .accessibilityLabel(busy ? "Refreshing" : "Refresh")
    }
}

enum Format {
    static func ago(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(seconds / 60) min ago"
        case ..<86400: "\(seconds / 3600) hr ago"
        default: "\(seconds / 86400) d ago"
        }
    }

    static func interval(_ seconds: Int) -> String {
        switch seconds {
        case ..<120: "\(seconds) seconds"
        case ..<7200: "\(seconds / 60) minutes"
        default: "\(seconds / 3600) hours"
        }
    }
}

struct Hint<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(Theme.Fonts.secondary)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
