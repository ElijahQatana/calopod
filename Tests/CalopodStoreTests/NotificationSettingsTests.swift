@testable import CalopodStore
import Foundation
import GRDB
import Testing

@Suite("Notification settings")
struct NotificationSettingsTests {
    @Test("Defaults are a first reminder at 10 minutes and a final one at 1")
    func defaults() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let settings = try repository.notificationSettings()
        #expect(settings == NotificationSettings.standard)
        #expect(settings.enabled && settings.firstEnabled && settings.finalEnabled && !settings.hideTitles)
        #expect(settings.leads.map { $0.minutes } == [10, 1])
    }

    @Test("Minutes outside 1 to 120 and a final reminder that is not earlier are refused")
    func validation() throws {
        let table: [(first: Int, final: Int, error: NotificationSettingsError)] = [
            (0, 1, .minutesOutOfRange), (121, 1, .minutesOutOfRange), (10, 0, .minutesOutOfRange),
            (10, 121, .minutesOutOfRange), (10, 10, .finalNotEarlier), (5, 8, .finalNotEarlier),
        ]
        for row in table {
            #expect(throws: row.error) { try NotificationSettings(firstMinutes: row.first, finalMinutes: row.final) }
        }
        #expect(try NotificationSettings(firstMinutes: 120, finalMinutes: 119).leads.count == 2)
        #expect(NotificationSettingsError.finalNotEarlier.localizedDescription.contains("final reminder"))
    }

    @Test("The order only matters while both reminders are on")
    func orderWithOneOff() throws {
        let onlyFinal = try NotificationSettings(firstEnabled: false, firstMinutes: 5, finalMinutes: 30)
        #expect(onlyFinal.leads.map { $0.kind } == [NotificationSettings.Kind.final])
        #expect(throws: NotificationSettingsError.finalNotEarlier) { try onlyFinal.changing(firstEnabled: true) }
        let onlyFirst = try NotificationSettings(firstMinutes: 3, finalEnabled: false, finalMinutes: 30)
        #expect(onlyFirst.leads.map { $0.kind } == [NotificationSettings.Kind.first])
    }

    @Test("Both off, or the master switch off, leave nothing to schedule")
    func nothingWhenOff() throws {
        #expect(try NotificationSettings(firstEnabled: false, finalEnabled: false).leads.isEmpty)
        #expect(try NotificationSettings(enabled: false).leads.isEmpty)
    }

    @Test("Saved settings are read back after the database is reopened")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("state.sqlite").path
        let saved = try NotificationSettings(
            enabled: true, firstEnabled: true, firstMinutes: 30, finalEnabled: false, finalMinutes: 2, hideTitles: true)
        do {
            let repository = LocalStateRepository(database: try CalopodDatabase(path: path))
            try repository.saveNotificationSettings(saved)
            try repository.saveNotificationSettings(saved)
        }
        let reopened = LocalStateRepository(database: try CalopodDatabase(path: path))
        #expect(try reopened.notificationSettings() == saved)
    }

    @Test("A state from before the table gains it with the defaults")
    func migration() throws {
        #expect(CalopodDatabase.supportedMigrationIdentifiers.last == "v20_notification_settings")
        let queue = try DatabaseQueue()
        try CalopodDatabase.migrator.migrate(queue, upTo: "v19_calendar_view_hidden")
        #expect(try queue.read { try $0.tableExists("notification_settings") } == false)
        try CalopodDatabase.migrator.migrate(queue)
        #expect(try queue.read { try $0.tableExists("notification_settings") })
        #expect(try queue.read { try CalopodDatabase.migrator.appliedMigrations($0) } == CalopodDatabase.supportedMigrationIdentifiers)
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        #expect(try repository.notificationSettings() == .standard)
    }
}
