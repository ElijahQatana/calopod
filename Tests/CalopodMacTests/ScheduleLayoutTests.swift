import CalopodCommands
import XCTest

@testable import CalopodMac

final class ScheduleLayoutTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func event(
        _ id: String, _ start: Date, _ end: Date, response: ScheduleResponse = .accepted,
        copy: Bool = false, overlaps: [String] = [], changed: Bool = false
    ) -> ScheduleEvent {
        ScheduleEvent(
            id: id, calendarID: "work", title: id, startsAt: start, endsAt: end, response: response,
            isCopy: copy, overlaps: overlaps, changedSinceViewed: changed)
    }

    func testWeekStartsOnFirstWeekdayEvenFromSunday() {
        let sunday = date(18, 12)
        let days = ScheduleLayout.weekDays(containing: sunday, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, date(12, 0))
        XCTAssertEqual(days.last, date(18, 0))
    }

    func testOverlappingEventsShareColumnsAndLaterOnesStartOver() {
        let events = [
            event("a", date(14, 10), date(14, 11)),
            event("b", date(14, 10, 30), date(14, 11, 30)),
            event("c", date(14, 10, 45), date(14, 11, 15)),
            event("d", date(14, 13), date(14, 14)),
        ]
        let placed = Dictionary(
            uniqueKeysWithValues: ScheduleLayout.placements(events, on: date(14, 0), calendar: calendar).map { ($0.id, $0) })
        XCTAssertEqual([placed["a"]?.column, placed["b"]?.column, placed["c"]?.column], [0, 1, 2])
        XCTAssertEqual(placed["a"]?.columns, 3)
        XCTAssertEqual(placed["d"]?.columns, 1)
        XCTAssertEqual(placed["d"]?.column, 0)
    }

    func testShortEventKeepsRoomAndNeighborsMoveAside() {
        let events = [
            event("short", date(14, 9), date(14, 9, 5)),
            event("next", date(14, 9, 20), date(14, 10)),
        ]
        let placed = ScheduleLayout.placements(events, on: date(14, 0), calendar: calendar)
        XCTAssertEqual(placed.first { $0.id == "short" }?.height, 30)
        XCTAssertEqual(Set(placed.map(\.column)), [0, 1])
    }

    func testEventPastMidnightIsClippedToEachDay() {
        let late = event("late", date(14, 22), date(15, 2))
        let first = ScheduleLayout.placements([late], on: date(14, 0), calendar: calendar)
        let second = ScheduleLayout.placements([late], on: date(15, 0), calendar: calendar)
        XCTAssertEqual(first.first?.top, 22 * 60)
        XCTAssertEqual((first.first?.top ?? 0) + (first.first?.height ?? 0), 1440)
        XCTAssertEqual(second.first?.top, 0)
        XCTAssertEqual(second.first?.height, 120)
        XCTAssertTrue(ScheduleLayout.placements([late], on: date(16, 0), calendar: calendar).isEmpty)
    }

    func testTreatmentChoice() {
        XCTAssertEqual(ScheduleLayout.treatment(for: event("a", date(14, 9), date(14, 10))), .tinted)
        XCTAssertEqual(ScheduleLayout.treatment(for: event("b", date(14, 9), date(14, 10), response: .organizer)), .tinted)
        XCTAssertEqual(ScheduleLayout.treatment(for: event("c", date(14, 9), date(14, 10), response: .needsResponse)), .needsRSVP)
        XCTAssertEqual(ScheduleLayout.treatment(for: event("d", date(14, 9), date(14, 10), response: .declined)), .declined)
        // A copy stays a copy and never shows an overlap ring or change dot.
        let copy = event("e", date(14, 9), date(14, 10), response: .needsResponse, copy: true, overlaps: ["x"], changed: true)
        XCTAssertEqual(ScheduleLayout.treatment(for: copy), .copy)
        XCTAssertFalse(ScheduleLayout.showsOverlap(copy))
        XCTAssertFalse(ScheduleLayout.showsChange(copy))
        let flagged = event("f", date(14, 9), date(14, 10), overlaps: ["x"], changed: true)
        XCTAssertTrue(ScheduleLayout.showsOverlap(flagged))
        XCTAssertTrue(ScheduleLayout.showsChange(flagged))
    }

    func testNoticesCoverStaleUnreadAndShortCoverageButNotHiddenCalendars() {
        let range = date(12, 0)..<date(19, 0)
        let calendars = [
            ScheduleCalendar(id: "a", name: "Work", account: "Example", provider: "google", freshness: .stale(since: date(14, 6))),
            ScheduleCalendar(id: "b", name: "Team", account: "Example", provider: "google", freshness: .unread),
            ScheduleCalendar(
                id: "c", name: "Home", account: "Example", provider: "google",
                coverage: date(1, 0)...date(15, 0)),
            ScheduleCalendar(
                id: "d", name: "Family", account: "Example", provider: "google",
                coverage: date(1, 0)...date(30, 0)),
        ]
        let all = ScheduleLayout.notices(calendars: calendars, hidden: [], range: range, now: date(14, 8))
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all[0].contains("Work") && all[0].contains("2 hr ago"))
        let some = ScheduleLayout.notices(calendars: calendars, hidden: ["a", "b"], range: range, now: date(14, 8))
        XCTAssertEqual(some.count, 1)
        XCTAssertTrue(some[0].contains("Home"))
    }
}
