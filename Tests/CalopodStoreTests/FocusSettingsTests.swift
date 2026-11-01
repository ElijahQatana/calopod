import Foundation
import GRDB
import Testing
@testable import CalopodStore

@Suite("Focus settings")
struct FocusSettingsTests {
    @Test("Two hours until a length is saved, then the saved length")
    func roundTrip() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        #expect(try repository.focusSettings().minutes == 120)

        try repository.saveFocusSettings(FocusSettings(minutes: 90))
        try repository.saveFocusSettings(FocusSettings(minutes: 45))

        #expect(try repository.focusSettings() == (try FocusSettings(minutes: 45)))
    }

    @Test("Lengths outside 15 minutes to 24 hours are refused", arguments: [0, 14, 1_441])
    func range(minutes: Int) {
        #expect(throws: FocusSettingsError.minutesOutOfRange) { try FocusSettings(minutes: minutes) }
    }

    @Test("A state from before the table gains it")
    func migration() throws {
        let queue = try DatabaseQueue()
        try CalopodDatabase.migrator.migrate(queue, upTo: "v28_arm_sync_health")
        #expect(try queue.read { try $0.tableExists("focus_settings") } == false)
        try CalopodDatabase.migrator.migrate(queue)
        #expect(try queue.read { try $0.tableExists("focus_settings") })
    }
}
