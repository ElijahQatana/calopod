@testable import CalopodStore
import Foundation
import Testing

@Suite("Inbox digest settings")
struct InboxDigestSettingsTests {
    @Test("Off until turned on, and a time outside one day is refused")
    func defaultsAndValidation() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        #expect(try repository.inboxDigestSettings() == .standard)
        #expect(!InboxDigestSettings.standard.enabled && InboxDigestSettings.standard.minute == nil)
        for minute in [-1, 1440] {
            #expect(throws: InboxDigestSettingsError.minuteOutOfRange) { try InboxDigestSettings(minute: minute) }
        }
    }

    @Test("Without a chosen time the digest follows the earliest working day start")
    func defaultTime() throws {
        let early = try WorkingHours.Day(startMinute: 450, endMinute: 1020)
        let late = try WorkingHours.Day(startMinute: 600, endMinute: 1020)
        let hours = try WorkingHours(days: [1: late, 2: early, 3: late])
        #expect(InboxDigestSettings.standard.minute(workingHours: hours) == 450)
        #expect(InboxDigestSettings.standard.minute(workingHours: .standard) == 540)
        #expect(InboxDigestSettings.standard.minute(workingHours: try WorkingHours(days: [:])) == InboxDigestSettings.fallbackMinute)
        #expect(try InboxDigestSettings(minute: 0).minute(workingHours: hours) == 0)
    }

    @Test("Saved settings come back, with and without a time")
    func roundTrip() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        for settings in [try InboxDigestSettings(enabled: true), try InboxDigestSettings(enabled: true, minute: 465), .standard] {
            try repository.saveInboxDigestSettings(settings)
            #expect(try repository.inboxDigestSettings() == settings)
        }
    }
}
