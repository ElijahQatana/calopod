import SwiftUI

/// Appearance, window style and how see-through the panels are.
struct SettingsScreen: View {
    private let settings = AppSettings.shared

    var body: some View { ScrollView { page } }

    var page: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(Theme.title(.title))
            appearance
            transparency
            windowStyle
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: 640, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private var appearance: some View {
        group("Appearance", caption: "System follows your Mac. The change applies right away.") {
            PillPicker(
                options: [("System", AppearanceChoice.system), ("Light", .light), ("Dark", .dark)],
                selection: Binding(get: { settings.appearance }, set: { settings.setAppearance($0) }))
        }
    }

    private var transparency: some View {
        group(
            "Transparency",
            caption: "Right is more see-through. Content stays at least 55% filled so text is readable. "
                + "Reduce transparency in macOS overrides these."
        ) {
            slider("Frame", .frame)
            slider("Sidebar", .sidebar)
            slider("Content", .content)
            Button("Reset to defaults") { settings.resetTransparency() }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.accent)
        }
    }

    private var windowStyle: some View {
        let options: [(String, WindowStyle)] =
            (WindowStyle.glassAvailable ? [("Glass", .glass)] : []) + [("Frosted", .frosted), ("Solid", .solid)]
        return group("Window style", caption: windowStyleCaption) {
            PillPicker(
                options: options,
                selection: Binding(get: { settings.windowStyle }, set: { settings.setWindowStyle($0) }))
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
            Text(title).font(.callout.weight(.medium)).frame(width: 70, alignment: .leading)
            Slider(value: position, in: 0 ... 1)
            Text("\(Int((position.wrappedValue * 100).rounded()))%")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) transparency")
    }

    private func group<Content: View>(
        _ title: String, caption: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.title(.headline))
            content()
            Text(caption).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelFill(.inner, in: armCardShape)
        .overlay(armCardShape.strokeBorder(Theme.paneLine, lineWidth: 1))
    }
}
