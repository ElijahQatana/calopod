import CalopodCommands
import SwiftUI

struct MenuPopover: View {
    let model: ServiceModel
    let navigation: AppNavigation
    let inbox: InboxModel
    let schedule: CalendarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    if let age = model.status?.lastSuccessAgeSeconds {
                        Text("Last synced \(Format.ago(age))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let busy = model.busyAction { BusyLine(text: busy) }
            if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(Theme.bad) }

            if let next = nextEvent { nextCard(next) }
            if inbox.waiting > 0 { waitingCard }
            if !stale.isEmpty {
                Label("\(stale.joined(separator: ", ")) is out of date", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Theme.caution, .secondary)
            }

            if let status = model.status, status.installed {
                HStack(spacing: 8) {
                    Button("Preview sync") { open(.overview); Task { await model.previewSync() } }
                        .buttonStyle(.accentFilled)
                        .disabled(model.isBusy)
                    if status.enabled {
                        Button(status.paused ? "Resume" : "Pause") {
                            Task { await model.setPaused(!status.paused) }
                        }
                        .disabled(model.isBusy)
                    }
                }
            }

            Divider()
            row("Open Calopod", "macwindow", count: nil) { open(.overview) }
            row("Calendar", "calendar.day.timeline.left", count: todayCount) { open(.calendar) }
            row("Inbox", "tray", count: inbox.count) { openInbox(.all) }
            Divider()
            Button("Quit Calopod") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
    }

    private var nextEvent: ScheduleEvent? { UpNext.events(in: schedule.schedule, from: Date()).first }
    private var todayCount: Int? {
        schedule.schedule == nil ? nil : UpNext.today(in: schedule.schedule, now: Date()).count
    }
    private var stale: [String] { UpNext.staleCalendars(in: schedule.schedule) }

    private func nextCard(_ event: ScheduleEvent) -> some View {
        HStack(spacing: 10) {
            Circle().fill(CalendarColors.shared.color(for: event.calendarID).color).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.startsAt <= Date() ? "Now" : "Next").font(.caption).foregroundStyle(.secondary)
                Text(event.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(event.startsAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(.calendar) }
    }

    private var waitingCard: some View { WaitingCard(count: inbox.waiting) { openInbox(.needsRSVP) } }

    private func row(_ title: String, _ symbol: String, count: Int?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let count, count > 0 { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openInbox(_ filter: InboxFilter) {
        navigation.openInbox(filter)
        show()
    }

    private func open(_ screen: Screen) {
        navigation.selection = screen
        show()
    }

    private func show() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "home")
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
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Review", action: review).buttonStyle(.accentFilled).fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous).fill(Theme.accent.opacity(0.12)))
    }
}
