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
        CardPage(title: "Overview") {
            if let notice = model.notice { Banner(kind: .error, text: notice) }

            if progress.canResume && !showingSetup { CardSection { CardRow { resumeBanner } } }

            if let status = model.status, status.installed {
                CardSection { CardRow { hero(status) } }
                if let preview = model.pendingPreview { previewSection(preview) }
                needsYou
                nextUp
                attention(status)
                glance
            } else if model.status != nil {
                gettingStarted
            } else {
                CardSection { CardRow { ProgressView().frame(maxWidth: .infinity).padding(40) } }
            }
        }
        .sheet(isPresented: $showingSetup) {
            FirstRunSheet(progress: progress, setup: setup, service: model, navigation: navigation)
                .appTypography()
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
                .font(Theme.Fonts.glyph)
                .foregroundStyle(color(status))
                .frame(width: 76, height: 76)
                .background(Circle().fill(color(status).opacity(0.14)))
            VStack(spacing: 4) {
                Text(headline(status)).font(Theme.Fonts.heading)
                Text(detail(status)).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
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
        CardSection("Review before syncing: \(Self.summaryLine(preview))") {
            ForEach(preview.lines.prefix(8)) { line in
                CardRow("\(line.action.capitalized) · \(line.armName)") {
                    Text(line.reason).foregroundStyle(.secondary)
                }
            }
            if preview.lines.count > 8 {
                CardRow { Text("and \(preview.lines.count - 8) more").foregroundStyle(.secondary) }
            }
            if preview.removals > 0 {
                CardRow { Banner(kind: .caution, text: "Includes removing copies Calopod made earlier.") }
            }
            ForEach(preview.warnings, id: \.self) { warning in
                CardRow { Banner(kind: .caution, text: warning) }
            }
            CardRow {
                HStack {
                    Button("Cancel") { model.discardPreview() }
                    Spacer()
                    Button("Apply") { Task { await model.applyPreview() } }
                        .buttonStyle(.accentFilled)
                        .keyboardShortcut(.defaultAction)
                }
                .disabled(model.isBusy)
            }
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
            CardSection("Needs you") {
                if !board.isComplete {
                    CardRow { Banner(kind: .caution, text: "Some calendars are out of date, so this may be missing items.") }
                }
                let rows: [(String, Int, InboxFilter, Bool)] = [
                    ("Invitations waiting", inbox.waiting, .needsRSVP, true),
                    ("Overlapping events", inbox.overlaps, .conflicts, false),
                    ("Changed since you last looked", inbox.changes, .changed, false),
                ]
                ForEach(rows.filter { $0.1 > 0 }, id: \.2) { title, count, filter, highlight in
                    CardRow {
                        Button { navigation.openInbox(filter) } label: {
                            CardLabeled(title: title) {
                                HStack(spacing: 6) {
                                    Text("\(count)").monospacedDigit().fontWeight(.medium)
                                        .foregroundStyle(highlight ? Theme.accent : .primary)
                                    Image(systemName: "chevron.right").font(Theme.Fonts.secondary).foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if rows.allSatisfy({ $0.1 == 0 }) {
                    CardRow { Label("Nothing needs an answer", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                }
            }
        }
    }

    @ViewBuilder
    private var nextUp: some View {
        if schedule.schedule != nil {
            let events = UpNext.today(in: schedule.schedule, now: Date())
            let stale = UpNext.staleCalendars(in: schedule.schedule, name: { CalendarAliases.shared.name(for: $0.id, real: $0.name) })
            CardSection("Next up today") {
                if !stale.isEmpty {
                    CardRow { Banner(kind: .caution, text: "\(stale.joined(separator: ", ")) is out of date, so events may be missing.") }
                }
                ForEach(events.prefix(4)) { event in
                    CardRow {
                        Button { navigation.selection = .calendar } label: {
                            HStack(spacing: 12) {
                                Label {
                                    Text(event.title).lineLimit(1)
                                } icon: {
                                    Circle().fill(CalendarColors.shared.color(for: event.calendarID).color).frame(width: 10, height: 10)
                                }
                                Spacer(minLength: 12)
                                Text(event.startsAt.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if events.count > 4 { CardRow { Text("and \(events.count - 4) more").foregroundStyle(.secondary) } }
                if events.isEmpty { CardRow { Text("Nothing else today").foregroundStyle(.secondary) } }
            }
        }
    }

    // MARK: Attention

    @ViewBuilder
    private func attention(_ status: AgentControlStatus) -> some View {
        if let health = model.health, health.status != "ok" {
            CardSection(
                "Needs attention", footnote: health.warnings.isEmpty ? nil : health.warnings.joined(separator: " ")
            ) {
                ForEach(health.checks.filter { $0.state != "ok" }) { check in
                    CardRow {
                        HStack(spacing: 12) {
                            Label(
                                check.name.replacingOccurrences(of: "-", with: " ").capitalized,
                                systemImage: check.state == "failed" ? "xmark.circle.fill" : "clock.fill"
                            )
                            .foregroundStyle(check.state == "failed" ? Theme.bad : Theme.caution, .primary)
                            Spacer(minLength: 12)
                            Text((check.reason ?? check.state).replacingOccurrences(of: "-", with: " "))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !status.running && status.enabled && model.registration != .enabled {
                    CardRow {
                        Button("Start service") { Task { await model.setEnabled(true) } }
                            .disabled(model.isBusy)
                    }
                }
                if status.paused {
                    CardRow {
                        Button("Resume syncing") { Task { await model.setPaused(false) } }
                            .disabled(model.isBusy)
                    }
                }
            }
        }
    }

    // MARK: At a glance

    private var glance: some View {
        CardSection("At a glance") {
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
        CardRow {
            Button {
                if let filter { navigation.openInbox(filter) } else { navigation.selection = screen }
            } label: {
                CardLabeled(title: title) {
                    HStack(spacing: 6) {
                        Text(value).monospacedDigit()
                        Image(systemName: "chevron.right").font(Theme.Fonts.secondary).foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: First run

    private var gettingStarted: some View {
        CardSection {
            CardRow { VStack(spacing: 14) {
                Image(systemName: "calendar.badge.plus").font(Theme.Fonts.glyph).foregroundStyle(Theme.accent)
                Text(progress.isFinished ? "Setup is done" : "Welcome to Calopod").font(Theme.Fonts.heading)
                Text(
                    progress.isFinished
                        ? "Turn on background sync when you are ready."
                        : "Connect your calendars, pick where events go, and review the first sync. It takes a few minutes and nothing is copied until you approve."
                )
                .font(Theme.Fonts.secondary).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
    }

    private var resumeBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.clipboard").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Setup isn't finished").font(Theme.Fonts.bodySemibold)
                Text("Step \(progress.step.rawValue + 1) of 3: \(progress.step.title)")
                    .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") { showingSetup = true }.buttonStyle(.accentFilled)
        }
    }
}
