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

    /// Calendars whose copy is old or missing, so the list above may be incomplete.
    static func staleCalendars(in schedule: CalendarSchedule?) -> [String] {
        (schedule?.calendars ?? []).filter { $0.freshness != .current }.map(\.name)
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
