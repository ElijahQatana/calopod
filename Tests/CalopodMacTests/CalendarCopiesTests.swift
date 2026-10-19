import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class CalendarCopiesTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private lazy var start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!

    private func event(_ id: String, copy: Bool) -> ScheduleEvent {
        return ScheduleEvent(
            id: id, calendarID: "work", title: id, startsAt: start, endsAt: start.addingTimeInterval(3600),
            response: .accepted, isCopy: copy, overlaps: [], change: .none)
    }

    private func defaults() throws -> UserDefaults {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "CalendarCopiesTests"))
        suite.removePersistentDomain(forName: "CalendarCopiesTests")
        return suite
    }

    func testHiddenCopiesLeaveTheLayoutAndFreeTheColumns() async throws {
        let schedule = CalendarSchedule(calendars: [], events: [event("a", copy: false), event("a-busy", copy: true)])
        let model = CalendarModel(calendar: calendar, now: { self.start }, defaults: try defaults(), aliases: .isolated(), load: { schedule })
        await model.reload()
        model.showCopies = true
        let day = calendar.startOfDay(for: model.anchor)

        let shown = ScheduleLayout.placements(model.events, on: day, calendar: calendar)
        XCTAssertEqual(shown.map(\.columns), [2, 2])

        model.showCopies = false
        let hidden = ScheduleLayout.placements(model.events, on: day, calendar: calendar)
        XCTAssertEqual(hidden.map(\.event.id), ["a"])
        XCTAssertEqual(hidden.map(\.columns), [1])
    }

    func testHidingCopiesClosesAnOpenCopyOnly() async throws {
        let schedule = CalendarSchedule(calendars: [], events: [event("a", copy: false), event("a-busy", copy: true)])
        let model = CalendarModel(calendar: calendar, now: { self.start }, defaults: try defaults(), aliases: .isolated(), load: { schedule })
        await model.reload()
        model.showCopies = true

        model.selectedID = "a"
        model.showCopies = false
        XCTAssertEqual(model.selectedID, "a")

        model.showCopies = true
        model.selectedID = "a-busy"
        model.showCopies = false
        XCTAssertNil(model.selectedID)
    }

    func testCopiesAreOffByDefaultAndTheChoiceIsRemembered() throws {
        let store = try defaults()
        XCTAssertFalse(CalendarModel(defaults: store, aliases: .isolated(), load: { CalendarSchedule(calendars: [], events: []) }).showCopies)
        CalendarModel(defaults: store, aliases: .isolated(), load: { CalendarSchedule(calendars: [], events: []) }).showCopies = true
        XCTAssertTrue(CalendarModel(defaults: store, aliases: .isolated(), load: { CalendarSchedule(calendars: [], events: []) }).showCopies)
    }
}
