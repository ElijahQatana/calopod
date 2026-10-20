import CalopodCommands
import CalopodDomain
import SwiftUI

struct MenuPopover: View {
    let model: ServiceModel
    let navigation: AppNavigation
    let inbox: InboxModel
    let schedule: CalendarModel
    var joiner: any MeetingJoining = MeetingJoiner.system
    @State private var joinNotice: String?
    /// The time the Next card is computed for. Set when the popover appears and at each boundary.
    @State private var now = Date()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    static let width: CGFloat = 300
    /// The even gap between the window edge and the panel on all four sides. The panel's corner
    /// radius less its own 4 pt padding is the rows' highlight radius, so the corners nest.
    static let inset: CGFloat = 6
    private static var panel: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous) }
    /// What a row's text can use: the window minus the insets, the row padding, the light and its gap.
    static let statusTextWidth = width - 2 * inset - 8 - 24 - 8 - 8

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            statusLine
            if let busy = model.busyAction { BusyLine(text: busy).padding(.horizontal, 12) }
            if let notice = model.notice {
                Text(notice).font(Theme.Fonts.secondary).foregroundStyle(Theme.badText).padding(.horizontal, 12)
            }
            if let next = nextChoice.primary { nextLine(next) }
            if let joinNotice { Banner(kind: .error, text: joinNotice, onDismiss: { self.joinNotice = nil }) }
            if !stale.isEmpty {
                Label("\(stale.joined(separator: ", ")) is out of date", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.cautionText, .secondary)
                    .lineLimit(1).padding(.horizontal, 12)
            }

            if let status = model.status, status.installed { syncControls(status) }

            VStack(spacing: 0) {
                row("Open Calopod", "macwindow") { open(.overview) }
                row("Calendar", "calendar.day.timeline.left", count: todayCount) { open(.calendar) }
                row("Inbox", "tray", count: inbox.count) { openInbox(.all) }
                row("Quit Calopod", "power", tint: .secondary) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(4)
        .background(Self.panel.fill(Theme.innerFill))
        .overlay(Self.panel.strokeBorder(Theme.paneLine, lineWidth: 1))
        .padding(Self.inset)
        .frame(width: Self.width)
        .appTypography()
        // Sleeps until the next moment the choice can change, and recomputes when the schedule reloads.
        .task(id: schedule.schedule) {
            while !Task.isCancelled {
                now = Date()
                guard let wake = UpNext.next(in: schedule.schedule, now: now, ignored: Self.isIgnored).changesAt else { return }
                try? await Task.sleep(for: .seconds(max(0.5, wake.timeIntervalSinceNow)))
            }
        }
    }

    private func syncControls(_ status: AgentControlStatus) -> some View {
        MenuSyncControls(
            rule: model.previewRule, busy: model.isBusy, offersEnable: model.syncHealth.offersEnable,
            pausable: status.enabled ? status.paused : nil,
            preview: { open(.overview, keepMenu: true); Task { await model.previewSync() } },
            enable: { Task { await model.setEnabled(true) } },
            togglePause: { Task { await model.setPaused(!status.paused) } })
    }

    private var todayCount: Int? {
        schedule.schedule == nil ? nil : UpNext.today(in: schedule.schedule, now: now, ignored: Self.isIgnored).count
    }

    private var statusLine: some View {
        StatusLine(color: model.syncHealth.color, text: model.syncHealth.menuLine)
    }

    private static let isIgnored: (String) -> Bool = { CalendarAliases.shared.isIgnored($0) }

    private var nextChoice: UpNext.Next { UpNext.next(in: schedule.schedule, now: now, ignored: Self.isIgnored) }
    private var stale: [String] { UpNext.staleToday(
        in: schedule.schedule, ignored: { CalendarAliases.shared.isIgnored($0.id) },
        name: { CalendarAliases.shared.name(for: $0.id, real: $0.name) }) }

    private func nextLine(_ primary: UpNext.Next.Line) -> some View {
        let link = JoinOffer.link(for: primary.event, now: now)
        return NextLine(
            primary: primary, now: now, color: CalendarColors.shared.color(for: primary.event.calendarID).color,
            joinLink: link,
            join: { link in
                Task {
                    joinNotice = await JoinOffer.join(link, using: joiner)
                    if joinNotice == nil { closePopover() }
                }
            },
            open: { event in
                navigation.openCalendar(showing: event, in: schedule)
                show()
            })
    }

    private func row(
        _ title: String, _ symbol: String, count: Int? = nil, tint: Color = .primary, action: @escaping () -> Void
    ) -> some View {
        MenuRow(title: title, symbol: symbol, count: count, tint: tint, action: action)
    }

    private func openInbox(_ filter: InboxFilter) {
        navigation.openInbox(filter)
        show()
    }

    private func open(_ screen: Screen, keepMenu: Bool = false) {
        navigation.selection = screen
        show(keepMenu: keepMenu)
    }

    /// Opens the window, then closes the popover unless it should stay for watching status.
    private func show(keepMenu: Bool = false) {
        let popover = NSApp.keyWindow.flatMap { $0.title == "Calopod" ? nil : $0 }
        MainWindowOpener.shared.show { openWindow(id: "home") }
        guard !keepMenu else { return }
        closePopover(popover)
    }

    private func closePopover(_ popover: NSWindow? = NSApp.keyWindow.flatMap { $0.title == "Calopod" ? nil : $0 }) {
        dismiss()
        // dismiss() is not honored by every popover, so close its window as well.
        DispatchQueue.main.async { if popover?.isVisible == true { popover?.close() } }
    }
}

