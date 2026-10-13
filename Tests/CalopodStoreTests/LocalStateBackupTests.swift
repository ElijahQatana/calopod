@testable import CalopodStore
import CalopodTestSupport
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
        at: fixture.backupURL.path,
        secrets: fixture.secrets
    )

    #expect(summary.migrationCount == 15)
    #expect(try LocalStateBackup.verify(at: fixture.backupURL.path, secrets: fixture.secrets) == summary)
    let permissions = try FileManager.default.attributesOfItem(
        atPath: fixture.backupURL.path
    )[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    #expect(try fixture.configurationIDs(at: fixture.plainCopy(of: fixture.backupURL)) == ["original"])
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
            at: fixture.backupURL.path,
            secrets: fixture.secrets
        )
    }
    #expect(throws: LocalStateBackupError.invalidPath) {
        try LocalStateBackup.create(from: fixture.stateURL.path, at: "backup.sqlite", secrets: fixture.secrets)
    }
}

@Test
func localStateBackupRejectsPublicAndInvalidFiles() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")
    _ = try LocalStateBackup.create(
        from: fixture.stateURL.path,
        at: fixture.backupURL.path,
        secrets: fixture.secrets
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o644],
        ofItemAtPath: fixture.backupURL.path
    )

    #expect(throws: LocalStateBackupError.backupNotPrivate) {
        try LocalStateBackup.verify(at: fixture.backupURL.path, secrets: fixture.secrets)
    }

    let invalidURL = fixture.root.appendingPathComponent("invalid.sqlite")
    try Data("not a database".utf8).write(to: invalidURL)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: invalidURL.path
    )
    #expect(throws: (any Error).self) {
        try LocalStateBackup.verify(at: invalidURL.path, secrets: fixture.secrets)
    }
}

@Test
func localStateRestoreReplacesStateAndPreservesBackup() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("backed-up")
    _ = try LocalStateBackup.create(
        from: fixture.stateURL.path,
        at: fixture.backupURL.path,
        secrets: fixture.secrets
    )

    try FileManager.default.removeItem(at: fixture.stateURL)
    try fixture.seed("replacement")
    let summary = try LocalStateBackup.restore(
        from: fixture.backupURL.path,
        to: fixture.stateURL.path,
        secrets: fixture.secrets
    )

    #expect(summary.migrationCount == 15)
    #expect(try fixture.configurationIDs(at: fixture.stateURL) == ["backed-up"])
    #expect(FileManager.default.fileExists(atPath: fixture.backupURL.path))
}

@Test
func localStateBackupAndRestoreRecoverWALContents() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    let database = try CalopodDatabase(path: fixture.stateURL.path)
    try database.write { db in
        try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["retained", Date(), Date()])
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.stateURL.path)
    #expect(FileManager.default.fileExists(atPath: fixture.stateURL.path + "-wal"))
    _ = try LocalStateBackup.create(from: fixture.stateURL.path, at: fixture.backupURL.path, secrets: fixture.secrets)
    #expect(try fixture.configurationIDs(at: fixture.plainCopy(of: fixture.backupURL)) == ["retained"])
    for suffix in ["-wal", "-shm"] {
        #expect(!FileManager.default.fileExists(atPath: fixture.backupURL.path + suffix))
    }

    // Copy the on-disk WAL state to simulate an interrupted process.
    let interruptedURL = fixture.root.appendingPathComponent("interrupted.sqlite")
    for suffix in ["", "-wal", "-shm"] {
        try FileManager.default.copyItem(atPath: fixture.stateURL.path + suffix, toPath: interruptedURL.path + suffix)
    }
    #expect(try fixture.configurationIDs(at: interruptedURL) == ["retained"])
    let summary = try LocalStateBackup.restore(from: fixture.backupURL.path, to: interruptedURL.path, secrets: fixture.secrets)
    #expect(summary.migrationCount == CalopodDatabase.supportedMigrationIdentifiers.count)
    #expect(try fixture.configurationIDs(at: interruptedURL) == ["retained"])
    for suffix in ["-wal", "-shm"] {
        #expect(!FileManager.default.fileExists(atPath: interruptedURL.path + suffix))
    }
    let reopened = try CalopodDatabase(path: interruptedURL.path)
    #expect(try reopened.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
    withExtendedLifetime(database) {}
}

@Test
func localStateRestoreRefusesAnOpenWALConnection() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")
    let database = try CalopodDatabase(path: fixture.stateURL.path)
    _ = try LocalStateBackup.create(from: fixture.stateURL.path, at: fixture.backupURL.path, secrets: fixture.secrets)
    #expect(throws: LocalStateBackupError.stateBusy) {
        try LocalStateBackup.restore(from: fixture.backupURL.path, to: fixture.stateURL.path, secrets: fixture.secrets)
    }
    #expect(try fixture.configurationIDs(at: fixture.stateURL) == ["original"])
    withExtendedLifetime(database) {}
}

