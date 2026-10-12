import Foundation
import GRDB

/// Owns the single GRDB connection to Calopod's SQLite operational ledger
/// and runs schema migrations on writable opens. Every store type (`LocalStateRepository`
/// and friends) reads and writes through this rather than opening its own
/// connection, so all access goes through one consistent migration state.
public final class CalopodDatabase: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(path: String, readonly: Bool = false) throws {
        var configuration = Configuration()
        configuration.readonly = readonly
        configuration.busyMode = .timeout(2)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            if !readonly {
                try database.execute(sql: "PRAGMA journal_mode = WAL")
            }
        }

        writer = try DatabaseQueue(path: path, configuration: configuration)
        if readonly {
            guard try writer.read({ try Self.migrator.hasCompletedMigrations($0) }) else {
                throw CalopodDatabaseError.migrationRequired
            }
        } else {
            try migrate()
        }
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrate()
    }

    /// An ephemeral, in-memory database for tests — same schema and
    /// migrations as the real thing, but nothing touches disk.
    public static func inMemory() throws -> CalopodDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        return try CalopodDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    public func migrate() throws {
        try Self.migrator.migrate(writer)
    }

    public func read<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try writer.read(body)
    }

    public func write<Value>(_ body: (Database) throws -> Value) throws -> Value {
        try writer.write(body)
    }

    public func writeTransaction(_ body: (Database) throws -> Void) throws {
        try writer.write { database in
            try body(database)
        }
    }

    public func backup(toPath path: String) throws {
        let destination = try DatabaseQueue(path: path)
        try writer.backup(to: destination)
        // A backup travels as one file, even when its source uses WAL.
        try destination.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA journal_mode = DELETE")
        }
    }
}

public enum CalopodDatabaseError: Error, Equatable, Sendable {
    case migrationRequired
}
