import CalopodCommands
import XCTest

@testable import CalopodMac

@MainActor
final class CalendarViewModeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private lazy var start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!

    private func event(_ id: String, on calendarID: String, copy: Bool = false) -> ScheduleEvent {
        ScheduleEvent(
            id: id, calendarID: calendarID, title: id, startsAt: start, endsAt: start.addingTimeInterval(3600),
            response: .accepted, isCopy: copy)
    }

    private func defaults() throws -> UserDefaults {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "CalendarViewModeTests"))
        suite.removePersistentDomain(forName: "CalendarViewModeTests")
        return suite
    }

    /// work copies to hub, hub copies to home; "loose" is in no arm.
    private func model(defaults: UserDefaults? = nil) async throws -> CalendarModel {
        let cals = ["work", "hub", "home", "loose"].map { ScheduleCalendar(id: $0, name: $0, account: "x", provider: "google") }
        let schedule = CalendarSchedule(
            calendars: cals,
            events: [
                event("w", on: "work"), event("h", on: "hub"), event("o", on: "home"), event("l", on: "loose"),
                event("copy-hub", on: "hub", copy: true), event("copy-home", on: "home", copy: true),
            ],
            roles: CalendarRoles(sources: ["work", "hub"], destinations: ["hub", "home"]))
        let model = CalendarModel(
            calendar: calendar, now: { self.start }, defaults: try defaults ?? self.defaults(),
            aliases: CalendarAliases(defaults: try self.defaults(), state: nil), load: { schedule })
        await model.reload()
        return model
    }

    func testModesChooseCalendarsChipsAndCopies() async throws {
        let model = try await model()
        XCTAssertEqual(Set(model.events.map(\.id)), ["w", "h", "o", "l", "copy-hub", "copy-home"])

        model.viewMode = .sources
        XCTAssertEqual(model.chipCalendars.map(\.id), ["work", "hub"])
        XCTAssertEqual(Set(model.events.map(\.id)), ["w", "h"], "Sources never draws copies")

        model.viewMode = .destinations
        XCTAssertEqual(model.chipCalendars.map(\.id), ["hub", "home"])
        XCTAssertEqual(Set(model.events.map(\.id)), ["h", "o", "copy-hub", "copy-home"])
    }

    func testDestinationsDrawsCopiesEvenWhenTheChipIsOff() async throws {
        let model = try await model()
        model.showCopies = false
        XCTAssertFalse(model.events.contains { $0.isCopy })
        model.viewMode = .destinations
        XCTAssertEqual(model.events.filter(\.isCopy).count, 2)
        model.viewMode = .all
        XCTAssertFalse(model.events.contains { $0.isCopy }, "The chip choice comes back in All")
    }

    func testHiddenStateSurvivesSwitchingModes() async throws {
        let model = try await model()
        model.viewMode = .sources
        model.toggle("work")
        model.viewMode = .destinations
        XCTAssertEqual(Set(model.events.map(\.calendarID)), ["hub", "home"])
        model.viewMode = .sources
        XCTAssertEqual(Set(model.events.map(\.id)), ["h"])
        XCTAssertTrue(model.hidden.contains("work"))
    }

    func testSelectionClearsOnlyWhenItLeavesTheView() async throws {
        let model = try await model()
        model.selectedID = "h"
        model.viewMode = .sources
        XCTAssertEqual(model.selectedID, "h")
        model.selectedID = "w"
        model.viewMode = .destinations
        XCTAssertNil(model.selectedID)
    }

    func testOpeningAnEventOutsideTheModeShowsAll() async throws {
        let model = try await model()
        model.viewMode = .sources
        XCTAssertTrue(model.open(event("o", on: "home")))
        XCTAssertEqual(model.viewMode, .all)
        XCTAssertEqual(model.selectedID, "o")
    }

    func testModeIsRemembered() async throws {
        let store = try defaults()
        let model = try await model(defaults: store)
        model.viewMode = .destinations
        let again = CalendarModel(defaults: store, load: { CalendarSchedule(calendars: [], events: []) })
        XCTAssertEqual(again.viewMode, .destinations)
    }
}
