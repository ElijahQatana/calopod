@testable import CalopodCommands
import CalopodEventKit
import CalopodProviders
import Foundation
import Testing

private let home = "/Volumes/example-home"
private let standalone = "\(home)/Library/Application Support/Calopod/Service/eventkit-host/Calopod EventKit Host.app"
private let nested = "/Applications/Calopod.app/Contents/MacOS/eventkit-host/Calopod EventKit Host.app"
private let devBuild = "\(home)/src/calopod/.build/eventkit-host/Calopod EventKit Host.app"
private let askCommand = "open -W -n --stdout /tmp/h.json --stderr /tmp/h.err"

private func guidance(_ path: String, _ status: EventKitAccessStatus) -> CalendarAccessGuidance {
    CalendarAccessGuidance(helperPath: path, status: status, home: home)
}

@Test
func standaloneHelperNotAskedYetGetsTheAskCommand() {
    let result = guidance(standalone, .notDetermined)
    #expect(result.helperPath == "~/Library/Application Support/Calopod/Service/eventkit-host/Calopod EventKit Host.app")
    #expect(result.message.contains("\"Calopod EventKit Host\""))
    #expect(result.fix.contains("\(askCommand) \"$HOME/Library/Application Support/Calopod/Service/eventkit-host/Calopod EventKit Host.app\" --args --request-permission"))
    #expect(result.accessStatus == "not-determined")
    // A command-line-only install has no app to point at.
    #expect(!result.message.contains("Settings, Permissions") && !result.message.contains("Calopod.app"))
}

@Test
func standaloneHelperDeniedPointsAtPrivacySettings() {
    for status in [EventKitAccessStatus.denied, .restricted] {
        let result = guidance(standalone, status)
        #expect(result.message.contains("\"Calopod EventKit Host\" in Privacy & Security, Calendars"))
        #expect(result.fix.contains("open \"x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars\""))
        #expect(!result.message.contains(askCommand) && !result.message.contains("Calopod.app"))
    }
}

@Test
func helperInsideTheAppIsListedAsCalopod() {
    let denied = guidance(nested, .denied)
    #expect(denied.message.contains("macOS lists it as \"Calopod\""))
    #expect(denied.helperPath == nested)
    let asked = guidance(nested, .notDetermined)
    #expect(asked.fix.contains("Settings, Permissions, Allow"))
    #expect(asked.fix.contains(askCommand))
}

@Test
func buildCopyMentionsTheInstalledCommand() {
    for status in [EventKitAccessStatus.notDetermined, .denied] {
        let result = guidance(devBuild, status)
        #expect(result.helperPath == "~/src/calopod/.build/eventkit-host/Calopod EventKit Host.app")
        #expect(result.fix.contains("installed command in ~/.local/bin may use a different helper that is already allowed"))
    }
    #expect(!guidance(standalone, .denied).fix.contains("~/.local/bin"))
}

@Test
func messagesNeverCarryTheHomeFolder() {
    for path in [standalone, devBuild, nested] {
        for status in [EventKitAccessStatus.notDetermined, .denied, .restricted, .writeOnly, .unknown] {
            let result = guidance(path, status)
            for text in [result.message, result.fix, result.helperPath] {
                #expect(!text.contains(home))
            }
        }
    }
}

@Test
func accessErrorKeepsItsExitStatusAndCarriesTheFieldsInJSON() throws {
    let error = CalendarAccessDeniedError(guidance: guidance(devBuild, .denied))
    let failure = commandFailure(error)
    #expect(failure.exitCode == .permissionDenied)
    #expect(failure.message == error.guidance.message)

    let json = try OutputRenderer.render(
        command: "error", payload: errorPayload(error), warnings: [], format: .json, showIDs: false,
        human: HumanOutputContext(), width: 80)
    let data = try #require(json.data(using: .utf8))
    let payload = try #require((JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any])
    #expect(payload["helperPath"] as? String == error.guidance.helperPath)
    #expect(payload["accessStatus"] as? String == "denied")
    #expect(payload["fix"] as? String == error.guidance.fix)
    #expect(!json.contains(home))
}

@Test
func aFullAccessReplyKeepsTheGeneralError() {
    let error = CalendarAccessDeniedError.make(helper: URL(fileURLWithPath: standalone), status: .fullAccess)
    #expect(error as? ProviderFailure == .permissionDenied)
}

@Test
func doctorAndSettingsReadingsUseTheSameWords() {
    let reading = Permissions.calendar(status: .denied, helper: devBuild, home: home)
    #expect(reading.detail == guidance(devBuild, .denied).message)
    #expect(reading.reason == "denied")
    #expect(Permissions.calendar(status: .fullAccess, helper: devBuild, home: home).detail == "Calopod can read your calendars.")
}
