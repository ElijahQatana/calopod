import AppKit
import SwiftUI

/// A normal app (Dock, Cmd-Tab, Stage Manager) while the main window is open,
/// and a menu bar app with no Dock icon once it closes.
enum DockPresence {
    @MainActor static func enter() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    @MainActor static func leave() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

extension View {
    /// Ties the Dock presence to the window this view lives in.
    func dockPresence() -> some View {
        background(DockPresenceObserver())
    }
}

private struct DockPresenceObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Tracker() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Tracker: NSView {
        private var closing: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closing.map(NotificationCenter.default.removeObserver)
            closing = nil
            guard let window else { return }
            DockPresence.enter()
            closing = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { DockPresence.leave() }
            }
        }
    }
}
