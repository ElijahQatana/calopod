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

    static let standard = WindowStyle.frosted

    static func parse(_ raw: String?) -> WindowStyle {
        guard let style = raw.flatMap(Self.init(rawValue:)) else { return standard }
        return style == .glass && !glassAvailable ? .frosted : style
    }
}

enum GlassLayer { case frame, sidebar, content }

/// Alphas at a scale of 1, light then dark. The defaults sit at the slider positions below.
enum GlassBase {
    static let frame = (light: 0.10, dark: 0.08)
    static let sidebarFill = (light: 0.52, dark: 0.52)
    static let sidebarSheen = (light: 0.58, dark: 0.56)
    static let content = (light: 0.93, dark: 0.91)
    static let inner = (light: 0.97, dark: 0.97)

    /// Where the sliders start. Frame and sidebar sit at 100% and 75%. Content starts at
    /// the scale the older 65% position gave on its former 0.604 to 1.05 range.
    static func defaultScale(_ layer: GlassLayer) -> Double {
        switch layer {
        case .frame: 0
        case .sidebar: range(.sidebar).upperBound - 0.75 * (range(.sidebar).upperBound - range(.sidebar).lowerBound)
        case .content: 1.05 - 0.65 * (1.05 - 0.55 / 0.91)
        }
    }

    static func range(_ layer: GlassLayer) -> ClosedRange<Double> {
        switch layer {
        case .frame: 0 ... 3
        case .sidebar: 0.3 ... 1.6
        case .content: 0 ... 1.05
        }
    }
}

/// The look settings. Views read these through `Theme`, so only the ones that draw a
/// token redraw when a slider moves.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings(defaults: AppDefaults.forSingleton)

    static let appearanceKey = "calopod.appearance"
    static let windowStyleKey = "calopod.windowStyle"
    static let menuBarItemKey = "calopod.showMenuBarItem"
    static let scaleKeys: [GlassLayer: String] = [
        .frame: "calopod.frameScale", .sidebar: "calopod.sidebarScale", .content: "calopod.contentScale",
    ]

    private(set) var frameScale = GlassBase.defaultScale(.frame)
    private(set) var sidebarScale = GlassBase.defaultScale(.sidebar)
    private(set) var contentScale = GlassBase.defaultScale(.content)
    private(set) var appearance: AppearanceChoice
    private(set) var windowStyle: WindowStyle
    /// On unless turned off. With it off the Dock icon stays, so the window can always be reopened.
    private(set) var showsMenuBarItem: Bool
    /// The style the window was set up with. Changing it applies at the next launch.
    let launchWindowStyle: WindowStyle

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.standard) {
        self.defaults = defaults
        appearance = .parse(defaults.string(forKey: Self.appearanceKey))
        let style = WindowStyle.parse(defaults.string(forKey: Self.windowStyleKey))
        windowStyle = style
        launchWindowStyle = style
        showsMenuBarItem = defaults.object(forKey: Self.menuBarItemKey) as? Bool ?? true
        // Nothing is saved here, so an untouched default stays a default and can change later.
        for layer in [GlassLayer.frame, .sidebar, .content] { set(layer, Self.stored(defaults, layer), persist: false) }
    }

    private static func stored(_ defaults: UserDefaults, _ layer: GlassLayer) -> Double {
        guard let key = scaleKeys[layer], let number = defaults.object(forKey: key) as? NSNumber,
            number.doubleValue.isFinite
        else { return GlassBase.defaultScale(layer) }
        return number.doubleValue
    }

    func scale(_ layer: GlassLayer) -> Double {
        switch layer {
        case .frame: frameScale
        case .sidebar: sidebarScale
        case .content: contentScale
        }
    }

    // MARK: Changing

    /// Sets a layer's scale, kept inside that layer's own range.
    func set(_ layer: GlassLayer, _ requested: Double, persist: Bool = true) {
        let range = GlassBase.range(layer)
        let value = requested.isFinite ? min(max(requested, range.lowerBound), range.upperBound) : GlassBase.defaultScale(layer)
        switch layer {
        case .frame: frameScale = value
        case .sidebar: sidebarScale = value
        case .content: contentScale = value
        }
        if persist, let key = Self.scaleKeys[layer] { defaults.set(value, forKey: key) }
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
        for layer in [GlassLayer.frame, .sidebar, .content] { set(layer, GlassBase.defaultScale(layer), persist: false) }
        // Back to unset, so later changes to the defaults reach this Mac.
        for key in Self.scaleKeys.values { defaults.removeObject(forKey: key) }
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

    func setShowsMenuBarItem(_ shown: Bool) {
        showsMenuBarItem = shown
        defaults.set(shown, forKey: Self.menuBarItemKey)
    }

    /// Solid fills when the system asks for less transparency or the style is Solid.
    func isSolid(reduceTransparency: Bool) -> Bool { reduceTransparency || launchWindowStyle == .solid }
}
