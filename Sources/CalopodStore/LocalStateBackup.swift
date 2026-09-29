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
}

public struct LocalStateBackupSummary: Equatable, Sendable {
    public let migrationCount: Int

    public init(migrationCount: Int) {
        self.migrationCount = migrationCount
    }
}

public enum LocalStateBackup {
    public static func create(
        from sourcePath: String,
        at backupPath: String,
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

        let database = try CalopodDatabase(path: sourceURL.path)
        try database.backup(toPath: stagingURL.path)
        try makePrivate(stagingURL, fileManager: fileManager)
        let summary = try verify(at: stagingURL.path, fileManager: fileManager)
        try fileManager.moveItem(at: stagingURL, to: backupURL)
        return summary
    }

    public static func verify(
        at backupPath: String,
        fileManager: FileManager = .default
    ) throws -> LocalStateBackupSummary {
        let backupURL = try existingRegularFile(
            at: backupPath,
            missing: .backupInvalid,
            fileManager: fileManager
        )
        let attributes = try fileManager.attributesOfItem(atPath: backupURL.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0 else {
            throw LocalStateBackupError.backupNotPrivate
        }

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
        fileManager: FileManager = .default
    ) throws -> LocalStateBackupSummary {
        let backupURL = try existingRegularFile(
            at: backupPath,
            missing: .backupInvalid,
            fileManager: fileManager
        )
        let stateURL = try absoluteFileURL(statePath)
        guard backupURL != stateURL else { throw LocalStateBackupError.invalidPath }
        _ = try verify(at: backupURL.path, fileManager: fileManager)

        let parent = stateURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LocalStateBackupError.invalidPath
        }
        for suffix in ["-wal", "-shm"] where fileManager.fileExists(
            atPath: stateURL.path + suffix
        ) {
            throw LocalStateBackupError.stateBusy
        }

        let token = UUID().uuidString
        let stagingURL = parent.appendingPathComponent(".calopod-restore-\(token).sqlite")
        let rollbackURL = parent.appendingPathComponent(".calopod-rollback-\(token).sqlite")
        var movedCurrentState = false
        defer {
            try? fileManager.removeItem(at: stagingURL)
            try? fileManager.removeItem(at: rollbackURL)
        }

        try fileManager.copyItem(at: backupURL, to: stagingURL)
        try makePrivate(stagingURL, fileManager: fileManager)
        _ = try verify(at: stagingURL.path, fileManager: fileManager)

        if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.moveItem(at: stateURL, to: rollbackURL)
            movedCurrentState = true
        }
        do {
            try fileManager.moveItem(at: stagingURL, to: stateURL)
            try makePrivate(stateURL, fileManager: fileManager)
            let summary = try verify(at: stateURL.path, fileManager: fileManager)
            if movedCurrentState {
                try fileManager.removeItem(at: rollbackURL)
                movedCurrentState = false
            }
            return summary
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
