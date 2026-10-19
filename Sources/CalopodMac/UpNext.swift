import CalopodCommands
import CalopodDomain
import CalopodSnapshot
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

    static func today(in schedule: CalendarSchedule?, now: Date, calendar: Calendar = .current, ignored: (String) -> Bool = { _ in false }) -> [ScheduleEvent] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        return events(in: schedule, from: now, before: end).filter { isCandidate($0, ignored: ignored) }
    }

    /// Whether an event can be the next one: a real event, answered other than No, on a shown calendar.
    static func isCandidate(_ event: ScheduleEvent, ignored: (String) -> Bool) -> Bool {
        !event.isCopy && ReminderEligibility.isEligible(isAllDay: event.isAllDay, isDeclined: event.response == .declined)
            && !ignored(event.calendarID)
    }

    /// What the Next card shows. The same rule picks the event for `calopod join`.
    struct Next: Equatable {
        struct Line: Equatable {
            let event: ScheduleEvent
            let role: NextUpSelection.Role
        }
        var primary: Line?
        var secondary: Line?
        var alsoRunning: [ScheduleEvent] = []
        /// When the choice can change next, so the card can refresh then.
        var changesAt: Date?
    }

    static func next(
        in schedule: CalendarSchedule?, now: Date, ignored: (String) -> Bool = { _ in false }
    ) -> Next {
        let candidates = events(in: schedule, from: now).filter { isCandidate($0, ignored: ignored) }
        let entries = candidates.map { NextUpEntry(id: $0.id, startsAt: $0.startsAt, endsAt: $0.endsAt) }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let chosen = NextUpSelection.select(entries, now: now)
        func line(_ line: NextUpSelection.Line?) -> Next.Line? {
            line.flatMap { l in byID[l.event.id].map { Next.Line(event: $0, role: l.role) } }
        }
        return Next(
            primary: line(chosen.primary), secondary: line(chosen.secondary),
            alsoRunning: chosen.alsoRunning.compactMap { byID[$0.id] },
            changesAt: NextUpSelection.nextChange(entries, after: now))
    }

    /// Calendars whose copy is old or missing, so the list above may be incomplete. With a range,
    /// a calendar read only part of the way across it counts too.
    static func staleCalendars(
        in schedule: CalendarSchedule?, range: Range<Date>? = nil, now: Date = Date(),
        name: (ScheduleCalendar) -> String
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
        ignored: (ScheduleCalendar) -> Bool = { _ in false }, name: (ScheduleCalendar) -> String
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

/// Join on the menu bar Next card and the Overview rows. Both read it here so they cannot disagree.
enum JoinOffer {
    /// The link to offer: only a real event that has not ended. Copies never carry one.
    static func link(for event: ScheduleEvent, now: Date = Date()) -> MeetingLink? {
        guard !event.isCopy, event.endsAt > now else { return nil }
        return event.meeting
    }

    static func isProminent(_ event: ScheduleEvent, now: Date = Date()) -> Bool {
        MeetingLink.isImminent(startsAt: event.startsAt, endsAt: event.endsAt, now: now)
    }

    /// Opens the meeting. Returns the text for a dismissable banner when it did not open.
    static func join(_ link: MeetingLink, using joiner: any MeetingJoining) async -> String? {
        await joiner.join(link) == .failed ? MeetingJoinText.failed : nil
    }
}
