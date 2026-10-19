import CalopodCommands
@testable import CalopodStore
import XCTest

@testable import CalopodMac

@MainActor
final class CalendarViewHiddenTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private lazy var start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 10))!
    private let roles = CalendarRoles(sources: ["work", "hub"], destinations: ["hub", "home"])

    private func event(_ calendarID: String, copy: Bool = false) -> ScheduleEvent {
        ScheduleEvent(
            id: calendarID + (copy ? "-copy" : ""), calendarID: calendarID, title: calendarID, startsAt: start,
            endsAt: start.addingTimeInterval(3600), response: .accepted, isCopy: copy)
    }

    private func model(
        state: LocalStateRepository?, defaults: UserDefaults, ids: [String] = ["work", "hub", "home"]
    ) async -> CalendarModel {
        let schedule = CalendarSchedule(
            calendars: ids.map { ScheduleCalendar(id: $0, name: $0, account: "x", provider: "google") },
            events: ids.map { event($0) }, roles: roles)
        let model = CalendarModel(
            calendar: calendar, now: { self.start }, defaults: defaults, aliases: .isolated(), state: state, load: { schedule })
        await model.reload()
        return model
    }

    private func suite() -> UserDefaults { UserDefaults(suiteName: "hidden-\(UUID().uuidString)")! }

    func testHidingInOneModeLeavesTheOthersAlone() async throws {
        let model = await model(state: LocalStateRepository(database: try .inMemory()), defaults: suite())
        model.toggle("hub")
        XCTAssertEqual(Set(model.events.map(\.id)), ["work", "home"])
        model.viewMode = .sources
        XCTAssertTrue(model.hidden.isEmpty)
        XCTAssertEqual(Set(model.events.map(\.id)), ["work", "hub"])
        model.toggle("work")
        model.viewMode = .destinations
        XCTAssertTrue(model.hidden.isEmpty)
        XCTAssertEqual(Set(model.events.map(\.id)), ["hub", "home"])
        model.viewMode = .all
        XCTAssertEqual(model.hidden, ["hub"])
        model.viewMode = .sources
        XCTAssertEqual(model.hidden, ["work"])
    }

    func testEachModeKeepsItsHiddenCalendarsAndCopiesAcrossRelaunch() async throws {
        let state = LocalStateRepository(database: try .inMemory())
        let defaults = suite()
        let first = await model(state: state, defaults: defaults)
        first.toggle("home")
        first.showCopies = true
        first.viewMode = .destinations
        first.toggle("hub")
        first.showCopies = false
        first.viewMode = .sources

        let again = await model(state: state, defaults: defaults)
        XCTAssertEqual(again.viewMode, .sources)
        XCTAssertTrue(again.hidden.isEmpty)
        again.viewMode = .all
        XCTAssertEqual(again.hidden, ["home"])
        XCTAssertTrue(again.showCopies)
        again.viewMode = .destinations
        XCTAssertEqual(again.hidden, ["hub"])
        XCTAssertFalse(again.showCopies)
    }

    func testCalendarsNewToAModeAreShownAndOthersKeepTheirState() async throws {
        let state = LocalStateRepository(database: try .inMemory())
        let defaults = suite()
        let first = await model(state: state, defaults: defaults)
        first.toggle("work")
        first.viewMode = .destinations
        XCTAssertFalse(first.chipCalendars.map(\.id).contains("work"))
        first.toggle("home")

        // "work" is now offered in Destinations as well; it was never hidden there.
        let wider = CalendarSchedule(
            calendars: ["work", "hub", "home"].map { ScheduleCalendar(id: $0, name: $0, account: "x", provider: "google") },
            events: ["work", "hub", "home"].map { event($0) },
            roles: CalendarRoles(sources: ["hub"], destinations: ["work", "hub", "home"]))
        let again = CalendarModel(
            calendar: calendar, now: { self.start }, defaults: defaults, aliases: .isolated(), state: state, load: { wider })
        await again.reload()
        XCTAssertEqual(Set(again.events.map(\.id)), ["work", "hub"])
        again.viewMode = .all
        XCTAssertEqual(again.hidden, ["work"], "hidden state in a mode that did not offer it is kept")
        XCTAssertEqual(try state.hiddenCalendars(view: "destinations"), ["home"])
    }

    func testWithoutStateEachModeStillKeepsItsOwnForTheSession() async throws {
        let model = await model(state: nil, defaults: suite())
        model.toggle("hub")
        model.viewMode = .sources
        XCTAssertTrue(model.hidden.isEmpty)
        model.viewMode = .all
        XCTAssertEqual(model.hidden, ["hub"])
    }

    func testChangesFromTheCommandLineArePickedUpOnReload() async throws {
        let state = LocalStateRepository(database: try .inMemory())
        let model = await model(state: state, defaults: suite())
        try state.setCalendarHidden(true, view: "all", calendarID: "home")
        await model.reload()
        XCTAssertEqual(model.hidden, ["home"])
        XCTAssertEqual(Set(model.events.map(\.id)), ["work", "hub"])
    }

    func testAModeOrChipChangeRecomputesTheDayLists() async throws {
        let model = await model(state: nil, defaults: suite())
        let day = calendar.startOfDay(for: start)
        XCTAssertEqual(model.dayEvents(day).placements.count, 3)
        model.toggle("work")
        XCTAssertEqual(model.dayEvents(day).placements.count, 2)
        model.viewMode = .sources
        XCTAssertEqual(Set(model.dayEvents(day).placements.map(\.event.id)), ["work", "hub"])
        model.viewMode = .all
        XCTAssertEqual(model.dayEvents(day).placements.count, 2)
        model.selectedID = "hub"
        XCTAssertEqual(model.dayEvents(day).placements.count, 2)
    }
}
