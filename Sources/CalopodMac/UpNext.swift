import CalopodCommands
import Foundation

/// What Overview and the menu bar show. Counts come straight from the Inbox board, and
/// events from the same local copy the Calendar screen reads.
enum UpNext {
    /// Timed events still ahead or in progress, soonest first. Calopod's own copies are left out.
    static func events(in schedule: CalendarSchedule?, from now: Date, before end: Date? = nil) -> [ScheduleEvent] {
        (schedule?.events ?? [])
            .filter { !$0.isCopy && !$0.isAllDay && $0.endsAt > now && ($0.startsAt < (end ?? .distantFuture)) }
            .sorted { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
    }

    static func today(in schedule: CalendarSchedule?, now: Date, calendar: Calendar = .current) -> [ScheduleEvent] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        return events(in: schedule, from: now, before: end)
    }

    /// Calendars whose copy is old or missing, so the list above may be incomplete. With a range,
    /// a calendar read only part of the way across it counts too.
    static func staleCalendars(
        in schedule: CalendarSchedule?, range: Range<Date>? = nil, now: Date = Date(),
        name: (ScheduleCalendar) -> String = { $0.name }
    ) -> [String] {
        (schedule?.calendars ?? []).filter { calendar in
            guard let range else { return calendar.freshness != .current }
            return CalendarFreshnessLabel.make(calendar, range: range, now: now).isBehind
        }.map(name)
    }

    /// The same check for today, with ignored calendars left out. Overview and the menu bar both use
    /// this, and the Calendars list reads `CalendarFreshnessLabel`, so they cannot disagree.
    static func staleToday(
        in schedule: CalendarSchedule?, now: Date = Date(), calendar: Calendar = .current,
        ignored: (ScheduleCalendar) -> Bool = { _ in false }, name: (ScheduleCalendar) -> String = { $0.name }
    ) -> [String] {
        guard let schedule else { return [] }
        let start = calendar.startOfDay(for: now)
        let range = start..<(calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        let kept = CalendarSchedule(calendars: schedule.calendars.filter { !ignored($0) }, events: [])
        return staleCalendars(in: kept, range: range, now: now, name: name)
    }

    /// Text beside the menu bar icon. Nothing when no invitation is waiting.
    static func menuBarText(waiting: Int) -> String? {
        waiting <= 0 ? nil : (waiting > 99 ? "99+" : "\(waiting)")
    }
}

extension InboxModel {
    /// Invitations waiting for an answer: the Needs RSVP filter, counted as the Inbox does.
    var waiting: Int { board?.count(.needsRSVP) ?? 0 }
    var overlaps: Int { board?.count(.conflicts) ?? 0 }
    var changes: Int { board?.count(.changed) ?? 0 }
}
