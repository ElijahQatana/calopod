import Foundation

/// What each published record holds. The raw value is the `kind` field on the CloudKit record.
public enum SnapshotKind: String, Codable, Sendable {
    case inboxItem = "inbox-item"
    case availabilityDay = "availability-day"
    case calendars
    case syncStatus = "sync-status"
    case calendarDay = "calendar-day"
}

/// Names of the one CloudKit record type and zone the Mac writes. Production record types can
/// never be removed, so this stays small: everything else lives inside the `payload` bytes.
public enum SnapshotRemote {
    public static let containerIdentifier = "iCloud.pro.elijahquintana.calopod"
    public static let zoneName = "Snapshots"
    public static let recordType = "Snapshot"

    public enum Field {
        public static let kind = "kind"
        public static let schemaVersion = "schemaVersion"
        public static let publishedAt = "publishedAt"
        public static let payload = "payload"
    }
}

/// One record ready to upload. `recordName` is the record's own id, so a republish replaces it.
public struct SnapshotPayload: Equatable, Sendable {
    public let recordName: String
    public let kind: SnapshotKind
    public let schemaVersion: Int
    public let publishedAt: Date
    public let bytes: Data

    public init(recordName: String, kind: SnapshotKind, schemaVersion: Int, publishedAt: Date, bytes: Data) {
        self.recordName = recordName
        self.kind = kind
        self.schemaVersion = schemaVersion
        self.publishedAt = publishedAt
        self.bytes = bytes
    }

    public init<Record: SnapshotRecord>(_ record: Record, kind: SnapshotKind, at date: Date) throws {
        self.init(
            recordName: record.id, kind: kind, schemaVersion: SnapshotSchema.currentVersion, publishedAt: date,
            bytes: try SnapshotCoding.encode(SnapshotEnvelope(generatedAt: date, record: record)))
    }
}

/// Where snapshots go. The Mac app has the CloudKit one; tests use the in-memory one.
public protocol SnapshotPublisher: Sendable {
    /// Makes the remote hold exactly these records: new and changed ones are saved, any other is removed.
    func replaceAll(with records: [SnapshotPayload]) async throws
    /// Removes everything that was published.
    func deleteAll() async throws
}

/// Keeps records in memory, and can be told to fail, for tests.
public actor InMemorySnapshotPublisher: SnapshotPublisher {
    public struct Failure: Error, Equatable {
        public init() {}
    }

    public private(set) var records: [String: SnapshotPayload] = [:]
    public private(set) var replaceCount = 0
    public private(set) var deleteCount = 0
    public var failure: Failure?

    public init() {}

    public func setFailing(_ failing: Bool) { failure = failing ? Failure() : nil }

    public func replaceAll(with records: [SnapshotPayload]) throws {
        if let failure { throw failure }
        replaceCount += 1
        self.records = Dictionary(records.map { ($0.recordName, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func deleteAll() throws {
        if let failure { throw failure }
        deleteCount += 1
        records = [:]
    }
}