/// A thin capsule button for the menu bar window, in place of the standard 36 pt controls.
struct MenuButtonStyle: ButtonStyle {
    static let font = Font.system(size: 13, weight: .semibold)
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let fill = prominent ? Theme.accent.opacity(configuration.isPressed ? 0.8 : 1) : Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08)
        return configuration.label
            .font(Self.font)
            .foregroundStyle(prominent ? Theme.onAccent : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Preview, Enable and Pause on one thin row, with the reason when Preview is unavailable.
struct MenuSyncControls: View {
    let rule: PreviewSyncRule
    let busy: Bool
    let offersEnable: Bool
    /// Nil when automatic sync is off, so there is nothing to pause.
    let pausable: Bool?
    let preview: () -> Void
    let enable: () -> Void
    let togglePause: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button("Preview sync", action: preview)
                    .buttonStyle(MenuButtonStyle(prominent: true))
                    .previewSync(rule)
                if offersEnable {
                    Button("Enable", action: enable).buttonStyle(MenuButtonStyle()).disabled(busy)
                }
                if let paused = pausable {
                    Button(paused ? "Resume" : "Pause", action: togglePause).buttonStyle(MenuButtonStyle()).disabled(busy)
                }
            }
            // While a sync runs, the busy line above already says why.
            if !busy, let reason = rule.disabledReason {
                Text("Preview sync is unavailable: \(reason.prefix(1).lowercased() + reason.dropFirst()).")
                    .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}

/// The status light and its one line.
struct StatusLine: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(Theme.Fonts.bodyMedium).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).frame(minHeight: Theme.Control.popoverRowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// The meeting now or next on one line. The line opens the event in Calendar, and a small button
/// joins when there is a link.
struct NextLine: View {
    let primary: UpNext.Next.Line
    let now: Date
    let color: Color
    let joinLink: MeetingLink?
    let join: (MeetingLink) -> Void
    let open: (ScheduleEvent) -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { open(primary.event) } label: {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    // The minute count only needs to be right to the minute, so a minute clock drives it.
                    TimelineView(.everyMinute) { context in
                        Text(NextCardText.line(for: primary, now: max(now, context.date)))
                            .font(Theme.Fonts.body).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Control.popoverRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let joinLink {
                Button { join(joinLink) } label: { Label(joinLink.buttonTitle, systemImage: "video") }
                    .buttonStyle(MenuButtonStyle(prominent: primary.role == .current))
                    .help(JoinButton.help(for: joinLink)).fixedSize()
                    .padding(.leading, 16).padding(.bottom, 2)
            }
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .fill(hovering ? Theme.accent.opacity(0.14) : .clear))
        .onHover { hovering = $0 }
    }
}

/// The wording on the Next card.
enum NextCardText {
    static func label(for line: UpNext.Next.Line, now: Date) -> String {
        switch line.role {
        case .current, .inProgress:
            let minutes = max(0, Int(now.timeIntervalSince(line.event.startsAt) / 60))
            return minutes == 0 ? "Now" : "Now, \(minutes) min in"
        case .upcoming:
            let minutes = max(1, Int((line.event.startsAt.timeIntervalSince(now) / 60).rounded(.up)))
            return "Next, in \(minutes) min"
        }
    }

    /// The one line in the menu bar window: "Now: Title", or the countdown then the title.
    static func line(for line: UpNext.Next.Line, now: Date) -> String {
        switch line.role {
        case .current, .inProgress: "Now: \(line.event.title)"
        case .upcoming: "\(label(for: line, now: now)): \(line.event.title)"
        }
    }
}

/// A menu item with a rounded highlight under the pointer.
private struct MenuRow: View {
    let title: String
    let symbol: String
    let count: Int?
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(tint)
                Text(title).foregroundStyle(tint)
                Spacer()
                if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).frame(minHeight: Theme.Control.popoverRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .fill(hovering ? Theme.accent.opacity(0.14) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
