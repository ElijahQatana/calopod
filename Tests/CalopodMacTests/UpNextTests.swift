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
        XCTAssertEqual(UpNext.staleCalendars(in: schedule), ["Team"])
    }

    func testMenuBarTextDropsWhenNothingWaits() {
        XCTAssertNil(UpNext.menuBarText(waiting: 0))
        XCTAssertEqual(UpNext.menuBarText(waiting: 3), "3")
        XCTAssertEqual(UpNext.menuBarText(waiting: 250), "99+")
    }
}
