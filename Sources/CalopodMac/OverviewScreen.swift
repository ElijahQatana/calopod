import CalopodCommands
import SwiftUI

struct OverviewScreen: View {
    let model: ServiceModel
    let navigation: AppNavigation

    var body: some View {
        ScreenScaffold {
            ScreenHeader(title: "Overview", subtitle: subtitle)
            BusyLine(text: model.busyAction)
            if let notice = model.notice { Banner(kind: .error, text: notice) }

            if let status = model.status, status.installed {
                statusCard(status)
                if let preview = model.pendingPreview { previewCard(preview) }
                attention(status)
                tiles
            } else if model.status != nil {
                gettingStarted
            }
        }
    }

    private var subtitle: String {
        guard let status = model.status else { return "Checking your calendars…" }
        guard status.installed else { return "Let's get your calendars in sync." }
        return switch status.state {
        case "ok": "Everything is running smoothly."
        case "paused": "Scheduled syncs are paused."
        case "disabled": "Automatic sync is turned off."
        case "failed": "The last sync didn't finish."
        default: "Automatic sync needs a nudge."
        }
    }

    // MARK: Status

    private func statusCard(_ status: AgentControlStatus) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    StatusPill(text: pillText(status), color: pillColor(status))
                    Spacer()
                    if let age = status.lastSuccessAgeSeconds {
                        Text("Last synced \(Format.ago(age))")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text(model.lastRunSummary ?? status.message)
                    .font(.title3.weight(.medium))
                HStack(spacing: 10) {
                    Button("Preview sync") { Task { await model.previewSync() } }
                        .buttonStyle(.accentFilled)
                        .disabled(model.isBusy || model.pendingPreview != nil)
                    if status.enabled {
                        Button(status.paused ? "Resume" : "Pause") {
                            Task { await model.setPaused(!status.paused) }
                        }
                        .disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private func pillText(_ status: AgentControlStatus) -> String {
        switch status.state {
        case "ok": "Running"
        case "paused": "Paused"
        case "disabled": "Off"
        case "failed": "Needs attention"
        default: "Stopped"
        }
    }

    private func pillColor(_ status: AgentControlStatus) -> Color {
        switch status.state {
        case "ok": Theme.good
        case "paused", "disabled": Theme.caution
        default: Theme.bad
        }
    }

    // MARK: Preview

    private func previewCard(_ preview: SyncPreview) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Review before syncing")
                Text(Self.summaryLine(preview)).font(.title3.weight(.medium))
                if preview.removals > 0 {
                    Banner(kind: .caution, text: "Includes removing copies Calopod made earlier.")
                }
                ForEach(preview.lines.prefix(6)) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(line.action.capitalized)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                        Text("\(line.armName) — \(line.reason)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if preview.lines.count > 6 {
                    Text("and \(preview.lines.count - 6) more").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(preview.warnings, id: \.self) { Banner(kind: .caution, text: $0) }
                HStack(spacing: 10) {
                    Button("Apply") { Task { await model.applyPreview() } }
                        .buttonStyle(.accentFilled)
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel") { model.discardPreview() }
                }
                .disabled(model.isBusy)
            }
        }
    }

    private static func summaryLine(_ preview: SyncPreview) -> String {
        [("to create", preview.creates), ("to update", preview.updates),
         ("to remove", preview.removals), ("to repair", preview.repairs)]
            .filter { $0.1 > 0 }
            .map { "\($0.1) \($0.0)" }
            .joined(separator: " · ")
    }

    // MARK: Attention

    @ViewBuilder
    private func attention(_ status: AgentControlStatus) -> some View {
        if let health = model.health, health.status != "ok" {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Needs attention")
                    ForEach(health.checks.filter { $0.state != "ok" }) { check in
                        HStack {
                            Circle().fill(check.state == "failed" ? Theme.bad : Theme.caution)
                                .frame(width: 8, height: 8)
                            Text(check.name.replacingOccurrences(of: "-", with: " ").capitalized)
                            if let reason = check.reason {
                                Text(reason.replacingOccurrences(of: "-", with: " "))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                    ForEach(health.warnings, id: \.self) {
                        Text($0).font(.callout).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        if !status.running && status.enabled && model.registration != .enabled {
                            Button("Start service") { Task { await model.setEnabled(true) } }
                        }
                        if status.paused {
                            Button("Resume syncing") { Task { await model.setPaused(false) } }
                        }
                    }
                    .disabled(model.isBusy)
                }
            }
        }
    }

    // MARK: Tiles

    private var tiles: some View {
        HStack(spacing: 14) {
            StatTile(
                value: "\(model.overview?.connections.count ?? 0)",
                caption: "Connected accounts"
            )
            StatTile(
                value: "\(model.overview?.connections.reduce(0) { $0 + $1.selectedCalendarCount } ?? 0)",
                caption: "Calendars in use"
            )
            StatTile(
                value: "\(model.overview?.arms.filter(\.isEnabled).count ?? 0)",
                caption: "Active arms"
            )
        }
    }

    // MARK: First run

    private var gettingStarted: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("Welcome to Calopod").font(.title2.weight(.semibold))
                Text("Three steps and your calendars keep each other up to date.")
                    .foregroundStyle(.secondary)
                step(1, "Connect your calendars", "Add this Mac's calendars, Google or Microsoft.", .calendars)
                step(2, "Choose where events go", "Pick a Main calendar and any Arms.", .arms)
                step(3, "Turn on background sync", "Keep everything current automatically.", .service)
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String, _ screen: Screen) -> some View {
        HStack(spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.accent.opacity(0.14)))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") { navigation.selection = screen }
        }
    }
}
