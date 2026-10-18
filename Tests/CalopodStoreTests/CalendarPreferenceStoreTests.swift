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
func importFillsOnlyMissingValuesAndRunsOnce() throws {
    let state = LocalStateRepository(database: try .inMemory())
    try state.setCalendarAlias("Kept", calendarID: "a")
    try state.setCalendarIgnored(false, calendarID: "b")

    let ran = try state.importCalendarPreferences(
        aliases: ["a": "Old", "b": "Home"], ignored: ["a", "b"], colors: ["a": "red"])
    #expect(ran)
    #expect(try state.calendarPreferences() == [
        "a": CalendarPreference(alias: "Kept", isIgnored: true, color: "red"),
        "b": CalendarPreference(alias: "Home", isIgnored: false),
    ])

    try state.setCalendarAlias(nil, calendarID: "b")
    let again = try state.importCalendarPreferences(aliases: ["b": "Home"], ignored: [], colors: [:])
    #expect(!again)
    #expect(try state.calendarPreferences()["b"]?.alias == nil)
}
