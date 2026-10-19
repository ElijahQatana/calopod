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
    #expect(info["NSPrincipalClass"] as? String == "NSApplication")
    #expect(info["CFBundleIdentifier"] as? String == "pro.elijahquintana.calopod.eventkit-host")
    for key in ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"] {
        let text = try #require(info[key] as? String)
        #expect(text.contains("reads the calendars you choose"))
    }
}

@Test
func outerAppCanAskForCalendarAccessToo() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Support/Mac/Info.plist"))
    let info = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let host = try hostInfo()
    for key in ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"] {
        #expect(try #require(info[key] as? String) == host[key] as? String)
    }
    for path in ["Support/Mac/Entitlements.plist", "Support/EventKitHost/Entitlements.plist"] {
        let entitlements = try Data(contentsOf: root.appendingPathComponent(path))
        let plist = try #require(PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Any])
        #expect(plist["com.apple.security.personal-information.calendars"] as? Bool == true)
    }
}
