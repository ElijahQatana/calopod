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
    /// What a row's text can use: the window minus its padding, the row padding, the light and its gap.
    static let statusTextWidth = width - 16 - 24 - 8 - 8

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

            VStack(spacing: 0) {
                if inbox.waiting > 0 {
                    row(inbox.waiting == 1 ? "1 invitation waiting" : "\(inbox.waiting) invitations waiting", "envelope.badge") {
                        openInbox(.needsRSVP)
                    }
                }
                row("Open Calopod", "macwindow") { open(.overview) }
                if let status = model.status, status.installed {
                    if model.syncHealth.offersEnable {
                        row("Turn on sync", "power") { Task { await model.setEnabled(true) } }.disabled(model.isBusy)
                    }
                    if status.enabled {
                        row(status.paused ? "Resume sync" : "Pause sync", status.paused ? "play.fill" : "pause.fill") {
                            Task { await model.setPaused(!status.paused) }
                        }
                        .disabled(model.isBusy)
                    }
                }
                row("Quit Calopod", "power", tint: .secondary) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(8)
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
        _ title: String, _ symbol: String, tint: Color = .primary, action: @escaping () -> Void
    ) -> some View {
        MenuRow(title: title, symbol: symbol, tint: tint, action: action)
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
        HStack(spacing: 4) {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let joinLink {
                Button { join(joinLink) } label: { Image(systemName: "video") }
                    .controlSize(.small).help("Join \(joinLink.provider.displayName)").accessibilityLabel(joinLink.buttonTitle)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: Theme.Control.popoverRowHeight)
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
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(tint)
                Text(title).foregroundStyle(tint)
                Spacer()
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
