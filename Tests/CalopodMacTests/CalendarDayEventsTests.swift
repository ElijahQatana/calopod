import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class CalendarDayEventsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private lazy var start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!

    private func event(_ id: String, calendarID: String = "work", copy: Bool = false, allDay: Bool = false) -> ScheduleEvent {
        ScheduleEvent(
            id: id, calendarID: calendarID, title: id, startsAt: start, endsAt: start.addingTimeInterval(3600),
            isAllDay: allDay, response: .accepted, isCopy: copy, overlaps: [], change: .none)
    }

    private func model(_ events: [ScheduleEvent]) async throws -> CalendarModel {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "CalendarDayEventsTests"))
        suite.removePersistentDomain(forName: "CalendarDayEventsTests")
        let schedule = CalendarSchedule(calendars: [], events: events)
        let model = CalendarModel(
            calendar: calendar, now: { self.start }, defaults: suite, aliases: CalendarAliases(defaults: suite), load: { schedule })
        await model.reload()
        return model
    }

    func testDayEventsFollowFiltersAndMatchTheLayout() async throws {
        let model = try await model([event("a"), event("b", calendarID: "home"), event("c", copy: true), event("d", allDay: true)])
        let day = calendar.startOfDay(for: start)

        XCTAssertEqual(model.dayEvents(day).placements, ScheduleLayout.placements(model.events, on: day, calendar: calendar))
        XCTAssertEqual(model.dayEvents(day).allDay.map(\.id), ["d"])
        XCTAssertEqual(model.dayEvents(day).placements.count, 3)

        model.showCopies = false
        XCTAssertEqual(model.dayEvents(day).placements.map(\.event.id).sorted(), ["a", "b"])

        model.toggle("home")
        XCTAssertEqual(model.dayEvents(day).placements.map(\.event.id), ["a"])

        model.toggle("home")
        XCTAssertEqual(model.dayEvents(day).placements.count, 2)
    }

    func testSelectingDoesNotChangeDayEvents() async throws {
        let model = try await model([event("a"), event("b")])
        let day = calendar.startOfDay(for: start)
        let before = model.dayEvents(day)
        model.selectedID = "a"
        XCTAssertEqual(model.dayEvents(day), before)
    }
}
