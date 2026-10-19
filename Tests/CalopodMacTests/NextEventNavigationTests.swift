import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class NextEventNavigationTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func event(_ id: String, day: Int, calendarID: String = "work", isCopy: Bool = false) -> ScheduleEvent {
        let start = utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 7))!
        return ScheduleEvent(
            id: id, calendarID: calendarID, title: "Planning", startsAt: start, endsAt: start.addingTimeInterval(3600),
            response: .accepted, isCopy: isCopy, overlaps: [], change: .none)
    }

    private func model(_ events: [ScheduleEvent], name: String = #function) async throws -> CalendarModel {
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        suite.removePersistentDomain(forName: name)
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9))!
        let schedule = CalendarSchedule(calendars: [], events: events)
        let model = CalendarModel(calendar: utc, now: { now }, defaults: suite, aliases: .isolated(), load: { schedule })
        await model.reload()
        return model
    }

    func testChoosingARowOpensCalendarOnItsWeekAndSelectsIt() async throws {
        let target = event("e1", day: 21)
        let model = try await model([target])
        let navigation = AppNavigation(environment: [:])

        navigation.openCalendar(showing: target, in: model)

        XCTAssertEqual(navigation.selection, .calendar)
        XCTAssertTrue(model.days.contains { utc.isDate($0, inSameDayAs: target.startsAt) })
        XCTAssertEqual(model.selected, target)
        XCTAssertNil(model.openNotice)
    }

    func testChoosingARowShowsItsHiddenCalendarAgain() async throws {
        let target = event("e1", day: 21)
        let model = try await model([target])
        model.toggle("work")

        model.open(target)

        XCTAssertFalse(model.hidden.contains("work"))
        XCTAssertEqual(model.selected, target)
    }

    func testAMissingEventOrACopyOpensTheDayWithAMessage() async throws {
        let copy = event("c1", day: 22, isCopy: true)
        let model = try await model([copy])
        let navigation = AppNavigation(environment: [:])
        let gone = event("gone", day: 23)

        navigation.openCalendar(showing: gone, in: model)
        XCTAssertEqual(navigation.selection, .calendar)
        XCTAssertTrue(model.days.contains { utc.isDate($0, inSameDayAs: gone.startsAt) })
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.openNotice, CalendarModel.missingNotice)

        navigation.openCalendar(showing: copy, in: model)
        XCTAssertNil(model.selected)
        XCTAssertEqual(model.openNotice, CalendarModel.copyNotice)

        model.step(1)
        XCTAssertNil(model.openNotice)
    }

    func testTheRowLabelNamesTheEventAndTime() {
        let label = NextUpRow.label(for: event("e1", day: 21))
        XCTAssertTrue(label.hasPrefix("Open Planning, "), label)
    }
}
