import CalopodCommands
import XCTest

@testable import CalopodMac

final class UpNextTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, at hours: Double, copy: Bool = false, allDay: Bool = false) -> ScheduleEvent {
        let start = noon.addingTimeInterval(hours * 3600)
        return ScheduleEvent(
            id: id, calendarID: "work@example.com", title: id, startsAt: start,
            endsAt: start.addingTimeInterval(1800), isAllDay: allDay, isCopy: copy)
    }

    func testNextEventSkipsPastCopiesAndAllDay() {
        let schedule = CalendarSchedule(
            calendars: [],
            events: [event("past", at: -3), event("copy", at: 0.5, copy: true), event("holiday", at: 0.5, allDay: true),
                     event("later", at: 4), event("soon", at: 1)])
        XCTAssertEqual(UpNext.events(in: schedule, from: noon).map(\.id), ["soon", "later"])
    }

    private func answered(_ id: String, at minutes: Double, _ response: ScheduleResponse, calendar: String = "work@example.com") -> ScheduleEvent {
        let start = noon.addingTimeInterval(minutes * 60)
        return ScheduleEvent(
            id: id, calendarID: calendar, title: id, startsAt: start, endsAt: start.addingTimeInterval(1800), response: response)
    }

    func testNextSkipsDeclinedAndIgnoredButCountsAMaybe() {
        let schedule = CalendarSchedule(calendars: [], events: [
            answered("declined", at: 10, .declined), answered("hidden", at: 20, .accepted, calendar: "hidden@example.com"),
            answered("maybe", at: 30, .tentative), answered("yes", at: 40, .accepted)])
        let chosen = UpNext.next(in: schedule, now: noon, ignored: { $0 == "hidden@example.com" })
        XCTAssertEqual(chosen.primary?.event.id, "maybe")
        XCTAssertEqual(chosen.secondary, nil)
        XCTAssertEqual(UpNext.today(in: schedule, now: noon, ignored: { $0 == "hidden@example.com" }).map(\.id), ["maybe", "yes"])
    }

    func testCardMovesOnTenMinutesIntoTheRunningMeeting() {
        let schedule = CalendarSchedule(calendars: [], events: [answered("run", at: -5, .accepted), answered("next", at: 25, .accepted)])
        let early = UpNext.next(in: schedule, now: noon)
        XCTAssertEqual([early.primary?.event.id, early.secondary?.event.id], ["run", "next"])
        XCTAssertEqual(early.changesAt, noon.addingTimeInterval(5 * 60))
        let late = UpNext.next(in: schedule, now: noon.addingTimeInterval(6 * 60))
        XCTAssertEqual([late.primary?.event.id, late.secondary?.event.id], ["next", "run"])
    }

    func testCardWording() {
        let schedule = CalendarSchedule(calendars: [], events: [answered("run", at: -6, .accepted), answered("next", at: 40, .accepted)])
        let early = UpNext.next(in: schedule, now: noon.addingTimeInterval(-60))
        XCTAssertEqual(NextCardText.label(for: early.primary!, now: noon), "Now, 6 min in")
        XCTAssertTrue(NextCardText.secondary(early.secondary!, also: []).hasPrefix("Next: next at "))
        let late = UpNext.next(in: schedule, now: noon.addingTimeInterval(5 * 60))
        XCTAssertEqual(NextCardText.label(for: late.primary!, now: noon.addingTimeInterval(5 * 60)), "Next, in 35 min")
        XCTAssertTrue(NextCardText.secondary(late.secondary!, also: []).hasPrefix("In run until "))
    }

    func testTodayStopsAtMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let schedule = CalendarSchedule(calendars: [], events: [event("a", at: 1), event("tomorrow", at: 30)])
        XCTAssertEqual(UpNext.today(in: schedule, now: noon, calendar: calendar).map(\.id), ["a"])
    }

    func testStaleCalendarsAreNamed() {
        let schedule = CalendarSchedule(
            calendars: [
                ScheduleCalendar(id: "a", name: "Work", account: "", provider: "google"),
                ScheduleCalendar(id: "b", name: "Team", account: "", provider: "google", freshness: .stale(since: nil)),
            ], events: [])
        XCTAssertEqual(UpNext.staleCalendars(in: schedule, name: { $0.name }), ["Team"])
    }

    func testMenuBarTextDropsWhenNothingWaits() {
        XCTAssertNil(UpNext.menuBarText(waiting: 0))
        XCTAssertEqual(UpNext.menuBarText(waiting: 3), "3")
        XCTAssertEqual(UpNext.menuBarText(waiting: 250), "99+")
    }
}
