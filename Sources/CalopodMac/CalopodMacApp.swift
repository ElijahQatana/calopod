import AppKit
import SwiftUI

@main
struct CalopodMacApp: App {
    @State private var model = ServiceModel()
    @State private var setup = SetupModel()
    @State private var conflicts = ConflictModel()

    init() {
        // A menu bar app: no Dock icon even when launched as a bare executable.
        NSApplication.shared.setActivationPolicy(.accessory)
        AppConfiguration.apply()
    }

    var body: some Scene {
        // A menu bar app shows nothing on launch, which reads as "it didn't open". This window
        // opens at launch and again when the app is opened a second time.
        Window("Calopod", id: "home") {
            StatusView(model: model)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            StatusView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Window("Calopod Setup", id: "setup") {
            SetupView(model: setup)
        }

        Window("Resolve Conflicts", id: "conflicts") {
            ConflictsView(model: conflicts)
        }
    }
}
