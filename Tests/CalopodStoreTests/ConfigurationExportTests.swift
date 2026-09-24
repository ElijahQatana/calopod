import CalopodDomain
import CalopodStore
import Foundation
import Testing

@Test
func plainExportContainsOnlyLogicalBindings() throws {
    let connectionID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let bindingID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let export = ExportedConfiguration(
        configurationID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
        connections: [ExportedConnection(id: connectionID, provider: .google)],
        calendarBindings: [
            ExportedCalendarBinding(id: bindingID, connectionID: connectionID, isSelected: true),
        ],
        arms: []
    )

    let encoded = try JSONEncoder().encode(export)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let serialized = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let text = try #require(String(data: serialized, encoding: .utf8))

    #expect(text.contains("requiresRebinding"))
    #expect(!text.localizedCaseInsensitiveContains("token"))
    #expect(!text.localizedCaseInsensitiveContains("secret"))
    #expect(!text.localizedCaseInsensitiveContains("credential"))
    #expect(!text.localizedCaseInsensitiveContains("providerCalendar"))
    #expect(!text.localizedCaseInsensitiveContains("displayLabel"))
}
