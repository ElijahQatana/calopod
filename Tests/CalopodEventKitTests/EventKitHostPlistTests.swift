import Foundation
import Testing

private func hostInfo() throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Support/EventKitHost/Info.plist"))
    return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
}

@Test
func hostRunsAsAnAgentAppThatCanShowTheCalendarPrompt() throws {
    let info = try hostInfo()
    #expect(info["LSUIElement"] as? Bool == true)
    #expect(info["LSBackgroundOnly"] == nil)
    #expect(info["CFBundleIdentifier"] as? String == "pro.elijahquintana.calopod.eventkit-host")
    for key in ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"] {
        let text = try #require(info[key] as? String)
        #expect(text.contains("reads the calendars you choose"))
    }
}
