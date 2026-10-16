import AppKit
import OSLog
import SwiftUI

/// How the window gets its behind-window blur. Read once at launch from UserDefaults so each
/// way can be tried without a rebuild, then relaunch. Examples:
///   defaults write pro.elijahquintana.calopod CalopodWindowBlur -string background
///   defaults write pro.elijahquintana.calopod CalopodWindowMaterial -string hudWindow
///   defaults write pro.elijahquintana.calopod CalopodWindowAppearance -string darkAqua
///   defaults write pro.elijahquintana.calopod CalopodWindowBlurAlpha -float 0.6
/// and `defaults delete pro.elijahquintana.calopod <key>` to reset one.
enum WindowBlurStrategy: String, CaseIterable {
    /// The blur view is the window's content view, with the SwiftUI view inside it.
    case wrapper
    /// A SwiftUI background behind everything.
    case background
    /// A SwiftUI window container background (macOS 15 and later, else `background`).
    case container
    /// No blur, only the tints.
    case off
    /// Like wrapper, with the system glass view (macOS 26 and later, else wrapper).
    case glass

    static let key = "CalopodWindowBlur"

    static func parse(_ raw: String?) -> WindowBlurStrategy {
        guard let raw else { return .wrapper }
        return WindowBlurStrategy(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) ?? .wrapper
    }

    static var current: WindowBlurStrategy { parse(UserDefaults.standard.string(forKey: key)) }

    /// What actually runs, since `container` needs a newer system.
    var effective: WindowBlurStrategy {
        if self == .container, #unavailable(macOS 15) { return .background }
        if self == .glass, #unavailable(macOS 26) { return .wrapper }
        return self
    }
}

/// Look of the blur view itself, for finding what shows the wallpaper best.
enum WindowTuning {
    static let materialKey = "CalopodWindowMaterial"
    static let appearanceKey = "CalopodWindowAppearance"
    static let alphaKey = "CalopodWindowBlurAlpha"

    static let materials: [String: NSVisualEffectView.Material] = [
        "sidebar": .sidebar, "underwindowbackground": .underWindowBackground, "hudwindow": .hudWindow,
        "popover": .popover, "menu": .menu, "headerview": .headerView, "fullscreenui": .fullScreenUI,
        "contentbackground": .contentBackground, "windowbackground": .windowBackground,
        "sheet": .sheet, "titlebar": .titlebar, "tooltip": .toolTip,
    ]

    static func material(_ raw: String?) -> NSVisualEffectView.Material {
        raw.flatMap { materials[$0.trimmingCharacters(in: .whitespaces).lowercased()] } ?? Theme.windowMaterial
    }

    /// nil follows the system.
    static func appearance(_ raw: String?) -> NSAppearance? {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "aqua": NSAppearance(named: .aqua)
        case "darkaqua": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    /// Accepts a number or a numeric string; anything else is 1. Clamped to 0.2 through 1.
    static func alpha(_ raw: Any?) -> Double {
        let value: Double?
        switch raw {
        case let number as NSNumber: value = number.doubleValue
        case let text as String: value = Double(text.trimmingCharacters(in: .whitespaces))
        default: value = nil
        }
        guard let value, value.isFinite else { return 1 }
        return min(1, max(0.2, value))
    }
}

enum WindowDiagnostics {
    private static let logger = Logger(subsystem: "pro.elijahquintana.calopod", category: "window")

    static func line(
        event: String, strategy: WindowBlurStrategy, isOpaque: Bool, background: String,
        contentView: String, effect: String, isMain: Bool, reduceTransparency: Bool
    ) -> String {
        "\(event): strategy=\(strategy.rawValue) isOpaque=\(isOpaque) backgroundColor=\(background) "
            + "contentView=\(contentView) effect=\(effect) isMainWindow=\(isMain) "
            + "reduceTransparency=\(reduceTransparency)"
    }

