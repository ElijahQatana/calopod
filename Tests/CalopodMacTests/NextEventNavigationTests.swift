import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class NextEventNavigationTests: XCTestCase {
    func testChoosingTheNextEventOpensItsDayAndSelectsIt() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 7))!
        let event = ScheduleEvent(
            id: "e1", calendarID: "work", title: "Planning", startsAt: start, endsAt: start.addingTimeInterval(3600),
            response: .accepted, isCopy: false, overlaps: [], change: .none)
        let suite = try XCTUnwrap(UserDefaults(suiteName: "NextEventNavigationTests"))
        suite.removePersistentDomain(forName: "NextEventNavigationTests")
        let schedule = CalendarSchedule(calendars: [], events: [event])
        let model = CalendarModel(calendar: calendar, now: { now }, defaults: suite, load: { schedule })
        await model.reload()
        let navigation = AppNavigation(environment: [:])

        model.show(event)
        navigation.selection = .calendar

        XCTAssertEqual(navigation.selection, .calendar)
        XCTAssertTrue(model.days.contains { calendar.isDate($0, inSameDayAs: start) })
        XCTAssertEqual(model.selected, event)
    }
}
