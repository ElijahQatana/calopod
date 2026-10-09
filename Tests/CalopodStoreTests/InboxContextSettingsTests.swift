import CalopodStore
import Foundation
import Testing

@Suite("Inbox context settings")
struct InboxContextSettingsTests {
    @Test("Defaults, separate session overrides, and restart persistence")
    func restart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("settings.sqlite").path
        do {
            let repository = LocalStateRepository(database: try CalopodDatabase(path: path))
            #expect(try repository.inboxContextSettings() == InboxContextSettings())
            let settings = try InboxContextSettings(beforeMinutes: 30, afterMinutes: 180)
            try repository.saveInboxContextSettings(settings)
            #expect(try settings.overriding(afterMinutes: 15) == InboxContextSettings(beforeMinutes: 30, afterMinutes: 15))
            #expect(try repository.inboxContextSettings() == settings)
        }
        let reopened = LocalStateRepository(database: try CalopodDatabase(path: path))
        #expect(try reopened.inboxContextSettings() == InboxContextSettings(beforeMinutes: 30, afterMinutes: 180))
    }

    @Test("Invalid and empty windows cannot replace saved settings")
    func invalidMargins() throws {
        #expect(throws: InboxContextSettingsError.invalidMargin) { try InboxContextSettings(beforeMinutes: -1) }
        #expect(throws: InboxContextSettingsError.invalidMargin) { try InboxContextSettings(afterMinutes: Int.max) }
        #expect(throws: InboxContextSettingsError.invalidMargin) { try InboxContextSettings(beforeMinutes: 0, afterMinutes: 0) }
        #expect(try InboxContextSettings(beforeMinutes: 0, afterMinutes: 1).beforeMinutes == 0)
    }
}
