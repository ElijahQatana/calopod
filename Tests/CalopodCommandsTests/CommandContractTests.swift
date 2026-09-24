import CalopodCommands
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
