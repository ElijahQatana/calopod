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

    /// One line above Needs you. Each part is nil when the data cannot say it.
    struct Glance: Equatable {
        /// The free stretch that is under way or comes next, cut at now.
        var free: DateInterval?
        var freeNow: Bool
        var timeZone: TimeZone
        var meetingsLeft: Int?

        /// "Next free: 09:45 to 10:00", or nil when no free stretch is known.
        func freeText(locale: Locale = .current) -> String? {
            guard let free else { return nil }
            let style = Date.FormatStyle(locale: locale, timeZone: timeZone).hour().minute()
            return freeNow ? "Free until \(free.end.formatted(style))"
                : "Next free: \(free.start.formatted(style)) to \(free.end.formatted(style))"
        }

        var meetingsText: String? {
            guard let meetingsLeft else { return nil }
            return meetingsLeft == 0 ? "No meetings left today"
                : meetingsLeft == 1 ? "1 meeting left today" : "\(meetingsLeft) meetings left today"
        }

        func text(locale: Locale = .current) -> String? {
            let parts = [freeText(locale: locale), meetingsText].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    static let nextShown = 3
    /// Shorter gaps are not worth pointing out.
    static let shortestFree: TimeInterval = 15 * 60

    var invitations: Int
    var overlaps: Int
    var changes: Int
    var sync: Sync
    /// False when the Mac shares no calendar events, so Next up has nothing to say but how to start.
    var hasCalendars: Bool
    var next: [Next]
    var moreToday: Int
    /// Today as the Mac published it. Nil when it sent nothing for today.
    var availability: AvailabilityFigures?
    var glance: Glance?

    /// `hidden` holds calendars the person hid on this phone. They stay out of Next up.
    init(context: SnapshotContext, hidden: Set<String>, calendar: Calendar = .current) {
        let snapshot = context.snapshot, now = context.now
        invitations = InboxFilter.needsRSVP.apply(to: snapshot.inbox).count
        overlaps = InboxFilter.conflicts.apply(to: snapshot.inbox).count
        changes = InboxFilter.changes.apply(to: snapshot.inbox).count

        let report = StatusReport(status: snapshot.status, calendars: snapshot.calendars)
        sync = report.hasFailure ? .didNotFinish : context.isStale ? .behind : .inSync

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

        if context.isStale {
            glance = nil
        } else {
            let free = availability?.worked?.free
                .filter { $0.end > now }
                .map { DateInterval(start: max($0.start, now), end: $0.end) }
                .first { $0.duration >= Self.shortestFree }
            let meetings = hasCalendars ? coming.count : nil
            glance = free == nil && meetings == nil ? nil : Glance(
                free: free, freeNow: free?.start == now, timeZone: availability?.timeZone ?? calendar.timeZone, meetingsLeft: meetings)
        }
    }

    static func chip(for event: CalendarEvent, now: Date) -> String {
        guard event.startsAt > now else { return "Now" }
        let minutes = max(1, Int((event.startsAt.timeIntervalSince(now) / 60).rounded(.up)))
        return "In \(DurationText.text(Double(minutes) * 60))"
    }
}
