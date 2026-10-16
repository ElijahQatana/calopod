import AppKit
import OSLog
import SwiftUI

/// How the window gets its behind-window blur. Read once from UserDefaults so each way can
/// be tried without a rebuild:
/// `defaults write pro.elijahquintana.calopod CalopodWindowBlur -string background`
enum WindowBlurStrategy: String, CaseIterable {
    /// The blur view is the window's content view, with the SwiftUI view inside it.
    case wrapper
    /// A SwiftUI background behind everything.
    case background
    /// A SwiftUI window container background (macOS 15 and later, else `background`).
    case container
    /// No blur, only the tints.
    case off

    static let key = "CalopodWindowBlur"

    static func parse(_ raw: String?) -> WindowBlurStrategy {
        guard let raw else { return .wrapper }
        return WindowBlurStrategy(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) ?? .wrapper
    }

    static var current: WindowBlurStrategy { parse(UserDefaults.standard.string(forKey: key)) }

    /// What actually runs, since `container` needs a newer system.
    var effective: WindowBlurStrategy {
        if self == .container, #unavailable(macOS 15) { return .background }
        return self
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
                + "inWindow=\($0.window === window)"
        } ?? "none"
        let text = line(
            event: event, strategy: strategy, isOpaque: window.isOpaque,
            background: window.backgroundColor.map { String(describing: $0) } ?? "nil",
            contentView: window.contentView.map { String(describing: type(of: $0)) } ?? "nil",
            effect: effectText, isMain: window.isMainWindow,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        logger.notice("\(text, privacy: .public)")
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
        view.material = Theme.windowMaterial
        view.appearance = nil
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
            case .wrapper, .off:
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
                if strategy.effective == .wrapper,
                    !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                {
                    Self.installWrapper(in: window)
                }
                WindowDiagnostics.log("startup", window: window, strategy: strategy)
            }
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
