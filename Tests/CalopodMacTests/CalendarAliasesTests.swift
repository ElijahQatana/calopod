import CalopodStore
import XCTest

@testable import CalopodMac

@MainActor
final class CalendarAliasesTests: XCTestCase {
    private func store() throws -> (CalendarAliases, UserDefaults, LocalStateRepository) {
        let defaults = UserDefaults(suiteName: "aliases-\(UUID().uuidString)")!
        let state = LocalStateRepository(database: try .inMemory())
        return (CalendarAliases(defaults: defaults, state: state), defaults, state)
    }

    func testAliasShowsInPlaceOfTheRealNameAndClears() throws {
        let (aliases, _, _) = try store()
        XCTAssertEqual(aliases.name(for: "a", real: "Calendar"), "Calendar")
        aliases.setAlias("  Work ", for: "a", real: "Calendar")
        XCTAssertEqual(aliases.name(for: "a", real: "Calendar"), "Work")
        for blank in ["", "   ", "Calendar"] {
            aliases.setAlias("Work", for: "a", real: "Calendar")
            aliases.setAlias(blank, for: "a", real: "Calendar")
            XCTAssertNil(aliases.alias(for: "a"), "\(blank) clears")
        }
    }

    func testTwoCalendarsWithTheSameNameGetOwnAliases() throws {
        let (aliases, _, _) = try store()
        aliases.setAlias("Family birthdays", for: "a", real: "Birthdays")
        XCTAssertEqual(aliases.name(for: "a", real: "Birthdays"), "Family birthdays")
        XCTAssertEqual(aliases.name(for: "b", real: "Birthdays"), "Birthdays")
    }

    func testIgnoreAndUnignore() throws {
        let (aliases, _, _) = try store()
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

    func testChoicesSurviveARestart() throws {
        let (aliases, defaults, state) = try store()
        aliases.setAlias("Work", for: "a", real: "Calendar")
        aliases.setIgnored(true, for: "b")
        aliases.setExpanded(true, for: "conn")
        let again = CalendarAliases(defaults: defaults, state: state)
        XCTAssertEqual(again.alias(for: "a"), "Work")
        XCTAssertTrue(again.isIgnored("b"))
        XCTAssertTrue(again.isExpanded("conn"))
        XCTAssertFalse(again.isExpanded("other"), "collapsed by default")
    }

    func testPreferencesAreReadFromTheDatabaseNotPreferences() throws {
        let (aliases, defaults, state) = try store()
        aliases.setAlias("Work", for: "a", real: "Calendar")
        aliases.setIgnored(true, for: "b")
        XCTAssertEqual(try state.calendarPreferences()["a"]?.alias, "Work")
        XCTAssertEqual(try state.calendarPreferences()["b"]?.isIgnored, true)
        XCTAssertNil(defaults.dictionary(forKey: "calendarAliases"))
        XCTAssertNil(defaults.stringArray(forKey: "calendarIgnored"))
        // Another process, such as the command line, changes the database; a restart sees it.
        try state.setCalendarAlias(nil, calendarID: "a")
        try state.setCalendarIgnored(false, calendarID: "b")
        let again = CalendarAliases(defaults: defaults, state: state)
        XCTAssertNil(again.alias(for: "a"))
        XCTAssertFalse(again.isIgnored("b"))
    }

    func testOldPreferencesMoveOverOnceAndNeverOverwrite() throws {
        let defaults = UserDefaults(suiteName: "aliases-\(UUID().uuidString)")!
        let state = LocalStateRepository(database: try .inMemory())
        defaults.set(["a": "Work", "b": "Home"], forKey: "calendarAliases")
        defaults.set(["a"], forKey: "calendarIgnored")
        defaults.set(["a": "red", "b": "teal"], forKey: "calendarColors")
        // Already in the database before the import: kept.
        try state.setCalendarAlias("Kept", calendarID: "b")

        let first = CalendarAliases(defaults: defaults, state: state)
        XCTAssertEqual(first.alias(for: "a"), "Work")
        XCTAssertEqual(first.alias(for: "b"), "Kept")
        XCTAssertTrue(first.isIgnored("a"))
        XCTAssertEqual(CalendarColors(defaults: defaults, state: state).color(for: "b").id, "teal")

        // Cleared afterwards, a later launch does not bring the old value back.
        first.setAlias("", for: "a", real: "Calendar")
        first.setIgnored(false, for: "a")
        let second = CalendarAliases(defaults: defaults, state: state)
        XCTAssertNil(second.alias(for: "a"))
        XCTAssertFalse(second.isIgnored("a"))
    }

    func testIgnoredCalendarsDoNotUseUpSuggestedColors() {
        let colors = CalendarColors(defaults: UserDefaults(suiteName: "colors-\(UUID().uuidString)")!, state: nil)
        colors.assignMissing(to: [CalendarColorSource(id: "ignored")])
        let first = colors.color(for: "ignored").id
        colors.assignMissing(to: [CalendarColorSource(id: "next")], ignoring: ["ignored"])
        XCTAssertEqual(colors.color(for: "next").id, first)
    }
}
