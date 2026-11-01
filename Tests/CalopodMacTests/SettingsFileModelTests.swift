import CalopodStore
import Foundation
import Testing

@testable import CalopodMac

@MainActor
struct SettingsFileModelTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-file-\(UUID().uuidString)")

    private func model(_ state: LocalStateRepository) throws -> SettingsFileModel {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SettingsFileModel(state: state)
    }

    @Test func exportIsPrivateAndImportWaitsForConfirmation() throws {
        let old = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try old.saveFocusSettings(FocusSettings(minutes: 45))
        let file = directory.appendingPathComponent("calopod-config.json")
        try model(old).export(to: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)

        let new = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let importing = try model(new)
        var reloaded = false
        importing.onImported = { reloaded = true }
        importing.chooseImport(file)
        #expect(importing.plan?.lines == ["Change focus length"])
        #expect(try new.focusSettings().minutes == 120)
        importing.applyImport()
        #expect(try new.focusSettings().minutes == 45 && reloaded && importing.plan == nil && !importing.failed)
    }

    @Test func newerFileIsRefusedWithAMessage() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let importing = try model(state)
        let file = directory.appendingPathComponent("newer.json")
        try Data("{\"formatVersion\": 9}".utf8).write(to: file)
        importing.chooseImport(file)
        #expect(importing.plan == nil && importing.failed)
        #expect(importing.message?.contains("version 9") == true)
    }
}
