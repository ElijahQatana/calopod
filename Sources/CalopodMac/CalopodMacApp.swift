import AppKit
import SwiftUI

@main
struct CalopodMacApp: App {
    @State private var model = ServiceModel()

    init() {
        // A menu bar app: no Dock icon even when launched as a bare executable.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}
