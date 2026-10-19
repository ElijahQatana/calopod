import CalopodSnapshot
import Foundation

/// What Home shows, worked out from one snapshot: the Mac Overview, made small.
struct HomeSummary: Equatable {
    enum Sync { case inSync, didNotFinish, behind }

    struct Next: Equatable {
        var event: CalendarEvent
        /// "Now" or "In 12 min". Nil when the data is old, since the times could be wrong.
        var chip: String?
    }

    static let nextShown = 2
    static let calendarsShown = 2

    var invitations: Int
    var overlaps: Int
    var changes: Int
    var sync: Sync
    var lastSync: Date?
    /// False when the Mac shares no calendar events, so Next up has nothing to say but how to start.
    var hasCalendars: Bool
    var next: [Next]
    var moreToday: Int
    /// Today as the Mac published it. Nil when it sent nothing for today.
    var availability: AvailabilityFigures?
    var calendars: [StatusReport.Row]
    var moreCalendars: Int

    /// `hidden` holds calendars the person hid on this phone. They stay out of Next up.
    init(context: SnapshotContext, hidden: Set<String>, calendar: Calendar = .current) {
        let snapshot = context.snapshot, now = context.now
        invitations = InboxFilter.needsRSVP.apply(to: snapshot.inbox).count
        overlaps = InboxFilter.conflicts.apply(to: snapshot.inbox).count
        changes = InboxFilter.changes.apply(to: snapshot.inbox).count

        let report = StatusReport(status: snapshot.status, calendars: snapshot.calendars)
        sync = report.hasFailure ? .didNotFinish : context.isStale ? .behind : .inSync
        lastSync = report.lastSyncAt
        calendars = Array(report.rows.prefix(Self.calendarsShown))
        moreCalendars = max(0, report.rows.count - Self.calendarsShown)

        availability = AvailabilityFigures.week(from: snapshot.availability).first { $0.interval.contains(now) }
        hasCalendars = !snapshot.days.isEmpty
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        var seen = Set<String>()
        let coming = snapshot.days.flatMap(\.events)
            .filter { seen.insert($0.id).inserted }
            .filter { !$0.isAllDay && $0.response != .declined && !hidden.contains($0.calendarID) }
            .filter { $0.endsAt > now && $0.startsAt < endOfToday }
            .sorted { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
        next = coming.prefix(Self.nextShown).map { Next(event: $0, chip: context.isStale ? nil : Self.chip(for: $0, now: now)) }
        moreToday = max(0, coming.count - Self.nextShown)
    }

    static func chip(for event: CalendarEvent, now: Date) -> String {
        guard event.startsAt > now else { return "Now" }
        let minutes = max(1, Int((event.startsAt.timeIntervalSince(now) / 60).rounded(.up)))
        return "In \(DurationText.text(Double(minutes) * 60))"
    }
}
