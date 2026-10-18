import CalopodStore
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class SetupModelTests: XCTestCase {
    private func make() throws -> (SetupModel, LocalStateRepository, CalendarColors) {
        let state = LocalStateRepository(database: try .inMemory())
        try state.saveConnection(StoredConnection(
            id: "mac", configurationID: "default", provider: "eventkit", displayLabel: "Calendars on this Mac", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "mac", bindings: ["work", "main", "busy"].map {
            StoredCalendarBinding(id: $0, connectionID: "mac", providerCalendarID: $0, displayLabel: $0.capitalized,
                                  isSelected: false, isReadOnly: false)
        })
        let suite = "SetupModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let colors = CalendarColors(defaults: defaults, state: state)
        let model = SetupModel(
            service: SetupService(makeRepository: { state }), aliases: CalendarAliases(defaults: defaults, state: state), colors: colors)
        return (model, state, colors)
    }

    func testReloadListsCalendarsAndGivesEachAColor() async throws {
        let (model, _, colors) = try make()
        await model.reload()
        XCTAssertEqual(model.snapshot?.connections.first?.calendars.count, 3)
        XCTAssertTrue(model.selectedCalendars.isEmpty)
        XCTAssertEqual(Set(model.targetCandidates.map(\.id)), ["work", "main", "busy"])
        XCTAssertEqual(Set(["work", "main", "busy"].map { colors.color(for: $0).id }).count, 3)
    }

    func testSelectingACalendarMakesItASourceNotATarget() async throws {
        let (model, _, _) = try make()
        await model.reload()
        await model.setSelected("work", true)
        XCTAssertEqual(model.selectedCalendars.map(\.id), ["work"])
        XCTAssertFalse(model.targetCandidates.map(\.id).contains("work"))
        XCTAssertNil(model.notice)
    }

    func testQuickSetupMakesTwoArmsAndMarksTheirCalendarsInUse() async throws {
        let (model, _, _) = try make()
        await model.reload()
        await model.setSelected("work", true)
        await model.setUpTwoArms(sources: ["work"], fullDetailsTarget: "main", busyTarget: "busy")
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.fullDetailsArm.map(model.targetName), "Main")
        XCTAssertEqual(model.busyArm.map(model.targetName), "Busy")
        XCTAssertEqual(model.armCalendarIDs, ["work", "main", "busy"])
    }

    func testAFailedChangeShowsANoticeThatTheNextChangeClears() async throws {
        let (model, _, _) = try make()
        await model.reload()
        await model.setSelected("missing", true)
        XCTAssertNotNil(model.notice)
        XCTAssertFalse(model.isBusy)

        await model.setSelected("work", true)
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.selectedCalendars.map(\.id), ["work"])
    }

    func testALoadErrorGoesAwayOnceALoadWorks() async throws {
        struct Down: Error {}
        final class Flag: @unchecked Sendable { var failing = true }
        let flag = Flag()
        let state = LocalStateRepository(database: try .inMemory())
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SetupModelTests-load"))
        defaults.removePersistentDomain(forName: "SetupModelTests-load")
        let model = SetupModel(
            service: SetupService(makeRepository: { if flag.failing { throw Down() } else { return state } }),
            aliases: CalendarAliases(defaults: defaults, state: state), colors: CalendarColors(defaults: defaults, state: nil))
        await model.reload()
        XCTAssertNotNil(model.notice)
        flag.failing = false
        await model.reload()
        XCTAssertNil(model.notice)
        XCTAssertNotNil(model.snapshot)
    }
}
