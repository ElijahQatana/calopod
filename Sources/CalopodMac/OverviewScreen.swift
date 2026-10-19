import CalopodCommands
import SwiftUI

struct OverviewScreen: View {
    let model: ServiceModel
    let navigation: AppNavigation
    let setup: SetupModel
    @Environment(InboxModel.self) private var inbox
    @Environment(CalendarModel.self) private var schedule
    @Environment(CalendarAccessModel.self) private var access
    @Environment(OverviewRefresh.self) private var refresh
    @Environment(\.sidebarCollapsed) private var collapsed

    @State private var progress = FirstRunProgress()
    @State private var showingSetup = false

    @State private var openReasons: Set<String> = []

    var body: some View {
        CardPage(title: "Overview", trailing: Date().formatted(.dateTime.weekday(.wide).day().month(.wide)), maxWidth: 1180) {
            if let notice = model.notice { Banner(kind: .error, text: notice, onDismiss: model.dismissNotice) }
            ForEach(refresh.messages) { message in
                Banner(kind: .error, text: message.text, onDismiss: { refresh.dismiss(message.id) })
            }

            if accessState.isMissing {
                CardSection { CardRow { CalendarAccessCard(access: access, state: accessState) } }
            }

            if progress.canResume && !showingSetup { CardSection { CardRow { resumeBanner } } }

            if let status = model.status, status.installed {
                statusCard(status)
                if let preview = model.pendingPreview { previewSection(preview) }
                OverviewColumns(sidebarCollapsed: collapsed) {
                    VStack(alignment: .leading, spacing: 16) {
                        needsYou
                        nextUp
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        attention(status)
                        calendarsCard
                        glance
                    }
                }
            } else if model.status != nil {
                gettingStarted
            } else {
                CardSection { CardRow { ProgressView().frame(maxWidth: .infinity).padding(40) } }
            }
        }
        .onDisappear {
            model.dismissNotice()
            refresh.dismissAll()
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

    // MARK: Status

    private var accessState: CalendarAccessState { model.calendarAccess }

    private func statusCard(_ status: AgentControlStatus) -> some View {
        SyncStatusCard(
            health: model.syncHealth, refreshed: refresh.refreshedText(), marks: model.recentRuns, busy: model.busyAction,
            paused: status.enabled ? status.paused : nil,
            previewRule: model.previewRule,
            pauseDisabled: model.isBusy,
            preview: { Task { await model.previewSync() } },
            togglePause: { Task { await model.setPaused(!status.paused) } },
            enable: { Task { await model.setEnabled(true) } })
    }

    // MARK: Preview

    private func previewSection(_ preview: SyncPreview) -> some View {
        SyncReviewSection(model: model, preview: preview)
    }

    // MARK: Needs you and next up

    @ViewBuilder
    private var needsYou: some View {
        if let board = inbox.board {
            CardSection(
                header: OverviewSectionHeader(title: "Needs you", link: "Open Inbox") { navigation.openInbox(.all) },
                content: {
                    if !board.isComplete {
                        CardRow {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .center, spacing: 12) { staleBanner(board); refreshButton }
                                VStack(alignment: .leading, spacing: 10) { staleBanner(board); refreshButton }
                            }
                        }
                    }
                    let tiles: [(String, Int, InboxFilter, Bool)] = [
                        ("Invitations waiting", inbox.waiting, .needsRSVP, true),
                        ("Overlapping events", inbox.overlaps, .conflicts, false),
                        ("Changed since you last looked", inbox.changes, .changed, false),
                    ]
                    CardRow {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(tiles, id: \.2) { title, count, filter, highlight in
                                    NeedsYouTile(title: title, count: count, highlight: highlight) {
                                        navigation.openInbox(filter)
                                    }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            if tiles.allSatisfy({ $0.1 == 0 }) {
                                Label("Nothing needs an answer", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                })
        }
    }

    private func staleBanner(_ board: InboxBoard) -> some View {
        Banner(kind: .caution, text: board.staleText(suffix: "so this may be missing items."))
    }

    private var refreshButton: some View { RefreshCalendarsButton() }

    private var today: Range<Date> {
        let calendar = Calendar.current, start = calendar.startOfDay(for: Date())
        return start..<(calendar.date(byAdding: .day, value: 1, to: start) ?? start)
    }

    @ViewBuilder
    private var nextUp: some View {
        if let current = schedule.schedule {
            let now = Date()
            let events = UpNext.today(in: current, now: now)
            let stale = UpNext.staleToday(
                in: current, now: now, ignored: { CalendarAliases.shared.isIgnored($0.id) },
                name: { CalendarAliases.shared.name(for: $0.id, real: $0.name) })
            let names = Dictionary(
                current.calendars.map { ($0.id, CalendarAliases.shared.name(for: $0.id, real: $0.name)) },
                uniquingKeysWith: { first, _ in first })
            CardSection(
                header: OverviewSectionHeader(title: "Next up today", link: "Open Calendar") { navigation.selection = .calendar },
                content: {
                    if !stale.isEmpty {
                        CardRow {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .center, spacing: 12) { staleNextUp(stale); refreshButton }
                                VStack(alignment: .leading, spacing: 10) { staleNextUp(stale); refreshButton }
                            }
                        }
                    }
                    ForEach(Array(events.prefix(4).enumerated()), id: \.element.id) { index, event in
                        NextUpRow(
                            event: event, calendarName: names[event.calendarID] ?? "Calendar",
                            color: CalendarColors.shared.color(for: event.calendarID).color,
                            tags: UpNextTag.tags(for: event, isNext: index == 0, now: now)
                        ) { navigation.openCalendar(showing: event, in: schedule) }
                    }
                    if events.count > 4 { CardRow { Text("and \(events.count - 4) more").foregroundStyle(.secondary) } }
                    if events.isEmpty { CardRow { Text("Nothing else today").foregroundStyle(.secondary) } }
                })
        }
    }

    private func staleNextUp(_ stale: [String]) -> some View {
        Banner(kind: .caution, text: "\(stale.joined(separator: ", ")) \(stale.count == 1 ? "is" : "are") out of date, so events may be missing.")
    }

    // MARK: Attention

    @ViewBuilder
    private func attention(_ status: AgentControlStatus) -> some View {
        let checks = model.attentionChecks
        if let health = model.health, health.status != "ok", !checks.isEmpty {
            CardSection(
                header: Text("Needs attention").font(Theme.Fonts.sectionTitle),
                footnote: health.warnings.isEmpty ? nil : health.warnings.joined(separator: " ")
            ) {
                ForEach(checks) { check in
                    let failedRun = check.name == "automatic-run" && check.state == "failed"
                    CardRow {
                        AttentionRow(
                            title: check.name.replacingOccurrences(of: "-", with: " ").capitalized,
                            detail: attentionDetail(check, status),
                            failed: check.state == "failed",
                            reason: failedRun ? syncFailureReason(category: check.reason) : nil,
                            showingReason: Binding(
                                get: { openReasons.contains(check.name) },
                                set: { if $0 { openReasons.insert(check.name) } else { openReasons.remove(check.name) } }))
                    }
                    if check.name == "source-install" {
                        CardRow {
                            Button("Turn off") { Task { await model.turnOffSourceInstall() } }
                                .disabled(model.isBusy)
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
        return "Failed, \(Format.ago(age))"
    }

    // MARK: Calendars

    @ViewBuilder
    private var calendarsCard: some View {
        let calendars = (schedule.schedule?.calendars ?? []).filter { !CalendarAliases.shared.isIgnored($0.id) }
        if !calendars.isEmpty {
            let now = Date()
            let labels = calendars.map { CalendarFreshnessLabel.make($0, range: today, now: now) }
            CardSection(
                header: OverviewSectionHeader(title: "Calendars", link: "Manage") { navigation.selection = .calendars },
                content: {
                    ForEach(Array(zip(calendars, labels)), id: \.0.id) { calendar, label in
                        CardRow {
                            HStack(spacing: 10) {
                                Circle().fill(CalendarColors.shared.color(for: calendar.id).color).frame(width: 10, height: 10)
                                Text(CalendarAliases.shared.name(for: calendar.id, real: calendar.name)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(label.text).font(Theme.Fonts.secondary)
                                    .foregroundStyle(label.isBehind ? Theme.cautionText : Color.secondary)
                            }
                        }
                    }
                    if labels.contains(where: \.isBehind) {
                        CardRow { HStack { refreshButton; Spacer(minLength: 0) } }
                    }
                })
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
