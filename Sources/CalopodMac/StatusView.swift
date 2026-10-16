import CalopodCommands
import SwiftUI

struct StatusView: View {
    let model: ServiceModel
    @Environment(\.openWindow) private var openWindow

    private static let intervals: [(label: String, seconds: Int)] = [
        ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900),
        ("30 minutes", 1800), ("1 hour", 3600),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let status = model.status, status.installed {
                controls(status)
                Divider()
                overview
            }
            Button("Set Up Calendars…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "setup")
            }
            backgroundService
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.red)
            }
            Divider()
            Button("Quit Calopod") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.busyAction ?? model.status?.message ?? "Checking…")
                    .font(.headline)
                if let age = model.status?.lastSuccessAgeSeconds {
                    Text("Last synced \(Self.relative(age)) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let summary = model.lastRunSummary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func controls(_ status: AgentControlStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Sync Now") { Task { await model.syncNow() } }
                .disabled(model.isBusy)
            Toggle("Automatic sync", isOn: Binding(
                get: { status.enabled },
                set: { value in Task { await model.setEnabled(value) } }
            ))
            .disabled(model.isBusy)
            Toggle("Pause scheduled syncs", isOn: Binding(
                get: { status.paused },
                set: { value in Task { await model.setPaused(value) } }
            ))
            .disabled(model.isBusy || !status.enabled)
            Picker("Every", selection: Binding(
                get: { status.intervalSeconds ?? 600 },
                set: { value in Task { await model.setInterval(seconds: value) } }
            )) {
                ForEach(Self.intervals, id: \.seconds) { Text($0.label).tag($0.seconds) }
                if let current = status.intervalSeconds,
                   !Self.intervals.contains(where: { $0.seconds == current }) {
                    Text("\(current) seconds").tag(current)
                }
            }
            .disabled(model.isBusy)
        }
    }

    @ViewBuilder
    private var backgroundService: some View {
        switch model.registration {
        case .unavailable:
            if model.status?.installed != true {
                Text("Open the Calopod app (Scripts/build-calopod-mac-app.sh) to install the background service.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .notRegistered, .notFound:
            VStack(alignment: .leading, spacing: 6) {
                Text(model.legacyServiceActive
                    ? "Automatic sync currently runs from the source-installed service. Installing the app's service replaces it; your settings and local state are kept."
                    : "Install the background service so Calopod syncs automatically.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(model.legacyServiceActive ? "Move to the app's service" : "Install background service") {
                    Task { await model.installBundledService() }
                }
                .disabled(model.isBusy || model.registration == .notFound)
            }
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow Calopod in System Settings > General > Login Items to start automatic sync.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Login Items Settings") { model.openLoginItemsSettings() }
            }
        case .enabled:
            Button("Remove background service") {
                Task { await model.removeBundledService() }
            }
            .disabled(model.isBusy)
        }
    }

    @ViewBuilder
    private var overview: some View {
        if let overview = model.overview {
            VStack(alignment: .leading, spacing: 6) {
                Text("Connections").font(.subheadline.bold())
                if overview.connections.isEmpty {
                    Text("None yet").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(overview.connections) { connection in
                    Text("\(connection.label) · \(connection.selectedCalendarCount) selected")
                        .font(.callout)
                        .foregroundStyle(connection.isEnabled ? .primary : .secondary)
                }
                Text("Arms").font(.subheadline.bold()).padding(.top, 4)
                if overview.arms.isEmpty {
                    Text("None yet").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(overview.arms) { arm in
                    Text("\(arm.name) · \(arm.sourceCount) source\(arm.sourceCount == 1 ? "" : "s")")
                        .font(.callout)
                        .foregroundStyle(arm.isEnabled ? .primary : .secondary)
                }
            }
        }
    }

    private var color: Color {
        switch model.status?.state {
        case "ok": .green
        case "paused", "disabled": .orange
        case "failed", "stopped": .red
        default: .gray
        }
    }

    private static func relative(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds)s"
        case ..<3600: "\(seconds / 60)m"
        case ..<86400: "\(seconds / 3600)h"
        default: "\(seconds / 86400)d"
        }
    }
}
