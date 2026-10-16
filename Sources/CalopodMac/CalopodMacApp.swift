import AppKit
import SwiftUI

@main
struct CalopodMacApp: App {
    @State private var service = ServiceModel()
    @State private var setup = SetupModel()
    @State private var conflicts = ConflictModel()
    @State private var navigation = AppNavigation()

    init() {
        // No Dock icon, even as a bare executable.
        NSApplication.shared.setActivationPolicy(.accessory)
        AppConfiguration.apply()
    }

    var body: some Scene {
        // Opens at launch and on reopen, so launching is visible.
        Window("Calopod", id: "home") {
            MainWindow(navigation: navigation, service: service, setup: setup, conflicts: conflicts)
                .task { await conflicts.reload() }
        }
        .defaultSize(width: 980, height: 660)

        MenuBarExtra {
            MenuPopover(model: service, navigation: navigation)
        } label: {
            Image(nsImage: SquidMark.menuBarImage(alert: service.menuBarAlert))
                .opacity(service.menuBarDimmed ? 0.5 : 1)
        }
        .menuBarExtraStyle(.window)
    }
}
