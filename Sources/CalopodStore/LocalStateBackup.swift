import Foundation
import GRDB

public enum LocalStateBackupError: Error, Equatable, Sendable {
    case invalidPath
    case sourceMissing
    case destinationExists
    case backupInvalid
    case backupNotPrivate
    case unsupportedSchema
    case stateBusy
    case keyUnavailable
}

public struct LocalStateBackupSummary: Equatable, Sendable {
    public let migrationCount: Int
    public let isEncrypted: Bool

    public init(migrationCount: Int, isEncrypted: Bool = false) {
        self.migrationCount = migrationCount
        self.isEncrypted = isEncrypted
    }
}

public enum LocalStateBackup {
    public static func create(
        from sourcePath: String,
        at backupPath: String,
        secrets: any SecretStore,
        fileManager: FileManager = .default
    ) throws -> LocalStateBackupSummary {
        let sourceURL = try existingRegularFile(
            at: sourcePath,
            missing: .sourceMissing,
            fileManager: fileManager
        )
        let backupURL = try newFileURL(at: backupPath, fileManager: fileManager)
        guard sourceURL != backupURL else { throw LocalStateBackupError.invalidPath }

        let stagingURL = backupURL.deletingLastPathComponent()
            .appendingPathComponent(".calopod-backup-\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: stagingURL) }

        guard fileManager.createFile(
            atPath: stagingURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LocalStateBackupError.invalidPath
        }
        let database = try CalopodDatabase(path: sourceURL.path)
        try database.backup(toPath: stagingURL.path)
        try makePrivate(stagingURL, fileManager: fileManager)
        let summary = try verifyPlain(at: stagingURL.path, fileManager: fileManager)
        let sealedURL = stagingURL.appendingPathExtension("sealed")
        defer { try? fileManager.removeItem(at: sealedURL) }
        let sealed = try BackupEncryption.seal(try Data(contentsOf: stagingURL), secrets: secrets)
        guard fileManager.createFile(
            atPath: sealedURL.path,
            contents: sealed,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LocalStateBackupError.invalidPath
        }
        try fileManager.moveItem(at: sealedURL, to: backupURL)
        return LocalStateBackupSummary(migrationCount: summary.migrationCount, isEncrypted: true)
    }

    /// Checks an encrypted or older plain backup. Encrypted files are opened in a private
    /// temporary copy that is removed afterwards.
    public static func verify(
        at backupPath: String,
        secrets: any SecretStore,
        fileManager: FileManager = .default
    ) throws -> LocalStateBackupSummary {
        let backupURL = try existingRegularFile(
            at: backupPath,
            missing: .backupInvalid,
            fileManager: fileManager
        )
        try requirePrivate(backupURL, fileManager: fileManager)
        guard try BackupEncryption.isEncrypted(backupURL) else {
            return try verifyPlain(at: backupURL.path, fileManager: fileManager)
        }
        let plainURL = backupURL.deletingLastPathComponent()
            .appendingPathComponent(".calopod-verify-\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: plainURL) }
        try writeDecrypted(backupURL, to: plainURL, secrets: secrets, fileManager: fileManager)
        let summary = try verifyPlain(at: plainURL.path, fileManager: fileManager)
        return LocalStateBackupSummary(migrationCount: summary.migrationCount, isEncrypted: true)
    }

    private static func writeDecrypted(
        _ backupURL: URL,
        to plainURL: URL,
        secrets: any SecretStore,
        fileManager: FileManager
    ) throws {
        let plain = try BackupEncryption.open(try Data(contentsOf: backupURL), secrets: secrets)
        guard fileManager.createFile(
            atPath: plainURL.path,
            contents: plain,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw LocalStateBackupError.invalidPath
        }
    }

    private static func requirePrivate(_ url: URL, fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw LocalStateBackupError.backupNotPrivate
        }
    }

    private static func verifyPlain(
        at backupPath: String,
        fileManager: FileManager
    ) throws -> LocalStateBackupSummary {
        let backupURL = try existingRegularFile(
            at: backupPath,
            missing: .backupInvalid,
            fileManager: fileManager
        )
        try requirePrivate(backupURL, fileManager: fileManager)

        var configuration = Configuration()
        configuration.readonly = true
        let database = try DatabaseQueue(path: backupURL.path, configuration: configuration)
        return try database.read { database in
            let integrity = try String.fetchAll(database, sql: "PRAGMA integrity_check")
            guard integrity == ["ok"] else { throw LocalStateBackupError.backupInvalid }

            let migrations = try String.fetchAll(
                database,
                sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"
            )
            let supported = Set(CalopodDatabase.supportedMigrationIdentifiers)
            guard migrations.first == "v1_foundation" else {
                throw LocalStateBackupError.backupInvalid
            }
            guard migrations.allSatisfy(supported.contains) else {
                throw LocalStateBackupError.unsupportedSchema
            }

            let requiredTables = Set([
                "arms",
                "calendar_bindings",
                "configurations",
                "connections",
                "mirror_mappings",
            ])
            let tables = Set(try String.fetchAll(
                database,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
            ))
            guard requiredTables.isSubset(of: tables) else {
                throw LocalStateBackupError.backupInvalid
            }
            return LocalStateBackupSummary(migrationCount: migrations.count)
        }
    }

    public static func restore(
        from backupPath: String,
        to statePath: String,
        secrets: any SecretStore,
        fileManager: FileManager = .default
    ) throws -> LocalStateBackupSummary {
        let backupURL = try existingRegularFile(
            at: backupPath,
            missing: .backupInvalid,
            fileManager: fileManager
        )
        let stateURL = try absoluteFileURL(statePath)
        guard backupURL != stateURL else { throw LocalStateBackupError.invalidPath }
        _ = try verify(at: backupURL.path, secrets: secrets, fileManager: fileManager)

        let parent = stateURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LocalStateBackupError.invalidPath
        }
        // Recover an interrupted WAL writer before moving the current state.
        // The caller must exclude writers and readers for the whole restore.
        let hasSidecars = ["-wal", "-shm"].contains { fileManager.fileExists(atPath: stateURL.path + $0) }
        if hasSidecars {
            guard fileManager.fileExists(atPath: stateURL.path) else { throw LocalStateBackupError.stateBusy }
            var configuration = Configuration()
            configuration.busyMode = .timeout(2)
            let database = try DatabaseQueue(path: stateURL.path, configuration: configuration)
            do {
                try database.writeWithoutTransaction { database in
                    try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    guard try String.fetchOne(database, sql: "PRAGMA journal_mode = DELETE") == "delete" else {
                        throw LocalStateBackupError.stateBusy
                    }
                }
                try database.close()
            } catch {
                throw LocalStateBackupError.stateBusy
            }
            for suffix in ["-wal", "-shm"] where fileManager.fileExists(atPath: stateURL.path + suffix) {
                try fileManager.removeItem(atPath: stateURL.path + suffix)
            }
        }

        let token = UUID().uuidString
        let stagingURL = parent.appendingPathComponent(".calopod-restore-\(token).sqlite")
        let rollbackURL = parent.appendingPathComponent(".calopod-rollback-\(token).sqlite")
        var movedCurrentState = false
        defer {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: rollbackURL)
        }

