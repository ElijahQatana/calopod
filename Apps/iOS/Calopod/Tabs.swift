import CalopodSnapshot
import SwiftUI

private let timeFormat = Date.FormatStyle.dateTime.hour().minute()
private let dayFormat = Date.FormatStyle.dateTime.weekday(.wide).day().month(.abbreviated)

/// What every tab needs: the snapshot, whether it is old, and the clock.
struct SnapshotContext {
    var snapshot: Snapshot
    var offline: Bool
    var now: Date

    var isStale: Bool { offline || Age.isStale(snapshot.publishedAt, now: now) }
    var fromMac: String { "from your Mac at \(snapshot.publishedAt.formatted(timeFormat))" }
}

struct InboxTab: View {
    var context: SnapshotContext

    var body: some View {
        let items = context.snapshot.inbox
        Screen(title: "Inbox", subtitle: "\(items.count) \(items.count == 1 ? "item" : "items") · \(context.fromMac)") {
            if context.isStale {
                StaleBanner(lastUpdate: context.snapshot.publishedAt, now: context.now, offline: context.offline)
            }
            Group {
                if items.isEmpty {
                    Card { Text("Nothing needs a look.").font(Theme.Fonts.body).padding(16) }
                }
                ForEach(days(items), id: \.day) { group in
                    SectionLabel(text: group.day.formatted(dayFormat))
                    Card {
                        ForEach(group.items, id: \.id) { item in
                            InboxRow(item: item, calendar: context.snapshot.calendar(for: item.calendarID))
                            if item.id != group.items.last?.id { Divider().overlay(Theme.line) }
                        }
                    }
                }
                ReadOnlyFoot()
            }
            .opacity(context.isStale ? 0.6 : 1)
        }
    }

    private func days(_ items: [InboxItem]) -> [(day: Date, items: [InboxItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.startsAt) }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.startsAt < $1.startsAt }) }
    }
}

private struct InboxRow: View {
    var item: InboxItem
    var calendar: CalendarEntry?

    var body: some View {
        let color = Theme.calendarColor(calendar?.colorIndex)
        HStack(spacing: 12) {
            VStack(spacing: 1) {
                Text(item.startsAt.formatted(timeFormat)).font(Theme.Fonts.bodyStrong).monospacedDigit()
                Text(duration).font(.caption2).foregroundStyle(Theme.secondary)
            }
            .frame(width: 54).padding(.vertical, 7)
            .background(color.opacity(0.2), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "Untitled").font(Theme.Fonts.bodyStrong).lineLimit(1)
                if let calendar {
                    Label { Text(calendar.name) } icon: { Circle().fill(color).frame(width: 8, height: 8) }
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 5) {
                    ForEach(item.reasons, id: \.self) { ReasonPill(reason: $0) }
                    if item.changeOrderUncertain { Pill(text: "Order uncertain", color: Theme.secondary, fill: Theme.fill) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12).padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    private var duration: String {
        let minutes = Int(item.endsAt.timeIntervalSince(item.startsAt) / 60)
        return minutes >= 60 ? (minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m") : "\(minutes)m"
    }
}

private struct ReasonPill: View {
    var reason: InboxReason

    var body: some View {
        switch reason {
        case .needsRSVP: Pill(text: "Needs RSVP", color: Theme.accent, fill: Theme.accentSoft)
        case .maybe: Pill(text: "Maybe", color: Theme.caution, fill: Theme.cautionSoft)
        case .unreadChange: Pill(text: "Changed", color: Theme.text, fill: Theme.fill)
        case .conflict: Pill(text: "Conflict", color: Theme.bad, fill: Theme.badSoft)
        }
    }
}

private struct Pill: View {
    var text: String
    var color: Color
    var fill: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.leading, 8).padding(.trailing, 9).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(fill, in: Capsule())
    }
}

struct CalendarTab: View {
    var context: SnapshotContext

    var body: some View {
        Screen(title: "Calendar", subtitle: "Busy time \(context.fromMac)") {
            if context.isStale {
                StaleBanner(lastUpdate: context.snapshot.publishedAt, now: context.now, offline: context.offline)
            }
            Group {
                ForEach(context.snapshot.availability, id: \.id) { day in
                    Card {
                        HStack {
                            Text(label(day)).font(Theme.Fonts.bodyStrong)
                            Spacer()
                            Text(day.busy.isEmpty ? "Free" : "\(day.busy.count) busy \(day.busy.count == 1 ? "block" : "blocks")")
                                .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                        }
                        .padding(14)
                    }
                }
                ReadOnlyFoot(text: "Read only. The full day view comes later.")
            }
            .opacity(context.isStale ? 0.6 : 1)
        }
    }

    private func label(_ day: AvailabilityDay) -> String {
        let parser = Date.ISO8601FormatStyle().year().month().day().dateSeparator(.dash)
        guard let date = try? Date(day.day, strategy: parser) else { return day.day }
        return date.formatted(dayFormat)
    }
}

struct StatusTab: View {
    var context: SnapshotContext

    var body: some View {
        let status = context.snapshot.status
        let problem = status.issues.contains { $0.kind == .failed }
        Screen(title: "Status", subtitle: "Reported by your Mac") {
            if context.isStale {
                StaleBanner(lastUpdate: context.snapshot.publishedAt, now: context.now, offline: context.offline)
            }
            Card {
                HStack(spacing: 12) {
                    Image(systemName: problem ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.title2).foregroundStyle(problem ? Theme.bad : Theme.good)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(problem ? "Last sync didn't finish" : "Syncing normally").font(Theme.Fonts.heading)
                        Text(status.lastSyncAt.map { "Last sync \($0.formatted(timeFormat))" } ?? "No sync yet")
                            .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            if !status.issues.isEmpty {
                SectionLabel(text: "Needs attention")
                Card {
                    ForEach(Array(status.issues.enumerated()), id: \.offset) { _, issue in
                        Text(describe(issue)).font(Theme.Fonts.body).padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            SectionLabel(text: "Calendars")
            Card {
                ForEach(context.snapshot.calendars, id: \.id) { calendar in
                    Label { Text(calendar.name) } icon: {
                        Circle().fill(Theme.calendarColor(calendar.colorIndex)).frame(width: 10, height: 10)
                    }
                    .font(Theme.Fonts.body).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set up on your Mac").font(Theme.Fonts.bodyStrong)
                    Text("Calendars, colors and what syncs are all chosen in Calopod on your Mac.")
                        .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                }
                .padding(14)
            }
            ReadOnlyFoot(text: "Synced through your private iCloud.")
        }
    }

    private func describe(_ issue: SyncIssue) -> String {
        let name = issue.calendarID.flatMap { context.snapshot.calendar(for: $0)?.name }
        switch issue.kind {
        case .failed: return name.map { "\($0) failed to sync." } ?? "The last sync failed."
        case .partial: return name.map { "\($0) only partly synced." } ?? "The last sync was only partial."
        case .stale: return name.map { "\($0) hasn't refreshed in a while." } ?? "Calendars haven't refreshed in a while."
        }
    }
}
