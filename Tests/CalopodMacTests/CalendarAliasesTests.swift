import XCTest

@testable import CalopodMac

@MainActor
final class CalendarAliasesTests: XCTestCase {
    private func store() -> (CalendarAliases, UserDefaults) {
        let defaults = UserDefaults(suiteName: "aliases-\(UUID().uuidString)")!
        return (CalendarAliases(defaults: defaults), defaults)
    }

    func testAliasShowsInPlaceOfTheRealNameAndClears() {
        let (aliases, _) = store()
        XCTAssertEqual(aliases.name(for: "a", real: "Calendar"), "Calendar")
        aliases.setAlias("  Work ", for: "a", real: "Calendar")
        XCTAssertEqual(aliases.name(for: "a", real: "Calendar"), "Work")
        for blank in ["", "   ", "Calendar"] {
            aliases.setAlias("Work", for: "a", real: "Calendar")
            aliases.setAlias(blank, for: "a", real: "Calendar")
            XCTAssertNil(aliases.alias(for: "a"), "\(blank) clears")
        }
    }

    func testTwoCalendarsWithTheSameNameGetOwnAliases() {
        let (aliases, _) = store()
        aliases.setAlias("Family birthdays", for: "a", real: "Birthdays")
        XCTAssertEqual(aliases.name(for: "a", real: "Birthdays"), "Family birthdays")
        XCTAssertEqual(aliases.name(for: "b", real: "Birthdays"), "Birthdays")
    }

    func testIgnoreAndUnignore() {
        let (aliases, _) = store()
        aliases.setIgnored(true, for: "a")
        XCTAssertTrue(aliases.isIgnored("a"))
        XCTAssertFalse(aliases.isIgnored("b"))
        aliases.setIgnored(false, for: "a")
        XCTAssertFalse(aliases.isIgnored("a"))
    }

    func testSelectedOrArmCalendarsAreInUse() {
        let arms: Set = ["target"]
        XCTAssertTrue(CalendarAliases.isInUse("source", selected: true, armCalendars: arms))
        XCTAssertTrue(CalendarAliases.isInUse("target", selected: false, armCalendars: arms))
        XCTAssertFalse(CalendarAliases.isInUse("other", selected: false, armCalendars: arms))
    }

    func testChoicesSurviveARestart() {
        let (aliases, defaults) = store()
        aliases.setAlias("Work", for: "a", real: "Calendar")
        aliases.setIgnored(true, for: "b")
        aliases.setExpanded(true, for: "conn")
        let again = CalendarAliases(defaults: defaults)
        XCTAssertEqual(again.alias(for: "a"), "Work")
        XCTAssertTrue(again.isIgnored("b"))
        XCTAssertTrue(again.isExpanded("conn"))
        XCTAssertFalse(again.isExpanded("other"), "collapsed by default")
    }

    func testIgnoredCalendarsDoNotUseUpSuggestedColors() {
        let colors = CalendarColors(defaults: UserDefaults(suiteName: "colors-\(UUID().uuidString)")!)
        colors.assignMissing(to: [CalendarColorSource(id: "ignored")])
        let first = colors.color(for: "ignored").id
        colors.assignMissing(to: [CalendarColorSource(id: "next")], ignoring: ["ignored"])
        XCTAssertEqual(colors.color(for: "next").id, first)
    }
}
