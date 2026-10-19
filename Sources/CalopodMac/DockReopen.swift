import AppKit
import SwiftUI

/// What a Dock click should do, given the state of the main window.
enum DockReopen {
    enum Action: Equatable {
        case open
        case restore
        case raise
    }

    static func action(windowExists: Bool, isMinimized: Bool, isVisible: Bool) -> Action {
        guard windowExists else { return .open }
        if isMinimized { return .restore }
        return isVisible ? .raise : .open
    }
}

/// The one way the main window is shown, used by the menu bar rows and the Dock click.
@MainActor
final class MainWindowOpener {
    static let shared = MainWindowOpener()
    /// Set by a live view that has the SwiftUI open-window action.
    var openHome: (() -> Void)?

    func show(open: () -> Void) {
        DockPresence.enter()
        NSApplication.shared.activate(ignoringOtherApps: true)
        open()
    }

    var mainWindow: NSWindow? {
        NSApplication.shared.windows.first { $0.title == "Calopod" && !($0 is NSPanel) }
    }

    /// Shows the main window, opening or restoring it when needed.
    func bringForward() { _ = handleDockClick() }

    /// Returns false when the click was handled here, so macOS does not open a window too.
    func handleDockClick() -> Bool {
        let window = mainWindow
        let action = DockReopen.action(
            windowExists: window != nil,
            isMinimized: window?.isMiniaturized ?? false,
            isVisible: window?.isVisible ?? false)
        switch action {
        case .open:
            guard let openHome else { return true }
            show(open: openHome)
        case .restore:
            window?.deminiaturize(nil)
            show {}
        case .raise:
            show { window?.makeKeyAndOrderFront(nil) }
        }
        return false
    }
}

final class CalopodAppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        // Set before any scene, so a click on a reminder that launched the app is delivered.
        AppNotifications.install()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowOpener.shared.handleDockClick()
    }
}

private struct RegistersWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { MainWindowOpener.shared.openHome = { openWindow(id: "home") } }
    }
}

extension View {
    /// Lets the app delegate open the main window; place it on a view that outlives the window.
    func registersWindowOpener() -> some View { modifier(RegistersWindowOpener()) }
}
