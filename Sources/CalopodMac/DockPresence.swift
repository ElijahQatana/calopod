import AppKit
import SwiftUI

/// A normal app (Dock, Cmd-Tab, Stage Manager) while the main window is open,
/// and a menu bar app with no Dock icon once it closes. With the menu bar item hidden the
/// Dock icon stays, so there is always a way back to the window.
enum DockPresence {
    static func closedPolicy(menuBarItemShown: Bool) -> NSApplication.ActivationPolicy {
        menuBarItemShown ? .accessory : .regular
    }

    @MainActor static func enter() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    @MainActor static func leave() {
        NSApplication.shared.setActivationPolicy(closedPolicy(menuBarItemShown: AppSettings.shared.showsMenuBarItem))
    }
}

extension View {
    /// Ties the Dock presence to the window this view lives in.
    func dockPresence() -> some View {
        background(DockPresenceObserver())
    }
}

struct DockPresenceObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Tracker() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Tracker: NSView {
        private var closing: NSObjectProtocol?
        /// Tests swap these to count observers without changing the app's activation policy.
        var center: NotificationCenter = .default
        var enter: @MainActor () -> Void = { DockPresence.enter() }
        var leave: @MainActor () -> Void = { DockPresence.leave() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            closing.map(center.removeObserver)
            closing = nil
            guard let window else { return }
            enter()
            let (center, leave) = (center, leave)
            closing = center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    leave()
                    // Done with this window, so the observer is removed instead of left registered.
                    self?.closing.map(center.removeObserver)
                    self?.closing = nil
                }
            }
        }
    }
}
