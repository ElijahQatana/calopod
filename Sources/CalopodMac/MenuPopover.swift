import CalopodCommands
import SwiftUI

struct MenuPopover: View {
    let model: ServiceModel
    let navigation: AppNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if let age = model.status?.lastSuccessAgeSeconds {
                        Text("Last synced \(Format.ago(age))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let busy = model.busyAction { BusyLine(text: busy) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(Theme.bad) }

            if let status = model.status, status.installed {
                HStack(spacing: 8) {
                    Button("Preview sync") { open(.overview); Task { await model.previewSync() } }
                        .buttonStyle(.accentFilled)
                        .disabled(model.isBusy)
                    if status.enabled {
                        Button(status.paused ? "Resume" : "Pause") {
                            Task { await model.setPaused(!status.paused) }
                        }
                        .disabled(model.isBusy)
                    }
                }
            }

            Divider()
            row("Open Calopod", "macwindow", .overview)
            row("Calendars", "calendar", .calendars)
            row("Conflicts", "rectangle.on.rectangle.angled", .conflicts)
            Divider()
            Button("Quit Calopod") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
    }

    private func row(_ title: String, _ symbol: String, _ screen: Screen) -> some View {
        Button { open(screen) } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ screen: Screen) {
        navigation.selection = screen
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "home")
    }

    private var title: String {
        guard let status = model.status else { return "Checking…" }
        guard status.installed else { return "Not set up yet" }
        return switch status.state {
        case "ok": "Syncing"
        case "paused": "Paused"
        case "disabled": "Sync is off"
        case "failed": "Needs attention"
        default: "Stopped"
        }
    }

    private var color: Color {
        switch model.status?.state {
        case "ok": Theme.good
        case "paused", "disabled": Theme.caution
        case "failed", "stopped": Theme.bad
        default: .secondary
        }
    }
}
