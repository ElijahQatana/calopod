import Foundation
import Testing

@testable import CalopodStore

@Test
func calendarPreferencesRoundTripAndClear() throws {
    let state = LocalStateRepository(database: try .inMemory())
    try state.setCalendarAlias("  Work ", calendarID: "a")
    try state.setCalendarIgnored(true, calendarID: "a")
    try state.setCalendarColor("teal", calendarID: "a")
    try state.setCalendarColor("red", calendarID: "b")
    #expect(try state.calendarPreferences() == [
        "a": CalendarPreference(alias: "Work", isIgnored: true, color: "teal"),
        "b": CalendarPreference(color: "red"),
    ])

    try state.setCalendarAlias("   ", calendarID: "a")
    try state.setCalendarIgnored(false, calendarID: "a")
    #expect(try state.calendarPreferences()["a"] == CalendarPreference(color: "teal"))
}

@Test
func calendarPreferencesRecordTheirConnection() throws {
    let state = LocalStateRepository(database: try .inMemory())
    try state.saveConnection(StoredConnection(
        id: "conn", configurationID: "default", provider: "eventkit", displayLabel: "Calendars", isEnabled: true))
    try state.replaceCalendarBindings(connectionID: "conn", bindings: [
        StoredCalendarBinding(id: "cal", connectionID: "conn", providerCalendarID: "cal", displayLabel: "Cal",
                              isSelected: false, isReadOnly: false),
    ])
    try state.setCalendarAlias("Work", calendarID: "cal")
    let connection = try state.database.read {
        try String.fetchOne($0, sql: "SELECT connection_id FROM calendar_preferences WHERE calendar_id = 'cal'")
    }
    #expect(connection == "conn")
}

@Test
func importFillsOnlyMissingValues() throws {
    let state = LocalStateRepository(database: try .inMemory())
    try state.setCalendarAlias("Kept", calendarID: "a")
    try state.setCalendarIgnored(false, calendarID: "b")

    let filled = try state.importCalendarPreferences(
        aliases: ["a": "Old", "b": "Home"], ignored: ["a", "b"], colors: ["a": "red"])
    #expect(filled == 3)
    #expect(try state.calendarPreferences() == [
        "a": CalendarPreference(alias: "Kept", isIgnored: true, color: "red"),
        "b": CalendarPreference(alias: "Home", isIgnored: false),
    ])
}

@Test
func importFillsARowThatExistsWithAnEmptyAlias() throws {
    let state = LocalStateRepository(database: try .inMemory())
    // A row made first by a color choice, and one with a blank alias left behind.
    try state.setCalendarColor("teal", calendarID: "a")
    try state.database.write {
        try $0.execute(sql: "INSERT INTO calendar_preferences (calendar_id, alias, color) VALUES ('b', '', '')")
    }
    try state.importCalendarPreferences(aliases: ["a": "Work", "b": "Home"], ignored: [], colors: ["b": "red"])
    #expect(try state.calendarPreferences() == [
        "a": CalendarPreference(alias: "Work", color: "teal"),
        "b": CalendarPreference(alias: "Home", color: "red"),
    ])
}

@Test
func importKeepsANonEmptyAliasAndCanRepeat() throws {
    let state = LocalStateRepository(database: try .inMemory())
    try state.setCalendarAlias("Kept", calendarID: "a")
    #expect(try state.importCalendarPreferences(aliases: ["a": "Old", "b": "Home"], ignored: [], colors: [:]) == 1)
    #expect(try state.importCalendarPreferences(aliases: ["a": "Old", "b": "Home"], ignored: [], colors: [:]) == 0)
    #expect(try state.calendarPreferences().mapValues(\.alias) == ["a": "Kept", "b": "Home"])
}

@Test
func pruneRemovesOnlyRowsWithNoBindingAndNoConnection() throws {
    let state = LocalStateRepository(database: try .inMemory())
    try state.saveConnection(StoredConnection(
        id: "conn", configurationID: "default", provider: "eventkit", displayLabel: "Calendars", isEnabled: true))
    try state.replaceCalendarBindings(connectionID: "conn", bindings: [
        StoredCalendarBinding(id: "cal", connectionID: "conn", providerCalendarID: "cal", displayLabel: "Cal",
                              isSelected: true, isReadOnly: false),
    ])
    try state.setCalendarAlias("Work", calendarID: "cal")
    try state.setCalendarAlias("Junk", calendarID: "fam")
    try state.setCalendarColor("red", calendarID: "hol")
    // Its calendar dropped out of a refresh, but the connection is still there.
    try state.database.write {
        try $0.execute(sql: "INSERT INTO calendar_preferences (calendar_id, connection_id, alias) VALUES ('gone', 'conn', 'Back soon')")
    }

    #expect(try state.pruneCalendarPreferences(dryRun: true) == 2)
    #expect(try state.calendarPreferences().count == 4)
    #expect(try state.pruneCalendarPreferences() == 2)
    #expect(Set(try state.calendarPreferences().keys) == ["cal", "gone"])
    #expect(try state.pruneCalendarPreferences() == 0)
}

@Test
func shownNameIgnoresBlankAndRealNames() {
    #expect(CalendarDisplayName.shown(alias: "Office", real: "Work") == "Office")
    #expect(CalendarDisplayName.shown(alias: "  ", real: "Work") == "Work")
    #expect(CalendarDisplayName.shown(alias: "", real: "Work") == "Work")
    #expect(CalendarDisplayName.alias("Work", real: "Work") == nil)
    #expect(CalendarDisplayName.shown(alias: nil, real: nil) == nil)
}
