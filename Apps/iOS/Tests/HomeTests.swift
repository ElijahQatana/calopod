import CalopodDomain
import CalopodSnapshot
import Foundation
import Testing

@testable import Calopod

@MainActor
struct HomeSummaryTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    // 2027-01-01 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_798_761_600 + 10 * 3600)

    private func at(_ hour: Double) -> Date { now.addingTimeInterval((hour - 10) * 3600) }

    private func event(_ id: String, _ start: Double, _ end: Double, calendar: String = "work", allDay: Bool = false, response: EventResponseState = .accepted)
        -> CalendarEvent
    {
        CalendarEvent(id: id, calendarID: calendar, title: id, startsAt: at(start), endsAt: at(end), isAllDay: allDay, response: response)
    }

    private func item(_ id: String, _ reasons: [InboxReason]) -> InboxItem {
        InboxItem(id: id, reasons: reasons, title: id, startsAt: at(12), endsAt: at(13), calendarID: "work", response: .needsResponse)
    }

    private func summary(
        events: [CalendarEvent] = [], inbox: [InboxItem] = [], issues: [SyncIssue] = [], age: TimeInterval = 300, hidden: Set<String> = [],
        availability: [AvailabilityDay] = []
    ) -> HomeSummary {
        let snapshot = Snapshot(
            publishedAt: now.addingTimeInterval(-age), inbox: inbox, availability: availability,
            days: events.isEmpty ? [] : [CalendarDay(day: "2027-01-01", timeZoneIdentifier: "UTC", events: events)],
            calendars: (1...4).map { CalendarEntry(id: "c\($0)", name: "Cal \($0)", colorIndex: $0) } + [CalendarEntry(id: "work", name: "Work", colorIndex: 0)],
            status: SyncStatus(lastSyncAt: now.addingTimeInterval(-age), issues: issues))
        return HomeSummary(context: SnapshotContext(snapshot: snapshot, offline: false, now: now), hidden: hidden, calendar: utc)
    }

    @Test func countsWhatNeedsYou() {
        let found = summary(inbox: [item("a", [.needsRSVP, .conflict]), item("b", [.maybe]), item("c", [.unreadChange]), item("d", [.conflict])])
        #expect((found.invitations, found.overlaps, found.changes) == (1, 2, 1))
    }

    @Test func nextUpIsTodaysComingEventsOnly() {
        let found = summary(events: [
            event("done", 8, 9), event("now", 9.5, 10.5), event("soon", 10.0 + 1.0 / 60, 11), event("lunch", 12, 13), event("late", 22, 23),
            event("tomorrow", 26, 27), event("all-day", 0, 24, allDay: true), event("no", 14, 15, response: .declined),
        ])
        #expect(found.next.map(\.event.id) == ["now", "soon", "lunch"])
        #expect(found.next.map(\.chip) == ["Now", "In 1 min", "In 2 hr"])
        #expect(found.moreToday == 1)
        #expect(found.hasCalendars)
    }

    @Test func hiddenCalendarsLeaveNextUp() {
        let found = summary(events: [event("a", 11, 12, calendar: "family"), event("b", 12, 13)], hidden: ["family"])
        #expect(found.next.map(\.event.id) == ["b"])
    }

    @Test func chipsSayHowSoon() {
        #expect(HomeSummary.chip(for: event("a", 10 + 2.0 / 60, 11), now: now) == "In 2 min")
        #expect(HomeSummary.chip(for: event("a", 12 + 19.0 / 60, 13), now: now) == "In 2 hr 19 min")
    }

    @Test func noCalendarChosenIsNotAnEmptyDay() {
        let found = summary()
        #expect(!found.hasCalendars && found.next.isEmpty)
    }

    @Test func syncStates() {
        #expect(summary().sync == .inSync)
        #expect(summary(issues: [SyncIssue(kind: .stale, calendarID: "c1")]).sync == .inSync)
        #expect(summary(issues: [SyncIssue(kind: .failed)]).sync == .didNotFinish)
        #expect(summary(age: 3 * 3600).sync == .behind)
        #expect(summary(issues: [SyncIssue(kind: .failed)], age: 3 * 3600).sync == .didNotFinish)
    }

    @Test func oldDataDropsTheCountdown() {
        let found = summary(events: [event("a", 11, 12)], age: 3 * 3600)
        #expect(found.next.map(\.event.id) == ["a"] && found.next[0].chip == nil)
    }

    private func day(free: [(Double, Double)]?) -> AvailabilityDay {
        func span(_ from: Double, _ to: Double) -> BusyInterval { BusyInterval(start: at(from), end: at(to)) }
        return AvailabilityDay(
            day: "2027-01-01", timeZoneIdentifier: "UTC", busy: [], working: span(9, 17),
            free: free.map { $0.map(span) }, overlaps: 0, status: free == nil ? nil : .mostlyFree)
    }

    private func glance(_ found: HomeSummary) -> String? { found.glance?.text(locale: Locale(identifier: "en_GB")) }

    @Test func glanceNamesTheNextFreeStretchAndMeetingsLeft() {
        let events = [event("a", 11, 12), event("b", 14, 15), event("done", 8, 9)]
        #expect(glance(summary(events: events, availability: [day(free: [(9, 10), (12, 14), (15, 17)])]))
            == "Next free: 12:00 to 14:00 · 2 meetings left today")
        #expect(glance(summary(events: events, availability: [day(free: [(9, 10.5), (12, 14)])])) == "Free until 10:30 · 2 meetings left today")
        #expect(glance(summary(events: [], availability: [day(free: [(9, 10.1), (10.2, 17)])])) == "Next free: 10:12 to 17:00")
    }

    @Test func glanceSaysNothingItCannotKnow() {
        let events = [event("a", 11, 12)]
        #expect(glance(summary(events: events)) == "1 meeting left today")
        #expect(glance(summary(events: events, availability: [day(free: nil)])) == "1 meeting left today")
        #expect(glance(summary(events: events, age: 3 * 3600, availability: [day(free: [(12, 14)])])) == nil)
        #expect(glance(summary(availability: [day(free: [(12, 14)])])) == "Next free: 12:00 to 14:00")
        #expect(glance(summary()) == nil)
        #expect(glance(summary(events: [event("done", 8, 9)], availability: [day(free: [])])) == "No meetings left today")
    }
}

struct CopyExclusionTests {
    @Test func copiesNeverReachNextUpOrReminders() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = FixtureReader.snapshot(publishedAt: now, now: now)
        let start = now.addingTimeInterval(1800)
        let copy = CalendarEvent(
            id: "copy:busy:x", calendarID: "work", title: nil, startsAt: start, endsAt: start.addingTimeInterval(1800),
            response: .unknown, copy: true)
        snapshot.days = [CalendarDay(day: "2027-01-15", timeZoneIdentifier: "UTC", events: [copy])]
        let home = HomeSummary(context: SnapshotContext(snapshot: snapshot, offline: false, now: now), hidden: [])
        #expect(home.next.isEmpty && home.moreToday == 0)
        #expect(ReminderPlan.plan(snapshot: snapshot, now: now).isEmpty)
    }
}
