import AppKit
import OSLog
import SwiftUI

private let windowLog = Logger(subsystem: "pro.elijahquintana.calopod", category: "window")

extension NSVisualEffectView {
    /// Blurs the desktop behind the window, like the system sidebars do.
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

/// Window background for the window style. For Glass and Frosted the blur view is the
/// window's content view, so nothing here paints the window except the frame tint.
struct WindowBackdrop: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if AppSettings.shared.isSolid(reduceTransparency: reduceTransparency) {
            content.background { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
        } else if #available(macOS 15, *) {
            content
                .containerBackground(for: .window) { Color.clear }
                .background { Theme.frameTint.ignoresSafeArea() }
        } else {
            content.background { Theme.frameTint.ignoresSafeArea() }
        }
    }
}

/// Finds the window and puts the blur view in as its content view, with the SwiftUI view inside.
struct WindowBlurHelper: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HelperView() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class HelperView: NSView {
        private var installed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !installed else { return }
            installed = true
            // Wait a beat so the window chrome setup has run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let window = self?.window else { return }
                let style = AppSettings.shared.launchWindowStyle
                if style != .solid, !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                    if style == .glass { Self.installGlass(in: window) } else { Self.installWrapper(in: window) }
                }
                windowLog.notice("window style: \(style.rawValue, privacy: .public)")
            }
        }

        private static func makeTransparent(_ hosting: NSView) {
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
            hosting.layer?.isOpaque = false
        }

        /// The blur view is the content view and the SwiftUI view fills it.
        private static func installWrapper(in window: NSWindow) {
            guard let hosting = window.contentView, !(hosting is NSVisualEffectView) else { return }
            let effect = NSVisualEffectView.behindWindow()
            effect.frame = hosting.frame
            window.contentView = effect
            hosting.frame = effect.bounds
            hosting.autoresizingMask = [.width, .height]
            makeTransparent(hosting)
            effect.addSubview(hosting)
            window.isOpaque = false
            window.backgroundColor = .clear
        }

        /// The same with the system glass view, which only exists on macOS 26 and later.
        private static func installGlass(in window: NSWindow) {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                guard let hosting = window.contentView, !(hosting is NSGlassEffectView) else { return }
                let glass = NSGlassEffectView()
                glass.style = .clear
                glass.frame = hosting.frame
                window.contentView = glass
                makeTransparent(hosting)
                glass.contentView = hosting
                window.isOpaque = false
                window.backgroundColor = .clear
                return
            }
            #endif
            installWrapper(in: window)
        }
    }
}
