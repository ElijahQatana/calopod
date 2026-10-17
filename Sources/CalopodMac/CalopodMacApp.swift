import AppKit
import SwiftUI

@main
struct CalopodMacApp: App {
    @State private var service = ServiceModel()
    @State private var setup = SetupModel()
    @State private var inbox = InboxModel()
    @State private var schedule = CalendarModel()
    @State private var navigation = AppNavigation()
    @State private var sidebar = SidebarState()

    init() {
        DockPresence.enter()
        AppConfiguration.apply()
        AppSettings.shared.applyAppearance()
    }

    var body: some Scene {
        // Opens at launch and on reopen, so launching is visible.
        Window("Calopod", id: "home") {
            MainWindow(navigation: navigation, sidebar: sidebar, service: service, setup: setup, inbox: inbox)
                .environment(inbox)
                .environment(schedule)
                .task { await inbox.reload() }
                .dockPresence()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1140, height: 700)
        .commands {
            SettingsCommands(navigation: navigation)
            CommandGroup(replacing: .sidebar) {
                Button(sidebar.isCollapsed ? "Show Sidebar" : "Hide Sidebar") { sidebar.toggle() }
                    .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }

        MenuBarExtra {
            MenuPopover(model: service, navigation: navigation, inbox: inbox, schedule: schedule)
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: SquidMark.menuBarImage(alert: service.menuBarAlert))
                if let text = UpNext.menuBarText(waiting: inbox.waiting) {
                    Text(text).monospacedDigit()
                }
            }
            .opacity(service.menuBarDimmed ? 0.5 : 1)
            // Reads the local copy only, so the count stays current with the window closed.
            .task {
                while !Task.isCancelled {
                    await inbox.reload()
                    await schedule.reload()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// The Settings command, with the usual Command-Comma.
struct SettingsCommands: Commands {
    let navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                navigation.selection = .settings
                DockPresence.enter()
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "home")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
