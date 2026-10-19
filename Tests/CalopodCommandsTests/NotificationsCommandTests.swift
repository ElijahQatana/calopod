@testable import CalopodCommands
import CalopodStore
import Foundation
import Testing

@Suite("calopod notifications")
struct NotificationsCommandTests {
    private func repository() throws -> LocalStateRepository {
        LocalStateRepository(database: try CalopodDatabase.inMemory())
    }

    @Test("Set changes only what it is given and the app reads the same row")
    func roundTrip() throws {
        let state = try repository()
        let set = try NotificationsSetCommand.parse(["--first", "20", "--final", "2", "--hide-titles"])
        try state.saveNotificationSettings(set.resolve(state.notificationSettings()))
        var saved = try state.notificationSettings()
        #expect(saved == (try NotificationSettings(firstMinutes: 20, finalMinutes: 2, hideTitles: true)))

        let later = try NotificationsSetCommand.parse(["--no-final", "--show-titles", "--off"])
        try state.saveNotificationSettings(later.resolve(saved))
        saved = try state.notificationSettings()
        #expect(!saved.enabled && !saved.finalEnabled && saved.firstEnabled && !saved.hideTitles && saved.firstMinutes == 20)

        let back = try NotificationsSetCommand.parse(["--on", "--final", "5"])
        #expect(try back.resolve(saved).finalEnabled)
    }

    @Test("The same checks as the app apply")
    func validation() throws {
        let current = NotificationSettings.standard
        #expect(throws: NotificationSettingsError.finalNotEarlier) {
            try NotificationsSetCommand.parse(["--final", "10"]).resolve(current)
        }
        #expect(throws: NotificationSettingsError.minutesOutOfRange) {
            try NotificationsSetCommand.parse(["--first", "121"]).resolve(current)
        }
        // With the first reminder off, a longer final time is fine.
        #expect(try NotificationsSetCommand.parse(["--no-first", "--final", "30"]).resolve(current).finalMinutes == 30)
    }

    @Test("Conflicting or empty options are refused")
    func parsing() {
        for arguments in [[], ["--on", "--off"], ["--hide-titles", "--show-titles"], ["--no-first", "--first", "5"], ["--no-final", "--final", "1"]] {
            #expect(throws: (any Error).self) { try NotificationsSetCommand.parse(arguments) }
        }
    }

    @Test("The permission is reported as managed by the app")
    func permission() throws {
        let text = NotificationsText.lines(.standard).joined(separator: "\n")
        #expect(text.contains("managed by the app"))
        #expect(text.contains("First reminder: 10 minutes before the start"))
        #expect(text.contains("Final reminder: 1 minute before the start"))
        let json = try OutputRenderer.render(
            command: "notifications",
            payload: CommandPayload(status: "ok", message: "x", notifications: NotificationSettingsOutput(.standard)),
            warnings: [], format: .json, showIDs: false, human: HumanOutputContext(), width: 80)
        #expect(json.contains("\"permission\":\"managed-by-app\""))
    }
}
