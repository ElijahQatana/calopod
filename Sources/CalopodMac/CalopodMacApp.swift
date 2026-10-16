import AppKit
import SwiftUI

@main
struct CalopodMacApp: App {
    @State private var service = ServiceModel()
    @State private var setup = SetupModel()
    @State private var inbox = InboxModel()
    @State private var navigation = AppNavigation()
    @State private var sidebar = SidebarState()

    init() {
        // No Dock icon, even as a bare executable.
        NSApplication.shared.setActivationPolicy(.accessory)
        AppConfiguration.apply()
    }

    var body: some Scene {
        // Opens at launch and on reopen, so launching is visible.
        Window("Calopod", id: "home") {
            MainWindow(navigation: navigation, sidebar: sidebar, service: service, setup: setup, inbox: inbox)
                .task {
                    await inbox.reload()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 660)
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button(sidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar") { sidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        MenuBarExtra {
            MenuPopover(model: service, navigation: navigation)
        } label: {
            Image(nsImage: SquidMark.menuBarImage(alert: service.menuBarAlert))
                .opacity(service.menuBarDimmed ? 0.5 : 1)
        }
        .menuBarExtraStyle(.window)
    }
}
