import CalopodCommands
import SwiftUI

struct OverviewScreen: View {
    let model: ServiceModel
    let navigation: AppNavigation
    let setup: SetupModel
    @Environment(InboxModel.self) private var inbox
    @Environment(CalendarModel.self) private var schedule
    @Environment(CalendarAccessModel.self) private var access

    @State private var progress = FirstRunProgress()
    @State private var showingSetup = false

    var body: some View {
        CardPage(title: "Overview") {
            if let notice = model.notice { Banner(kind: .error, text: notice, onDismiss: model.dismissNotice) }

            if accessState.isMissing {
                CardSection { CardRow { CalendarAccessCard(access: access, state: accessState) } }
            }

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
        .onDisappear { model.dismissNotice() }
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

    private var accessState: CalendarAccessState { model.calendarAccess }

    private func hero(_ status: AgentControlStatus) -> some View {
        let health = model.syncHealth
        return VStack(spacing: 14) {
            Image(systemName: health.symbol)
                .font(Theme.Fonts.glyph)
                .foregroundStyle(health.color)
                .frame(width: 76, height: 76)
                .background(Circle().fill(health.color.opacity(0.14)))
            VStack(spacing: 4) {
                Text(health.headline).font(Theme.Fonts.heading)
                Text(health.detail).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            }
            if let busy = model.busyAction { BusyLine(text: busy) }
            HStack(spacing: 10) {
                Button("Preview sync") { Task { await model.previewSync() } }
                    .buttonStyle(.accentFilled)
                    .disabled(model.isBusy || model.pendingPreview != nil || accessState.isMissing)
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

    // MARK: Preview

    private func previewSection(_ preview: SyncPreview) -> some View {
        SyncReviewSection(model: model, preview: preview)
    }

    // MARK: Needs you and next up

    @ViewBuilder
    private var needsYou: some View {
        if let board = inbox.board {
            CardSection("Needs you") {
                if !board.isComplete {
                    CardRow {
                        VStack(alignment: .leading, spacing: 8) {
                            Banner(kind: .caution, text: board.staleText(suffix: "so this may be missing items."))
                            Button("Refresh calendars") { Task { await inbox.refresh() } }
                                .disabled(inbox.isBusy)
                        }
                    }
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
        let checks = model.attentionChecks
        if let health = model.health, health.status != "ok", !checks.isEmpty {
            CardSection(
                "Needs attention", footnote: health.warnings.isEmpty ? nil : health.warnings.joined(separator: " ")
            ) {
                ForEach(checks) { check in
                    CardRow {
                        HStack(spacing: 12) {
                            Label(
                                check.name.replacingOccurrences(of: "-", with: " ").capitalized,
                                systemImage: check.state == "failed" ? "xmark.circle.fill" : "clock.fill"
                            )
                            .foregroundStyle(check.state == "failed" ? Theme.badText : Theme.cautionText, .primary)
                            Spacer(minLength: 12)
                            Text(attentionDetail(check, status))
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

    private func attentionDetail(_ check: HealthReport.Check, _ status: AgentControlStatus) -> String {
        let reason = (check.reason ?? check.state).replacingOccurrences(of: "-", with: " ")
        guard check.name == "automatic-run", let age = status.failureAgeSeconds else { return reason }
        return "\(reason), \(Format.ago(age))"
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
