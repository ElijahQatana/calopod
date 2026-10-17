import CalopodCommands
import SwiftUI

struct ServiceScreen: View {
    let model: ServiceModel

    private static let intervals: [(label: String, seconds: Int)] = [
        ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900),
        ("30 minutes", 1800), ("1 hour", 3600),
    ]

    var body: some View {
        Form {
            if let busy = model.busyAction { Section { BusyLine(text: busy) } }
            if let notice = model.notice { Section { Banner(kind: .error, text: notice) } }
            serviceSection
            if let status = model.status, status.installed { scheduleSection(status) }
        }
        .formStyle(.grouped)
    }

    // MARK: Service

    @ViewBuilder
    private var serviceSection: some View {
        switch model.registration {
        case .unavailable:
            Section {
                if model.status?.installed == true {
                    LabeledContent("Installed from", value: "Source install")
                    Toggle(
                        "Automatic sync",
                        isOn: Binding(
                            get: { model.status?.enabled ?? false },
                            set: { value in Task { await model.setEnabled(value) } }
                        )
                    )
                    .disabled(model.isBusy)
                } else {
                    LabeledContent("Status", value: "Not installed")
                }
                Hint { Text("Open the Calopod app (Scripts/build-calopod-mac-app.sh) to move syncing into the app.") }
            } header: {
                Text("Background service")
            }
        case .notRegistered, .notFound:
            Section {
                LabeledContent("Status", value: model.legacyServiceActive ? "Source install" : "Not installed")
                Button(model.legacyServiceActive ? "Move to the app" : "Install") {
                    Task { await model.installBundledService() }
                }
                .disabled(model.isBusy)
                if model.registration == .notFound {
                    Banner(
                        kind: .caution,
                        text:
                            "macOS has no record of this copy of the app. Background services need Calopod installed in the Applications folder and signed with a developer identity, not a debug build run from a build folder. You can still try installing. Your current service keeps running."
                    )
                }
                Hint {
                    Text(
                        model.legacyServiceActive
                            ? "The app's own service replaces the source-installed one. Your settings and local data are kept."
                            : "Syncing runs quietly in the background and starts when you sign in.")
                }
            } header: {
                Text("Background service")
            }
        case .requiresApproval:
            Section {
                LabeledContent("Status", value: "Waiting for approval")
                Button("Open Login Items Settings") { model.openLoginItemsSettings() }
                Hint { Text("Allow Calopod in System Settings, General, Login Items.") }
            } header: {
                Text("Background service")
            }
        case .enabled:
            Section {
                LabeledContent("Status", value: "Installed")
                Button("Remove", role: .destructive) { Task { await model.removeBundledService() } }
                    .buttonStyle(.quiet)
                    .disabled(model.isBusy)
                Hint { Text("Registered with macOS and starts when you sign in.") }
            } header: {
                Text("Background service")
            }
        }
    }

    // MARK: Schedule

    private func scheduleSection(_ status: AgentControlStatus) -> some View {
        Section {
            Picker(
                "Sync every",
                selection: Binding(
                    get: { status.intervalSeconds ?? 600 },
                    set: { value in Task { await model.setInterval(seconds: value) } }
                )
            ) {
                ForEach(Self.intervals, id: \.seconds) { Text($0.label).tag($0.seconds) }
                if let current = status.intervalSeconds,
                    !Self.intervals.contains(where: { $0.seconds == current })
                {
                    Text(Format.interval(current)).tag(current)
                }
            }
            .disabled(model.isBusy)
            Toggle(
                "Pause scheduled syncs",
                isOn: Binding(
                    get: { status.paused },
                    set: { value in Task { await model.setPaused(value) } }
                )
            )
            .disabled(model.isBusy || !status.enabled)
            Hint { Text("Pausing stops the schedule only. You can still sync by hand from Overview.") }
        } header: {
            Text("Schedule")
        }
    }
}