    @MainActor
    static func log(_ event: String, window: NSWindow, strategy: WindowBlurStrategy) {
        let effect = findEffectView(in: window.contentView)
        let effectText = effect.map {
            "material=\($0.material.rawValue) state=\($0.state.rawValue) blending=\($0.blendingMode.rawValue) "
                + "appearance=\($0.appearance?.name.rawValue ?? "system") alpha=\($0.alphaValue) "
                + "inWindow=\($0.window === window)"
        } ?? "none"
        let text = line(
            event: event, strategy: strategy, isOpaque: window.isOpaque,
            background: window.backgroundColor.map { String(describing: $0) } ?? "nil",
            contentView: window.contentView.map { String(describing: type(of: $0)) } ?? "nil",
            effect: effectText, isMain: window.isMainWindow,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        logger.notice("\(text, privacy: .public)")
        dumpViews(window.contentView, depth: 0)
    }

    static func viewLine(depth: Int, className: String, wantsLayer: Bool, background: String, layerOpaque: String)
        -> String
    {
        "view\(String(repeating: "  ", count: depth)) \(className) wantsLayer=\(wantsLayer) "
            + "layerBackground=\(background) layerOpaque=\(layerOpaque)"
    }

    /// Looks for an opaque fill: each view's layer background and opacity, a few levels down.
    @MainActor
    private static func dumpViews(_ view: NSView?, depth: Int) {
        guard let view, depth <= 3 else { return }
        let layer = view.layer
        let background = layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }.map { String(describing: $0) } ?? "nil"
        let text = viewLine(
            depth: depth, className: String(describing: type(of: view)), wantsLayer: view.wantsLayer,
            background: background, layerOpaque: layer.map { String($0.isOpaque) } ?? "nil")
        logger.notice("\(text, privacy: .public)")
        for sub in view.subviews.prefix(8) { dumpViews(sub, depth: depth + 1) }
    }

    @MainActor
    private static func findEffectView(in view: NSView?) -> NSVisualEffectView? {
        guard let view else { return nil }
        if let effect = view as? NSVisualEffectView { return effect }
        for sub in view.subviews { if let found = findEffectView(in: sub) { return found } }
        return nil
    }
}

extension NSVisualEffectView {
    @MainActor
    static func behindWindow() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        let defaults = UserDefaults.standard
        view.material = WindowTuning.material(defaults.string(forKey: WindowTuning.materialKey))
        view.appearance = WindowTuning.appearance(defaults.string(forKey: WindowTuning.appearanceKey))
        view.alphaValue = WindowTuning.alpha(defaults.object(forKey: WindowTuning.alphaKey))
        view.isEmphasized = false
        view.state = .followsWindowActiveState
        return view
    }
}

/// Window background for the chosen strategy: the blur (when it is a SwiftUI layer) and the tint.
struct WindowBackdrop: ViewModifier {
    let strategy: WindowBlurStrategy
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let tint = Theme.frameTint
        if reduceTransparency {
            content.background { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
        } else {
            switch strategy.effective {
            case .background:
                content.background {
                    BehindWindowBlur().overlay(tint).ignoresSafeArea()
                }
            case .container:
                if #available(macOS 15, *) {
                    content.containerBackground(for: .window) {
                        ZStack { Rectangle().fill(.ultraThinMaterial); tint }
                    }
                } else {
                    content
                }
            case .wrapper, .glass, .off:
                // Nothing of ours paints the window; the tint goes over what is behind.
                if #available(macOS 15, *) {
                    content
                        .containerBackground(for: .window) { Color.clear }
                        .background { tint.ignoresSafeArea() }
                } else {
                    content.background { tint.ignoresSafeArea() }
                }
            }
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView { .behindWindow() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Finds the window, installs the wrapper blur when asked to, and logs the window setup.
struct WindowBlurHelper: NSViewRepresentable {
    let strategy: WindowBlurStrategy

    func makeNSView(context: Context) -> NSView {
        let view = HelperView()
        view.strategy = strategy
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    final class HelperView: NSView {
        var strategy: WindowBlurStrategy = .wrapper
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observer == nil else { return }
            let strategy = strategy
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { WindowDiagnostics.log("becameKey", window: window, strategy: strategy) }
            }
            // Wait a beat so the window chrome setup has run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak window] in
                guard let window else { return }
                if [.wrapper, .glass].contains(strategy.effective),
                    !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                {
                    if strategy.effective == .glass { Self.installGlass(in: window) } else { Self.installWrapper(in: window) }
                }
                WindowDiagnostics.log("startup", window: window, strategy: strategy)
            }
        }

        /// Same as the wrapper with the system glass view, which only exists on macOS 26 and later.
        private static func installGlass(in window: NSWindow) {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                guard let hosting = window.contentView, !(hosting is NSGlassEffectView) else { return }
                let glass = NSGlassEffectView()
                glass.style = .clear
                glass.frame = hosting.frame
                window.contentView = glass
                hosting.wantsLayer = true
                hosting.layer?.backgroundColor = NSColor.clear.cgColor
                hosting.layer?.isOpaque = false
                glass.contentView = hosting
                window.isOpaque = false
                window.backgroundColor = .clear
                return
            }
            #endif
            installWrapper(in: window)
        }

        /// Makes a blur view the window's content view, with the SwiftUI view inside it.
        private static func installWrapper(in window: NSWindow) {
            guard let hosting = window.contentView, !(hosting is NSVisualEffectView) else { return }
            let frame = hosting.frame
            let effect = NSVisualEffectView.behindWindow()
            effect.frame = frame
            window.contentView = effect
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.layer?.isOpaque = false
            effect.addSubview(hosting)
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