        let isEncrypted = try BackupEncryption.isEncrypted(backupURL)
        if isEncrypted {
            try writeDecrypted(backupURL, to: stagingURL, secrets: secrets, fileManager: fileManager)
        } else {
            try fileManager.copyItem(at: backupURL, to: stagingURL)
        }
        try makePrivate(stagingURL, fileManager: fileManager)
        _ = try verifyPlain(at: stagingURL.path, fileManager: fileManager)

        if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.moveItem(at: stateURL, to: rollbackURL)
            movedCurrentState = true
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: stateURL)
            try makePrivate(stateURL, fileManager: fileManager)
            let summary = try verifyPlain(at: stateURL.path, fileManager: fileManager)
            if movedCurrentState {
                try fileManager.removeItem(at: rollbackURL)
                movedCurrentState = false
            }
            return LocalStateBackupSummary(migrationCount: summary.migrationCount, isEncrypted: isEncrypted)
        } catch {
            try? fileManager.removeItem(at: stateURL)
            if movedCurrentState {
                try? fileManager.moveItem(at: rollbackURL, to: stateURL)
                movedCurrentState = false
            }
            throw error
        }
    }

    private static func absoluteFileURL(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else { throw LocalStateBackupError.invalidPath }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private static func existingRegularFile(
        at path: String,
        missing: LocalStateBackupError,
        fileManager: FileManager
    ) throws -> URL {
        let url = try absoluteFileURL(path)
        guard fileManager.fileExists(atPath: url.path) else { throw missing }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LocalStateBackupError.invalidPath
        }
        return url
    }

    private static func newFileURL(
        at path: String,
        fileManager: FileManager
    ) throws -> URL {
        let url = try absoluteFileURL(path)
        guard !fileManager.fileExists(atPath: url.path) else {
            throw LocalStateBackupError.destinationExists
        }
        let parent = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LocalStateBackupError.invalidPath
        }
        return url
    }

    private static func makePrivate(_ url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
