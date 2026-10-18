import CalopodCommands
import SwiftUI

struct MenuPopover: View {
    let model: ServiceModel
    let navigation: AppNavigation
    let inbox: InboxModel
    let schedule: CalendarModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.Fonts.bodySemibold)
                    if let age = model.status?.lastSuccessAgeSeconds {
                        Text("Last synced \(Format.ago(age))").font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Self.card)
            if let busy = model.busyAction { BusyLine(text: busy) }
            if let notice = model.notice { Text(notice).font(Theme.Fonts.secondary).foregroundStyle(Theme.bad) }

            if let next = nextEvent { nextCard(next) }
            if inbox.waiting > 0 { waitingCard }
            if !stale.isEmpty {
                Label("\(stale.joined(separator: ", ")) is out of date", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.caution, .secondary)
            }

            if let status = model.status, status.installed {
                HStack(spacing: 8) {
                    Button("Preview sync") { open(.overview, keepMenu: true); Task { await model.previewSync() } }
                        .buttonStyle(.accentFilled)
                        .disabled(model.isBusy)
                    if status.enabled {
                        Button(status.paused ? "Resume" : "Pause") {
                            Task { await model.setPaused(!status.paused) }
                        }
                        .buttonStyle(.neutral)
                        .disabled(model.isBusy)
                    }
                }
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

    private static var card: some View {
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Theme.innerFill)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.paneLine, lineWidth: 1))
    }

    private var nextEvent: ScheduleEvent? { UpNext.events(in: schedule.schedule, from: Date()).first }
    private var todayCount: Int? {
        schedule.schedule == nil ? nil : UpNext.today(in: schedule.schedule, now: Date()).count
    }
    private var stale: [String] { UpNext.staleCalendars(in: schedule.schedule, name: { CalendarAliases.shared.name(for: $0.id, real: $0.name) }) }

    private func nextCard(_ event: ScheduleEvent) -> some View {
        HStack(spacing: 10) {
            Circle().fill(CalendarColors.shared.color(for: event.calendarID).color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.startsAt <= Date() ? "Now" : "Next").font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                Text(event.title).font(Theme.Fonts.bodyMedium).lineLimit(1)
                Text(event.startsAt.formatted(date: .omitted, time: .shortened)).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.card)
        .contentShape(Rectangle())
        .onTapGesture { open(.calendar) }
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
        DockPresence.enter()
        let popover = NSApp.keyWindow.flatMap { $0.title == "Calopod" ? nil : $0 }
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "home")
        guard !keepMenu else { return }
        dismiss()
        // dismiss() is not honored by every popover, so close its window as well.
        DispatchQueue.main.async { if popover?.isVisible == true { popover?.close() } }
    }

    private var title: String {
        guard let status = model.status else { return "Checking…" }
        guard status.installed else { return "Not set up yet" }
        return switch status.state {
        case "ok": "Syncing"
        case "paused": "Paused"
        case "disabled": "Sync is off"
        case "failed": "Needs attention"
        default: "Stopped"
        }
    }

    private var color: Color {
        switch model.status?.state {
        case "ok": Theme.good
        case "paused", "disabled": Theme.caution
        case "failed", "stopped": Theme.bad
        default: .secondary
        }
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
            HStack {
                Label(title, systemImage: symbol).foregroundStyle(tint)
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
