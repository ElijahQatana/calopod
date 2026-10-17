import AppKit
import Observation

enum AppearanceChoice: String, CaseIterable {
    case system, light, dark

    static func parse(_ raw: String?) -> AppearanceChoice { raw.flatMap(Self.init(rawValue:)) ?? .system }

    /// nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// How the window shows the desktop. Glass needs macOS 26.
enum WindowStyle: String, CaseIterable {
    case glass, frosted, solid

    static var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static var standard: WindowStyle { glassAvailable ? .glass : .frosted }

    static func parse(_ raw: String?) -> WindowStyle {
        guard let style = raw.flatMap(Self.init(rawValue:)) else { return standard }
        return style == .glass && !glassAvailable ? .frosted : style
    }
}

enum GlassLayer { case frame, sidebar, content }

/// Alphas at the default slider positions, light then dark. A scale of 1 gives these exactly.
enum GlassBase {
    static let frame = (light: 0.10, dark: 0.08)
    static let sidebarFill = (light: 0.52, dark: 0.52)
    static let sidebarSheen = (light: 0.58, dark: 0.56)
    static let content = (light: 0.93, dark: 0.91)
    static let inner = (light: 0.97, dark: 0.97)

    /// The content fill never goes below this, so text stays readable.
    static let contentFloor = 0.55
    /// Smallest step kept between the frame, sidebar and content alphas.
    static let gap = 0.03

    static func range(_ layer: GlassLayer) -> ClosedRange<Double> {
        switch layer {
        case .frame: 0 ... 3
        case .sidebar: 0.3 ... 1.6
        case .content: (contentFloor / content.dark) ... 1.05
        }
    }
}

/// The look settings. Views read these through `Theme`, so only the ones that draw a
/// token redraw when a slider moves.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    static let appearanceKey = "calopod.appearance"
    static let windowStyleKey = "calopod.windowStyle"
    static let scaleKeys: [GlassLayer: String] = [
        .frame: "calopod.frameScale", .sidebar: "calopod.sidebarScale", .content: "calopod.contentScale",
    ]

    private(set) var frameScale = 1.0
    private(set) var sidebarScale = 1.0
    private(set) var contentScale = 1.0
    private(set) var appearance: AppearanceChoice
    private(set) var windowStyle: WindowStyle
    /// The style the window was set up with. Changing it applies at the next launch.
    let launchWindowStyle: WindowStyle

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = .parse(defaults.string(forKey: Self.appearanceKey))
        let style = WindowStyle.parse(defaults.string(forKey: Self.windowStyleKey))
        windowStyle = style
        launchWindowStyle = style
        // Later layers are clamped against earlier ones, so a hand-edited value cannot break the order.
        set(.content, Self.stored(defaults, .content))
        set(.sidebar, Self.stored(defaults, .sidebar))
        set(.frame, Self.stored(defaults, .frame))
    }

    private static func stored(_ defaults: UserDefaults, _ layer: GlassLayer) -> Double {
        guard let key = scaleKeys[layer], let number = defaults.object(forKey: key) as? NSNumber,
            number.doubleValue.isFinite
        else { return 1 }
        return number.doubleValue
    }

    func scale(_ layer: GlassLayer) -> Double {
        switch layer {
        case .frame: frameScale
        case .sidebar: sidebarScale
        case .content: contentScale
        }
    }

    // MARK: Alphas

    private func frameAlpha(_ scale: Double, dark: Bool) -> Double { min(1, (dark ? GlassBase.frame.dark : GlassBase.frame.light) * scale) }
    private func sidebarLow(_ scale: Double, dark: Bool) -> Double { min(1, (dark ? GlassBase.sidebarFill.dark : GlassBase.sidebarFill.light) * scale) }
    private func sidebarHigh(_ scale: Double, dark: Bool) -> Double { min(1, (dark ? GlassBase.sidebarSheen.dark : GlassBase.sidebarSheen.light) * scale) }
    private func contentAlpha(_ scale: Double, dark: Bool) -> Double { min(1, (dark ? GlassBase.content.dark : GlassBase.content.light) * scale) }

    // MARK: Changing

    /// Sets a layer's scale, kept inside its range and a small gap away from its neighbors.
    func set(_ layer: GlassLayer, _ requested: Double) {
        let gap = GlassBase.gap
        var value = requested.isFinite ? requested : 1
        var low = GlassBase.range(layer).lowerBound
        var high = GlassBase.range(layer).upperBound
        for dark in [false, true] {
            switch layer {
            case .frame:
                high = min(high, (sidebarLow(sidebarScale, dark: dark) - gap) / (dark ? GlassBase.frame.dark : GlassBase.frame.light))
            case .sidebar:
                high = min(high, (contentAlpha(contentScale, dark: dark) - gap) / (dark ? GlassBase.sidebarSheen.dark : GlassBase.sidebarSheen.light))
                low = max(low, (frameAlpha(frameScale, dark: dark) + gap) / (dark ? GlassBase.sidebarFill.dark : GlassBase.sidebarFill.light))
            case .content:
                low = max(low, (sidebarHigh(sidebarScale, dark: dark) + gap) / (dark ? GlassBase.content.dark : GlassBase.content.light))
            }
        }
        value = min(max(value, low), max(low, high))
        switch layer {
        case .frame: frameScale = value
        case .sidebar: sidebarScale = value
        case .content: contentScale = value
        }
        if let key = Self.scaleKeys[layer] { defaults.set(value, forKey: key) }
    }

    /// Slider position from 0 (firmest) to 1 (most see-through).
    func position(_ layer: GlassLayer) -> Double {
        let range = GlassBase.range(layer)
        return (range.upperBound - scale(layer)) / (range.upperBound - range.lowerBound)
    }

    func setPosition(_ layer: GlassLayer, _ position: Double) {
        let range = GlassBase.range(layer)
        let clamped = min(1, max(0, position))
        set(layer, range.upperBound - clamped * (range.upperBound - range.lowerBound))
    }

    func resetTransparency() {
        // Back to the defaults, content first so the order check never blocks a step.
        for layer in [GlassLayer.content, .sidebar, .frame] { set(layer, 1) }
    }

    func setAppearance(_ choice: AppearanceChoice) {
        appearance = choice
        defaults.set(choice.rawValue, forKey: Self.appearanceKey)
        applyAppearance()
    }

    func applyAppearance() { NSApplication.shared.appearance = appearance.nsAppearance }

    func setWindowStyle(_ style: WindowStyle) {
        windowStyle = WindowStyle.parse(style.rawValue)
        defaults.set(windowStyle.rawValue, forKey: Self.windowStyleKey)
    }

    /// Solid fills when the system asks for less transparency or the style is Solid.
    func isSolid(reduceTransparency: Bool) -> Bool { reduceTransparency || launchWindowStyle == .solid }
}
