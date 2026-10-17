import SwiftUI

/// Appearance, window style and how see-through the panels are.
struct SettingsScreen: View {
    private let settings = AppSettings.shared

    var body: some View { CardPage(title: "Settings") { sections } }

    /// The page contents, for rendering without the scroll view.
    var page: some View { CardPage(title: "Settings") { sections }.page }

    @ViewBuilder
    private var sections: some View {
        appearance
        transparency
        windowStyle
    }

    private var appearance: some View {
        CardSection("Appearance", footnote: "System follows your Mac. The change applies right away.") {
            CardRow {
                PillPicker(
                    options: [("System", AppearanceChoice.system), ("Light", .light), ("Dark", .dark)],
                    selection: Binding(get: { settings.appearance }, set: { settings.setAppearance($0) }))
            }
        }
    }

    private var transparency: some View {
        CardSection(
            "Transparency",
            footnote: "Right is more see-through. Content stays at least 55% filled so text is readable. "
                + "Reduce transparency in macOS overrides these."
        ) {
            CardRow { slider("Frame", .frame) }
            CardRow { slider("Sidebar", .sidebar) }
            CardRow { slider("Content", .content) }
            CardRow {
                Button("Reset to defaults") { settings.resetTransparency() }
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.bodyMedium)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var windowStyle: some View {
        let options: [(String, WindowStyle)] =
            (WindowStyle.glassAvailable ? [("Glass", .glass)] : []) + [("Frosted", .frosted), ("Solid", .solid)]
        return CardSection("Window style", footnote: windowStyleCaption) {
            CardRow {
                PillPicker(
                    options: options,
                    selection: Binding(get: { settings.windowStyle }, set: { settings.setWindowStyle($0) }))
            }
        }
    }

    private var windowStyleCaption: String {
        var text = WindowStyle.glassAvailable
            ? "Glass shows the desktop through the window. Frosted blurs it more. Solid shows none."
            : "Frosted blurs the desktop behind the window. Solid shows none. Glass needs macOS 26 or later."
        if settings.windowStyle != settings.launchWindowStyle { text += " Takes effect next time you open Calopod." }
        return text
    }

    private func slider(_ title: String, _ layer: GlassLayer) -> some View {
        let position = Binding(get: { settings.position(layer) }, set: { settings.setPosition(layer, $0) })
        return HStack(spacing: 12) {
            Text(title).font(Theme.Fonts.bodyMedium).frame(width: 70, alignment: .leading)
            Slider(value: position, in: 0 ... 1)
            Text("\(Int((position.wrappedValue * 100).rounded()))%")
                .font(Theme.Fonts.body.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) transparency")
    }
}