@Test
func localStateRestoreCanReplaceDamagedStateWithoutSidecars() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")
    _ = try LocalStateBackup.create(from: fixture.stateURL.path, at: fixture.backupURL.path, secrets: fixture.secrets)
    let damagedURL = fixture.root.appendingPathComponent("damaged.sqlite")
    try Data("damaged".utf8).write(to: damagedURL)
    _ = try LocalStateBackup.restore(from: fixture.backupURL.path, to: damagedURL.path, secrets: fixture.secrets)
    #expect(try fixture.configurationIDs(at: damagedURL) == ["original"])
}

private struct BackupFixture {
    let root: URL
    let stateURL: URL
    let backupURL: URL
    let secrets = MemorySecretStore()

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

    /// Opens an encrypted backup into a plain database for inspection.
    func plainCopy(of backup: URL) throws -> URL {
        let plain = try BackupEncryption.open(try Data(contentsOf: backup), secrets: secrets)
        let url = root.appendingPathComponent("plain-\(UUID().uuidString).sqlite")
        try plain.write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@Test
func localStateBackupIsEncryptedAtRest() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("visible-marker")
    let summary = try LocalStateBackup.create(
        from: fixture.stateURL.path, at: fixture.backupURL.path, secrets: fixture.secrets
    )

    let bytes = try Data(contentsOf: fixture.backupURL)
    #expect(summary.isEncrypted)
    #expect(bytes.starts(with: Data("CALOPODBK1\n".utf8)))
    #expect(bytes.range(of: Data("SQLite format 3".utf8)) == nil)
    #expect(bytes.range(of: Data("visible-marker".utf8)) == nil)
}

@Test
func encryptedBackupNeedsItsKey() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")
    _ = try LocalStateBackup.create(
        from: fixture.stateURL.path, at: fixture.backupURL.path, secrets: fixture.secrets
    )

    #expect(throws: LocalStateBackupError.keyUnavailable) {
        try LocalStateBackup.verify(at: fixture.backupURL.path, secrets: MemorySecretStore())
    }

    let otherKey = MemorySecretStore()
    let otherBackup = fixture.root.appendingPathComponent("other.sqlite")
    _ = try LocalStateBackup.create(from: fixture.stateURL.path, at: otherBackup.path, secrets: otherKey)
    #expect(throws: LocalStateBackupError.backupInvalid) {
        try LocalStateBackup.verify(at: fixture.backupURL.path, secrets: otherKey)
    }
}

@Test
func tamperedEncryptedBackupIsRejected() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("original")
    _ = try LocalStateBackup.create(
        from: fixture.stateURL.path, at: fixture.backupURL.path, secrets: fixture.secrets
    )
    var bytes = try Data(contentsOf: fixture.backupURL)
    bytes[bytes.count - 20] ^= 0xFF
    try bytes.write(to: fixture.backupURL)

    #expect(throws: LocalStateBackupError.backupInvalid) {
        try LocalStateBackup.verify(at: fixture.backupURL.path, secrets: fixture.secrets)
    }
    #expect(throws: LocalStateBackupError.backupInvalid) {
        try LocalStateBackup.restore(
            from: fixture.backupURL.path, to: fixture.stateURL.path, secrets: fixture.secrets
        )
    }
}

@Test
func plainBackupsFromEarlierVersionsStillRestore() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("older")
    let database = try CalopodDatabase(path: fixture.stateURL.path)
    try database.backup(toPath: fixture.backupURL.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.backupURL.path)

    let verified = try LocalStateBackup.verify(at: fixture.backupURL.path, secrets: MemorySecretStore())
    #expect(!verified.isEncrypted)

    let target = fixture.root.appendingPathComponent("restored.sqlite")
    let restored = try LocalStateBackup.restore(
        from: fixture.backupURL.path, to: target.path, secrets: MemorySecretStore()
    )
    #expect(!restored.isEncrypted)
    #expect(try fixture.configurationIDs(at: target) == ["older"])
}

@Test
func encryptedBackupRestoresIntoPlainState() throws {
    let fixture = try BackupFixture()
    defer { fixture.remove() }
    try fixture.seed("kept")
    _ = try LocalStateBackup.create(
        from: fixture.stateURL.path, at: fixture.backupURL.path, secrets: fixture.secrets
    )
    let target = fixture.root.appendingPathComponent("restored.sqlite")
    let summary = try LocalStateBackup.restore(
        from: fixture.backupURL.path, to: target.path, secrets: fixture.secrets
    )

    #expect(summary.isEncrypted)
    #expect(try fixture.configurationIDs(at: target) == ["kept"])
}
