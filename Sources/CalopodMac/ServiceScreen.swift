import CalopodCommands
import SwiftUI

/// Install, approve and remove the background service, and set how often it runs.
struct ServiceScreen: View {
    let model: ServiceModel

    private static let intervals: [(label: String, seconds: Int)] = [
        ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900),
        ("30 minutes", 1800), ("1 hour", 3600),
    ]

    var body: some View {
        ScreenScaffold {
            ScreenHeader(
                title: "Background sync",
                subtitle: "Calopod keeps your calendars current even when this window is closed."
            )
            BusyLine(text: model.busyAction)
            if let notice = model.notice { Banner(kind: .error, text: notice) }
            serviceCard
            if let status = model.status, status.installed { scheduleCard(status) }
        }
    }

    // MARK: Service

    @ViewBuilder
    private var serviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                switch model.registration {
                case .unavailable:
                    SectionLabel("Service")
                    if model.status?.installed == true {
                        Text("Running from the source-installed service.").font(.title3.weight(.medium))
                        Text("Open the Calopod app (build it with Scripts/build-calopod-mac-app.sh) to move it into the app.")
                            .font(.callout).foregroundStyle(.secondary)
                        legacyToggle
                    } else {
                        Text("Not installed").font(.title3.weight(.medium))
                        Text("Open the Calopod app to install the background service.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                case .notRegistered, .notFound:
                    SectionLabel("Service")
                    Text(model.legacyServiceActive ? "Move to the app's service" : "Install the background service")
                        .font(.title3.weight(.medium))
                    Text(model.legacyServiceActive
                        ? "Syncing currently runs from the source-installed service. The app's own service replaces it. Your settings and local data are kept."
                        : "Syncing runs quietly in the background and starts when you sign in.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(model.legacyServiceActive ? "Move to the app" : "Install") {
                        Task { await model.installBundledService() }
                    }
                    .buttonStyle(.accentFilled)
                    .disabled(model.isBusy || model.registration == .notFound)
                    if model.registration == .notFound {
                        Banner(kind: .caution, text: "macOS can't find the background service in this build, so it can't be installed from here yet. Your current service keeps running.")
                    }
                case .requiresApproval:
                    SectionLabel("Service")
                    Text("One more step").font(.title3.weight(.medium))
                    Text("Allow Calopod in System Settings, General, Login Items.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Login Items") { model.openLoginItemsSettings() }
                        .buttonStyle(.accentFilled)
                case .enabled:
                    SectionLabel("Service")
                    HStack {
                        StatusPill(text: "Installed", color: Theme.good)
                        Spacer()
                        Button("Remove", role: .destructive) { Task { await model.removeBundledService() } }
                            .disabled(model.isBusy)
                    }
                    Text("Calopod's background service is registered with macOS and starts at login.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var legacyToggle: some View {
        Toggle("Automatic sync", isOn: Binding(
            get: { model.status?.enabled ?? false },
            set: { value in Task { await model.setEnabled(value) } }
        ))
        .disabled(model.isBusy)
    }

    // MARK: Schedule

    private func scheduleCard(_ status: AgentControlStatus) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Schedule")
                Picker("Sync every", selection: Binding(
                    get: { status.intervalSeconds ?? 600 },
                    set: { value in Task { await model.setInterval(seconds: value) } }
                )) {
                    ForEach(Self.intervals, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    if let current = status.intervalSeconds,
                       !Self.intervals.contains(where: { $0.seconds == current }) {
                        Text(Format.interval(current)).tag(current)
                    }
                }
                .disabled(model.isBusy)
                Divider()
                Toggle("Pause scheduled syncs", isOn: Binding(
                    get: { status.paused },
                    set: { value in Task { await model.setPaused(value) } }
                ))
                .disabled(model.isBusy || !status.enabled)
                Text("Pausing stops the schedule only. You can still sync by hand from Overview.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
