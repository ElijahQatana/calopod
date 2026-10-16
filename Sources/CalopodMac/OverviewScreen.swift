import CalopodCommands
import SwiftUI

struct OverviewScreen: View {
    let model: ServiceModel
    let navigation: AppNavigation
    let setup: SetupModel
    @Environment(InboxModel.self) private var inbox
    @Environment(CalendarModel.self) private var schedule

    @State private var progress = FirstRunProgress()
    @State private var showingSetup = false

    var body: some View {
        Form {
            if let notice = model.notice { Section { Banner(kind: .error, text: notice) } }

            if progress.canResume && !showingSetup { Section { resumeBanner } }

            if let status = model.status, status.installed {
                Section { hero(status) }
                if let preview = model.pendingPreview { previewSection(preview) }
                needsYou
                nextUp
                attention(status)
                glance
            } else if model.status != nil {
                gettingStarted
            } else {
                Section { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingSetup) {
            FirstRunSheet(progress: progress, setup: setup, service: model, navigation: navigation)
        }
        .task {
            await setup.reload()
            let fresh = model.status.map { !$0.installed } ?? false
            if fresh && progress.shouldOpenAutomatically && (setup.snapshot?.connections.isEmpty ?? true) {
                showingSetup = true
            }
        }
    }

    // MARK: Hero

    private func hero(_ status: AgentControlStatus) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol(status))
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(color(status))
                .frame(width: 76, height: 76)
                .background(Circle().fill(color(status).opacity(0.14)))
            VStack(spacing: 4) {
                Text(headline(status)).font(Theme.title())
                Text(detail(status)).font(.callout).foregroundStyle(.secondary)
            }
            if let busy = model.busyAction { BusyLine(text: busy) }
            HStack(spacing: 10) {
                Button("Preview sync") { Task { await model.previewSync() } }
                    .buttonStyle(.accentFilled)
                    .disabled(model.isBusy || model.pendingPreview != nil)
                if status.enabled {
                    Button(status.paused ? "Resume" : "Pause") {
                        Task { await model.setPaused(!status.paused) }
                    }
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func symbol(_ status: AgentControlStatus) -> String {
        switch status.state {
        case "ok": "checkmark"
        case "paused": "pause.fill"
        case "disabled": "power"
        default: "exclamationmark"
        }
    }

    private func color(_ status: AgentControlStatus) -> Color {
        switch status.state {
        case "ok": Theme.good
        case "paused", "disabled": Theme.caution
        default: Theme.bad
        }
    }

    private func headline(_ status: AgentControlStatus) -> String {
        if let summary = model.lastRunSummary { return summary }
        return switch status.state {
        case "ok": "Everything is in sync"
        case "paused": "Scheduled syncs are paused"
        case "disabled": "Automatic sync is off"
        case "failed": "The last sync didn't finish"
        default: "Automatic sync is stopped"
        }
    }

    private func detail(_ status: AgentControlStatus) -> String {
        var parts: [String] = []
        if let age = status.lastSuccessAgeSeconds { parts.append("Last synced \(Format.ago(age))") }
        if let interval = status.intervalSeconds { parts.append("every \(Format.interval(interval))") }
        return parts.isEmpty ? status.message : parts.joined(separator: " · ")
    }

    // MARK: Preview

    private func previewSection(_ preview: SyncPreview) -> some View {
        Section {
            ForEach(preview.lines.prefix(8)) { line in
                LabeledContent {
                    Text(line.reason).foregroundStyle(.secondary)
                } label: {
                    Text("\(line.action.capitalized) · \(line.armName)")
                }
            }
            if preview.lines.count > 8 {
                Text("and \(preview.lines.count - 8) more").foregroundStyle(.secondary)
            }
            if preview.removals > 0 {
                Banner(kind: .caution, text: "Includes removing copies Calopod made earlier.")
            }
            ForEach(preview.warnings, id: \.self) { Banner(kind: .caution, text: $0) }
            HStack {
                Button("Cancel") { model.discardPreview() }
                Spacer()
                Button("Apply") { Task { await model.applyPreview() } }
                    .buttonStyle(.accentFilled)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(model.isBusy)
        } header: {
            Text("Review before syncing: \(Self.summaryLine(preview))")
        }
    }

    private static func summaryLine(_ preview: SyncPreview) -> String {
        [
            ("to create", preview.creates), ("to update", preview.updates),
            ("to remove", preview.removals), ("to repair", preview.repairs),
        ]
        .filter { $0.1 > 0 }
        .map { "\($0.1) \($0.0)" }
        .joined(separator: ", ")
    }

    // MARK: Needs you and next up

    @ViewBuilder
    private var needsYou: some View {
        if let board = inbox.board {
            Section("Needs you") {
                if !board.isComplete {
                    Banner(kind: .caution, text: "Some calendars are out of date, so this may be missing items.")
                }
                let rows: [(String, Int, InboxFilter, Bool)] = [
                    ("Invitations waiting", inbox.waiting, .needsRSVP, true),
                    ("Overlapping events", inbox.overlaps, .conflicts, false),
                    ("Changed since you last looked", inbox.changes, .changed, false),
                ]
                ForEach(rows.filter { $0.1 > 0 }, id: \.2) { title, count, filter, highlight in
                    Button { navigation.openInbox(filter) } label: {
                        LabeledContent {
                            HStack(spacing: 6) {
                                Text("\(count)").monospacedDigit().fontWeight(.medium)
                                    .foregroundStyle(highlight ? Theme.accent : .primary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        } label: { Text(title) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if rows.allSatisfy({ $0.1 == 0 }) {
                    Label("Nothing needs an answer", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var nextUp: some View {
        if schedule.schedule != nil {
            let events = UpNext.today(in: schedule.schedule, now: Date())
            let stale = UpNext.staleCalendars(in: schedule.schedule)
            Section("Next up today") {
                if !stale.isEmpty {
                    Banner(kind: .caution, text: "\(stale.joined(separator: ", ")) is out of date, so events may be missing.")
                }
                ForEach(events.prefix(4)) { event in
                    Button { navigation.selection = .calendar } label: {
                        LabeledContent {
                            Text(event.startsAt.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        } label: {
                            Label {
                                Text(event.title).lineLimit(1)
                            } icon: {
                                Circle().fill(CalendarColors.shared.color(for: event.calendarID).color).frame(width: 10, height: 10)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if events.count > 4 { Text("and \(events.count - 4) more").foregroundStyle(.secondary) }
                if events.isEmpty { Text("Nothing else today").foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: Attention

    @ViewBuilder
    private func attention(_ status: AgentControlStatus) -> some View {
        if let health = model.health, health.status != "ok" {
            Section {
                ForEach(health.checks.filter { $0.state != "ok" }) { check in
                    LabeledContent {
                        Text((check.reason ?? check.state).replacingOccurrences(of: "-", with: " "))
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(
                            check.name.replacingOccurrences(of: "-", with: " ").capitalized,
                            systemImage: check.state == "failed" ? "xmark.circle.fill" : "clock.fill"
                        )
                        .foregroundStyle(check.state == "failed" ? Theme.bad : Theme.caution, .primary)
                    }
                }
                if !status.running && status.enabled && model.registration != .enabled {
                    Button("Start service") { Task { await model.setEnabled(true) } }
                        .disabled(model.isBusy)
                }
                if status.paused {
                    Button("Resume syncing") { Task { await model.setPaused(false) } }
                        .disabled(model.isBusy)
                }
                Hint { if !health.warnings.isEmpty { Text(health.warnings.joined(separator: " ")) } }
            } header: {
                Text("Needs attention")
            }
        }
    }

    // MARK: At a glance

    private var glance: some View {
        Section("At a glance") {
            glanceRow("Connected accounts", "\(model.overview?.connections.count ?? 0)", .calendars)
            glanceRow(
                "Calendars in use",
                "\(model.overview?.connections.reduce(0) { $0 + $1.selectedCalendarCount } ?? 0)",
                .calendars
            )
            glanceRow("Active arms", "\(model.overview?.arms.filter(\.isEnabled).count ?? 0)", .arms)
        }
    }

    private func glanceRow(_ title: String, _ value: String, _ screen: Screen, filter: InboxFilter? = nil) -> some View {
        Button {
            if let filter { navigation.openInbox(filter) } else { navigation.selection = screen }
        } label: {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Text(value).monospacedDigit()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: First run

    private var gettingStarted: some View {
        Section {
            VStack(spacing: 14) {
                Image(systemName: "calendar.badge.plus").font(.system(size: 34, weight: .medium)).foregroundStyle(Theme.accent)
                Text(progress.isFinished ? "Setup is done" : "Welcome to Calopod").font(Theme.title())
                Text(
                    progress.isFinished
                        ? "Turn on background sync when you are ready."
                        : "Connect your calendars, pick where events go, and review the first sync. It takes a few minutes and nothing is copied until you approve."
                )
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if progress.isFinished {
                    Button("Open background sync") { navigation.selection = .service }.buttonStyle(.accentFilled)
                } else {
                    Button(progress.canResume ? "Resume setup" : "Set up Calopod") { showingSetup = true }
                        .buttonStyle(.accentFilled)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private var resumeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Setup isn't finished").font(.headline)
                Text("Step \(progress.step.rawValue + 1) of 3: \(progress.step.title)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") { showingSetup = true }.buttonStyle(.accentFilled)
        }
    }
}
