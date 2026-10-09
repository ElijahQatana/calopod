@testable import CalopodStore
import Foundation
import GRDB
import Testing

@Test
func localStateBackupCreatesPrivateVerifiedCopy() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")

    let summary = try LocalStateBackup.create(
        from: fixture.stateURL.path,
        at: fixture.backupURL.path
    )

    #expect(summary.migrationCount == 9)
    #expect(try LocalStateBackup.verify(at: fixture.backupURL.path) == summary)
    let permissions = try FileManager.default.attributesOfItem(
        atPath: fixture.backupURL.path
    )[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(try fixture.configurationIDs(at: fixture.backupURL) == ["original"])
}

@Test
func localStateBackupRefusesOverwriteAndRelativePaths() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")
    try Data().write(to: fixture.backupURL)

    #expect(throws: LocalStateBackupError.destinationExists) {
        try LocalStateBackup.create(
            from: fixture.stateURL.path,
            at: fixture.backupURL.path
        )
    }
    #expect(throws: LocalStateBackupError.invalidPath) {
        try LocalStateBackup.create(from: fixture.stateURL.path, at: "backup.sqlite")
    }
}

@Test
func localStateBackupRejectsPublicAndInvalidFiles() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")
    _ = try LocalStateBackup.create(
        from: fixture.stateURL.path,
        at: fixture.backupURL.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fixture.backupURL.path
    )

    #expect(throws: LocalStateBackupError.backupNotPrivate) {
        try LocalStateBackup.verify(at: fixture.backupURL.path)
    }

    let invalidURL = fixture.root.appendingPathComponent("invalid.sqlite")
    try Data("not a database".utf8).write(to: invalidURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: invalidURL.path
    )
    #expect(throws: (any Error).self) {
        try LocalStateBackup.verify(at: invalidURL.path)
    }
}

@Test
func localStateRestoreReplacesStateAndPreservesBackup() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("backed-up")
    _ = try LocalStateBackup.create(
        from: fixture.stateURL.path,
        at: fixture.backupURL.path
    )

    try FileManager.default.removeItem(at: fixture.stateURL)
    try fixture.seed("replacement")
    let summary = try LocalStateBackup.restore(
        from: fixture.backupURL.path,
        to: fixture.stateURL.path
    )

    #expect(summary.migrationCount == 9)
    #expect(try fixture.configurationIDs(at: fixture.stateURL) == ["backed-up"])
    #expect(FileManager.default.fileExists(atPath: fixture.backupURL.path))
}

@Test
func localStateRestoreRejectsStateWithSQLiteSidecars() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")
    _ = try LocalStateBackup.create(
        from: fixture.stateURL.path,
        at: fixture.backupURL.path
    )
    FileManager.default.createFile(
        atPath: fixture.stateURL.path + "-wal",
        contents: Data()
    )

    #expect(throws: LocalStateBackupError.stateBusy) {
        try LocalStateBackup.restore(
            from: fixture.backupURL.path,
            to: fixture.stateURL.path
        )
    }
    #expect(try fixture.configurationIDs(at: fixture.stateURL) == ["original"])
}

private struct BackupFixture {
    let root: URL
    let stateURL: URL
    let backupURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("calopod-backup-\(UUID().uuidString)", isDirectory: true)
        stateURL = root.appendingPathComponent("state.sqlite")
        backupURL = root.appendingPathComponent("backup.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func seed(_ configurationID: String) throws {
        let database = try CalopodDatabase(path: stateURL.path)
        try database.write { database in
            try database.execute(
                sql: "INSERT INTO configurations VALUES (?, ?, ?)",
                arguments: [configurationID, Date(), Date()]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stateURL.path
        )
    }

    func configurationIDs(at url: URL) throws -> [String] {
        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        return try database.read { database in
            try String.fetchAll(database, sql: "SELECT id FROM configurations ORDER BY id")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
