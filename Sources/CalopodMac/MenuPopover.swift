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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(model.syncHealth.color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.syncHealth.label).font(Theme.Fonts.bodySemibold)
                    if let age = model.syncHealth.lastSyncedAge {
                        Text("Last synced \(Format.ago(age))").font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Self.card)
            if let busy = model.busyAction { BusyLine(text: busy) }
            if let notice = model.notice { Text(notice).font(Theme.Fonts.secondary).foregroundStyle(Theme.badText) }

            if let next = nextEvent { nextCard(next) }
            if let joinNotice { Banner(kind: .error, text: joinNotice, onDismiss: { self.joinNotice = nil }) }
            if inbox.waiting > 0 { waitingCard }
            if !stale.isEmpty {
                Label("\(stale.joined(separator: ", ")) is out of date", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.cautionText, .secondary)
            }

            if let status = model.status, status.installed {
                MenuSyncControls(
                    rule: model.previewRule, busy: model.isBusy, offersEnable: model.syncHealth.offersEnable,
                    pausable: status.enabled ? status.paused : nil,
                    preview: { open(.overview, keepMenu: true); Task { await model.previewSync() } },
                    enable: { Task { await model.setEnabled(true) } },
                    togglePause: { Task { await model.setPaused(!status.paused) } })
            }

            VStack(spacing: 2) {
                row("Open Calopod", "macwindow", count: nil) { open(.overview) }
                row("Calendar", "calendar.day.timeline.left", count: todayCount) { open(.calendar) }
                row("Inbox", "tray", count: inbox.count) { openInbox(.all) }
                row("Quit Calopod", "power", count: nil, tint: .secondary) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
        .appTypography()
    }

    fileprivate static var card: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.innerFill)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.paneLine, lineWidth: 1))
    }

    private var nextEvent: ScheduleEvent? { UpNext.events(in: schedule.schedule, from: Date()).first }
    private var todayCount: Int? {
        schedule.schedule == nil ? nil : UpNext.today(in: schedule.schedule, now: Date()).count
    }
    private var stale: [String] { UpNext.staleToday(
        in: schedule.schedule, ignored: { CalendarAliases.shared.isIgnored($0.id) },
        name: { CalendarAliases.shared.name(for: $0.id, real: $0.name) }) }

    private func nextCard(_ event: ScheduleEvent) -> some View {
        NextCard(event: event, color: CalendarColors.shared.color(for: event.calendarID).color, now: Date(), join: { link in
            Task {
                joinNotice = await JoinOffer.join(link, using: joiner)
                if joinNotice == nil { closePopover() }
            }
        }) {
            navigation.openCalendar(showing: event, in: schedule)
            show()
        }
    }

    private var waitingCard: some View { WaitingCard(count: inbox.waiting) { openInbox(.needsRSVP) } }

    private func row(
        _ title: String, _ symbol: String, count: Int?, tint: Color = .primary, action: @escaping () -> Void
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

/// Preview, Enable and Pause under the status card, with the reason when Preview is unavailable.
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Preview sync", action: preview)
                    .buttonStyle(.accentFilled)
                    .previewSync(rule)
                if offersEnable {
                    Button("Enable", action: enable).buttonStyle(.neutral).disabled(busy)
                }
                if let paused = pausable {
                    Button(paused ? "Resume" : "Pause", action: togglePause).buttonStyle(.neutral).disabled(busy)
                }
            }
            // While a sync runs, the busy line above already says why.
            if !busy, let reason = rule.disabledReason {
                Text("Preview sync is unavailable: \(reason.prefix(1).lowercased() + reason.dropFirst()).")
                    .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            }
        }
    }
}

/// The next event. The details open it in Calendar; Join, when there is a link, is its own button
/// beside them, or under them when the card is too narrow.
struct NextCard: View {
    let event: ScheduleEvent
    let color: Color
    let now: Date
    let join: (MeetingLink) -> Void
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let link = JoinOffer.link(for: event, now: now)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                details
                if let link { joinButton(link).padding(.trailing, 12) }
            }
            VStack(alignment: .leading, spacing: 0) {
                details
                if let link { joinButton(link).padding(.leading, 32).padding(.bottom, 12) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MenuPopover.card)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.accent.opacity(hovering ? 0.14 : 0)).allowsHitTesting(false))
        .onHover { hovering = $0 }
    }

    private var details: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.startsAt <= now ? "Now" : "Next").font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    Text(event.title).font(Theme.Fonts.bodyMedium).lineLimit(1)
                    Text(event.startsAt.formatted(date: .omitted, time: .shortened)).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressedFade())
    }

    private func joinButton(_ link: MeetingLink) -> some View {
        JoinButton(link: link, prominent: JoinOffer.isProminent(event, now: now)) { join(link) }
            .help(JoinButton.help(for: link))
            .fixedSize()
    }
}

private struct PressedFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct WaitingCard: View {
    let count: Int
    let review: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge").foregroundStyle(Theme.accent)
            Text(count == 1 ? "1 invitation waiting" : "\(count) invitations waiting")
                .font(Theme.Fonts.bodyMedium)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Review", action: review).buttonStyle(.accentFilled).fixedSize()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.accent.opacity(0.12)))
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
                Image(systemName: symbol).frame(width: 22).foregroundStyle(tint)
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
