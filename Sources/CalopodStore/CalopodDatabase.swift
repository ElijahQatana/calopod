import Foundation
import GRDB

public final class CalopodDatabase: @unchecked Sendable {
    private let writer: any DatabaseWriter

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }

        writer = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try migrate()
    }

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
}
