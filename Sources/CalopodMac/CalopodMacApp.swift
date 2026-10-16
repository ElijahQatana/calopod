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
        .defaultSize(width: 980, height: 660)
        .commands {
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
