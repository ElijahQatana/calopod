import CalopodCommands
import AppKit
import SwiftUI

struct ServiceScreen: View {
    let model: ServiceModel

    private static let intervals: [(label: String, seconds: Int)] = [
        ("5 minutes", 300), ("10 minutes", 600), ("15 minutes", 900),
        ("30 minutes", 1800), ("1 hour", 3600),
    ]

    var body: some View {
        CardPage(title: "Background sync") {
            if let busy = model.busyAction { BusyLine(text: busy) }
            if let notice = model.notice { Banner(kind: .error, text: notice, onDismiss: model.dismissNotice) }
            serviceSection
            if let status = model.status, status.installed { scheduleSection(status) }
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .onDisappear { model.dismissNotice() }
    }

    // MARK: Service

    @ViewBuilder
    private var serviceSection: some View {
        switch model.registration {
        case .unavailable:
            CardSection(
                "Service",
                footnote: "Syncing moves into the app once Calopod runs as an installed app, not from a build folder."
            ) {
                if model.status?.installed == true {
                    CardRow("Installed from", value: "Source install")
                    CardRow("Automatic sync") {
                        Toggle(
                            "Automatic sync",
                            isOn: Binding(
                                get: { model.status?.enabled ?? false },
                                set: { value in Task { await model.setEnabled(value) } }
                            )
                        )
                        .labelsHidden().toggleStyle(.switch)
                        .disabled(model.isBusy)
                    }
                } else {
                    CardRow("Status", value: "Not installed")
                }
            }
        case .notRegistered, .notFound:
            CardSection(
                "Service",
                footnote: model.legacyServiceActive
                    ? "The app's own service replaces the source-installed one. Your settings and local data are kept."
                    : "Syncing runs quietly in the background and starts when you sign in."
            ) {
                CardRow("Status", value: model.legacyServiceActive ? "Source install" : "Not installed")
                CardRow {
                    Button(model.legacyServiceActive ? "Move to the app" : "Install") {
                        Task { await model.installBundledService() }
                    }
                    .disabled(model.isBusy)
                }
                if model.registration == .notFound {
                    CardRow {
                        Banner(
                            kind: .caution,
                            text:
                                Permissions.noRecordOfThisCopy + " You can still try installing. Your current service keeps running."
                        )
                    }
                }
            }
        case .requiresApproval:
            CardSection(
                "Service",
                footnote: model.legacyServiceActive
                    ? "Allow Calopod in System Settings, General, Login Items, then choose Move to the app again. Your current service keeps running until then."
                    : "Allow Calopod in System Settings, General, Login Items."
            ) {
                CardRow("Status", value: "Waiting for approval")
                CardRow { Button("Open Login Items Settings") { model.openLoginItemsSettings() } }
            }
        case .enabled:
            CardSection("Service", footnote: "Registered with macOS and starts when you sign in.") {
                CardRow("Status", value: "Installed")
                if model.legacyServiceActive {
                    CardRow {
                        Banner(kind: .info, text: "The source-installed service is still running. Finish moving to stop it so only the app's service syncs.")
                    }
                    CardRow {
                        Button("Finish moving") { Task { await model.installBundledService() } }
                            .disabled(model.isBusy)
                    }
                }
                CardRow {
                    Button("Remove", role: .destructive) { Task { await model.removeBundledService() } }
                        .buttonStyle(.quiet)
                        .disabled(model.isBusy)
                }
            }
        }
    }

    // MARK: Schedule

    private func scheduleSection(_ status: AgentControlStatus) -> some View {
        CardSection(
            "Schedule", footnote: "Pausing stops the schedule only. You can still sync by hand from Overview."
        ) {
            CardRow("Sync every") {
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
                .labelsHidden()
                .fixedSize()
                .disabled(model.isBusy)
            }
            CardRow("Pause scheduled syncs") {
                Toggle(
                    "Pause scheduled syncs",
                    isOn: Binding(
                        get: { status.paused },
                        set: { value in Task { await model.setPaused(value) } }
                    )
                )
                .labelsHidden().toggleStyle(.switch)
                .disabled(model.isBusy || !status.enabled)
            }
        }
    }
}
