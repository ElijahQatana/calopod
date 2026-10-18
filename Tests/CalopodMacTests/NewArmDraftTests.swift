import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class NewArmDraftTests: XCTestCase {
    private func calendar(_ id: String, selected: Bool = true, readOnly: Bool = false) -> SetupCalendar {
        SetupCalendar(id: id, name: id.capitalized, sourceLabel: nil, isSelected: selected, isReadOnly: readOnly, providerColor: nil)
    }

    private func groups(ignoring ignored: [String] = []) -> [ArmCalendarGroup] {
        let aliases = CalendarAliases(defaults: UserDefaults(suiteName: "arm-draft-\(UUID().uuidString)")!, state: nil)
        ignored.forEach { aliases.setIgnored(true, for: $0) }
        let connection = SetupConnection(
            id: "c1", provider: "google", label: "me@example.com", isEnabled: true,
            calendars: [calendar("work"), calendar("home"), calendar("holidays", readOnly: true), calendar("old", selected: false)],
            warnings: [])
        return NewArmDraft.groups(from: [connection], aliases: aliases)
    }

    func testCreateNeedsASourceAndADestination() {
        var draft = NewArmDraft()
        XCTAssertNotNil(draft.problem)
        draft.toggleSource("work")
        XCTAssertNotNil(draft.problem)
        draft.target = "home"
        XCTAssertNil(draft.problem)
        draft.target = "work"
        XCTAssertNotNil(draft.problem, "a calendar cannot copy into itself")
    }

    func testChoosingTheDestinationAsASourceClearsIt() {
        var draft = NewArmDraft()
        draft.target = "home"
        draft.toggleSource("home")
        XCTAssertNil(draft.target)
    }

    func testDestinationsAreWritableAndNeverASource() {
        var draft = NewArmDraft()
        draft.toggleSource("work")
        let ids = draft.targets(in: groups()).flatMap(\.calendars).map(\.id)
        XCTAssertEqual(ids, ["home", "old"], "writable, even if not a source, and not the chosen source")
    }

    func testIgnoredCalendarsAreNotOfferedAndSourcesMustBeChosen() {
        let all = groups(ignoring: ["home"])
        XCTAssertEqual(all.flatMap(\.calendars).map(\.id), ["work", "holidays", "old"])
        XCTAssertEqual(NewArmDraft.sources(in: all).flatMap(\.calendars).map(\.id), ["work", "holidays"])
    }

    func testBlankNameKeepsTheDefault() {
        var draft = NewArmDraft()
        draft.name = "  "
        XCTAssertNil(draft.trimmedName)
        draft.name = " Work hours "
        XCTAssertEqual(draft.trimmedName, "Work hours")
    }

    func testOnlyTheMainCalendarHasAFixedRule() {
        func arm(main: Bool) -> SetupArm {
            SetupArm(id: "a", name: "A", isMain: main, isEnabled: true, rule: .fullDetails,
                     sourceNames: ["Work"], targetName: "Home", sourceIDs: ["work"], targetID: "home")
        }
        XCTAssertFalse(arm(main: true).canChangeRule)
        XCTAssertTrue(arm(main: false).canChangeRule)
    }
}
