@testable import CalopodCommands
import CalopodStore
import Foundation
import Testing

@Test
func rootExposesThePlannedCommandGroups() {
    var names: [String] = []
    for command in CalopodRoot.configuration.subcommands {
        names.append(command.configuration.commandName ?? "")
    }

    #expect(names == [
        "connection",
        "calendars",
        "events",
        "availability",
        "sync",
        "doctor",
        "agent",
    ])
}

@Test
func jsonOutputUsesTheStableEnvelope() throws {
    let resolved = try DateRangeResolver(day: "2026-09-24", timezone: "UTC")
        .resolve(default: .none, systemTimeZone: TimeZone(secondsFromGMT: 0)!)
    let range = try #require(resolved)
    let output = try OutputRenderer.render(
        command: "events",
        payload: CommandPayload(
            status: "ok",
            message: "No events are available.",
            count: 0,
            range: RangeOutput(range: range)
        ),
        format: .json
    )
    let data = try #require(output.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["command"] as? String == "events")
    #expect(object["warnings"] as? [String] == [])
    #expect(object["data"] is [String: Any])
}

@Test
func calendarsAcceptExplicitSelectionActions() throws {
    let select = try CalendarsCommand.parse([
        "--connection", "connection",
        "--select", "calendar",
    ])
    let deselect = try CalendarsCommand.parse([
        "--connection", "connection",
        "--deselect", "calendar",
    ])

    #expect(select.select == "calendar")
    #expect(select.deselect == nil)
    #expect(deselect.select == nil)
    #expect(deselect.deselect == "calendar")
}

@Test
func likelyEventKitAndDirectProviderOverlapIsBlocked() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let eventKit = StoredConnection(
        id: "eventkit-device",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Calendars on this Mac",
        isEnabled: true
    )
    let microsoft = StoredConnection(
        id: "microsoft",
        configurationID: "default",
        provider: "microsoft",
        displayLabel: "Microsoft Calendar",
        isEnabled: true
    )
    try repository.saveConnection(eventKit)
    try repository.saveConnection(microsoft)

    let eventKitBinding = StoredCalendarBinding(
        id: "eventkit-calendar",
        connectionID: eventKit.id,
        providerCalendarID: "eventkit-provider-calendar",
        displayLabel: "Synthetic work calendar",
        isSelected: false,
        isReadOnly: false,
        providerSourceID: "eventkit-source",
        providerSourceType: "exchange",
        providerSourceLabel: "Synthetic work source"
    )
    let microsoftBinding = StoredCalendarBinding(
        id: "microsoft-calendar",
        connectionID: microsoft.id,
        providerCalendarID: "microsoft-provider-calendar",
        displayLabel: "Synthetic work calendar",
        isSelected: true,
        isReadOnly: false
    )
    try repository.replaceCalendarBindings(
        connectionID: eventKit.id,
        bindings: [eventKitBinding]
    )
    try repository.replaceCalendarBindings(
        connectionID: microsoft.id,
        bindings: [microsoftBinding]
    )

    let message = try CalendarSelectionSafety.conflictMessage(
        selecting: eventKitBinding,
        on: eventKit,
        repository: repository
    )

    #expect(message?.contains("Microsoft Calendar") == true)
}

@Test
func likelyDirectProviderAndEventKitOverlapIsBlocked() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let eventKit = StoredConnection(
        id: "eventkit-device",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Calendars on this Mac",
        isEnabled: true
    )
    let google = StoredConnection(
        id: "google",
        configurationID: "default",
        provider: "google",
        displayLabel: "Google Calendar",
        isEnabled: true
    )
    try repository.saveConnection(eventKit)
    try repository.saveConnection(google)

    let eventKitBinding = StoredCalendarBinding(
        id: "eventkit-calendar",
        connectionID: eventKit.id,
        providerCalendarID: "eventkit-provider-calendar",
        displayLabel: "Synthetic calendar",
        isSelected: true,
        isReadOnly: false,
        providerSourceID: "eventkit-source",
        providerSourceType: "caldav",
        providerSourceLabel: "Google"
    )
    let googleBinding = StoredCalendarBinding(
        id: "google-calendar",
        connectionID: google.id,
        providerCalendarID: "google-provider-calendar",
        displayLabel: "Synthetic calendar",
        isSelected: false,
        isReadOnly: false
    )
    try repository.replaceCalendarBindings(
        connectionID: eventKit.id,
        bindings: [eventKitBinding]
    )
    try repository.replaceCalendarBindings(
        connectionID: google.id,
        bindings: [googleBinding]
    )

    let message = try CalendarSelectionSafety.conflictMessage(
        selecting: googleBinding,
        on: google,
        repository: repository
    )

    #expect(message?.contains("Google Calendar") == true)
}

@Test
func eventReadsRequireASelectedCalendar() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let connection = StoredConnection(
        id: "eventkit-device",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Calendars on this Mac",
        isEnabled: true
    )
    let binding = StoredCalendarBinding(
        id: "calendar",
        connectionID: connection.id,
        providerCalendarID: "provider-calendar",
        displayLabel: "Synthetic calendar",
        isSelected: false,
        isReadOnly: false
    )
    try repository.saveConnection(connection)
    try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [binding])

    var didThrow = false
    do {
        _ = try selectedCalendarBinding(
            id: binding.id,
            connectionID: connection.id,
            repository: repository
        )
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}
