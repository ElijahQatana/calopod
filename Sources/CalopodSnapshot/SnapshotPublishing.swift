import Foundation

/// What each published record holds. The raw value is the `kind` field on the CloudKit record.
public enum SnapshotKind: String, Codable, Sendable {
    case inboxItem = "inbox-item"
    case availabilityDay = "availability-day"
    case calendars
    case syncStatus = "sync-status"
    case calendarDay = "calendar-day"
    case reminderSettings = "reminder-settings"
}

/// How much of the feed a copy holds. Busy has no titles, places, notes, links or calendar names.
public enum SnapshotLevel: String, Codable, Sendable {
    case full
    case busy

    public func keeps(_ kind: SnapshotKind) -> Bool {
        switch self {
        case .full: true
        case .busy: kind == .availabilityDay || kind == .syncStatus
        }
    }
}

/// Names of the one CloudKit record type and the zones the Mac writes. Production record types can
/// never be removed, so this stays small: everything else lives inside the `payload` bytes.
public enum SnapshotRemote {
    public static let containerIdentifier = "iCloud.pro.elijahquintana.calopod"
    public static let recordType = "Snapshot"
    /// The zone every Mac used before each got its own.
    public static let legacyZoneName = "Snapshots"

    private static let zonePrefix = "Snapshots-"
    private static let busySuffix = "-busy"

    public static func zoneName(mac: String, level: SnapshotLevel = .full) -> String {
        zonePrefix + mac + (level == .busy ? busySuffix : "")
    }

    /// Nil for a zone that is not a feed. The old zone has no Mac id.
    public static func feed(inZone name: String) -> (mac: String?, level: SnapshotLevel)? {
        if name == legacyZoneName { return (nil, .full) }
        guard name.hasPrefix(zonePrefix) else { return nil }
        var mac = String(name.dropFirst(zonePrefix.count))
        var level = SnapshotLevel.full
        if mac.hasSuffix(busySuffix) {
            mac = String(mac.dropLast(busySuffix.count))
            level = .busy
        }
        return mac.isEmpty ? nil : (mac, level)
    }

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
    /// Makes the zone hold exactly these records: new and changed ones are saved, any other is removed.
    func replaceAll(with records: [SnapshotPayload], inZone zone: String) async throws
    /// Removes a zone, its records and any share. A missing zone is fine.
    func deleteZone(_ zone: String) async throws
}

/// Keeps records in memory, and can be told to fail, for tests.
public actor InMemorySnapshotPublisher: SnapshotPublisher {
    public struct Failure: Error, Equatable {
        public init() {}
    }

    public private(set) var zones: [String: [String: SnapshotPayload]] = [:]
    public private(set) var replaceCount = 0
    public private(set) var deleteCount = 0
    public private(set) var deletedZones: [String] = []
    public var failure: Failure?

    public init() {}

    public func setFailing(_ failing: Bool) { failure = failing ? Failure() : nil }

    public var records: [String: SnapshotPayload] {
        zones.first { SnapshotRemote.feed(inZone: $0.key)?.level == .full }?.value ?? [:]
    }

    public func records(inZone zone: String) -> [String: SnapshotPayload] { zones[zone] ?? [:] }

    public func replaceAll(with records: [SnapshotPayload], inZone zone: String) throws {
        if let failure { throw failure }
        replaceCount += 1
        zones[zone] = Dictionary(records.map { ($0.recordName, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func deleteZone(_ zone: String) throws {
        if let failure { throw failure }
        deleteCount += 1
        deletedZones.append(zone)
        zones[zone] = nil
    }
}
