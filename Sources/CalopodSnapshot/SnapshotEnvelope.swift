import Foundation

/// The schema version the Mac writes and this reader understands. Raise it when a record
/// changes in a way an older reader would misread. Adding fields does not need a bump.
public enum SnapshotSchema {
    public static let currentVersion = 1
}

public enum SnapshotError: Error, Equatable {
    /// The record was written by a newer Calopod than this reader supports.
    case newerVersion(found: Int, supported: Int)
}

/// A record that can be published on its own. The id is stable for the same underlying thing,
/// so a republish replaces the old record instead of adding another.
public protocol SnapshotRecord: Codable, Equatable, Sendable {
    var id: String { get }
}

/// Wraps a record with the schema version. The version is read before anything else, so a
/// record from a newer version is refused cleanly rather than failing on a field it moved.
public struct SnapshotEnvelope<Record: SnapshotRecord>: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let record: Record

    public init(generatedAt: Date, record: Record, schemaVersion: Int = SnapshotSchema.currentVersion) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.record = record
    }

    public var id: String { record.id }

    private enum CodingKeys: String, CodingKey { case schemaVersion, generatedAt, record }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version <= SnapshotSchema.currentVersion else {
            throw SnapshotError.newerVersion(found: version, supported: SnapshotSchema.currentVersion)
        }
        schemaVersion = version
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        record = try container.decode(Record.self, forKey: .record)
    }
}

public enum SnapshotCoding {
    public static func encode<Record: SnapshotRecord>(_ envelope: SnapshotEnvelope<Record>) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func decode<Record: SnapshotRecord>(
        _ type: Record.Type, from data: Data
    ) throws -> SnapshotEnvelope<Record> {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SnapshotEnvelope<Record>.self, from: data)
    }
}
