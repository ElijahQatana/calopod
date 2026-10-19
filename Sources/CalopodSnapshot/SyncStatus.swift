import Foundation

public enum SyncIssueKind: String, Codable, Sendable {
    case failed
    case partial
    case stale
}

/// A problem the Mac wants the phone to mention. `calendarID` is nil when it affects everything.
public struct SyncIssue: Codable, Equatable, Sendable {
    public let kind: SyncIssueKind
    public let calendarID: String?
    public let since: Date?

    public init(kind: SyncIssueKind, calendarID: String? = nil, since: Date? = nil) {
        self.kind = kind
        self.calendarID = calendarID
        self.since = since
    }
}

public struct SyncStatus: SnapshotRecord {
    public static let recordID = "sync-status"

    public let lastSyncAt: Date?
    public let issues: [SyncIssue]

    public var id: String { Self.recordID }

    public init(lastSyncAt: Date?, issues: [SyncIssue] = []) {
        self.lastSyncAt = lastSyncAt
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey { case lastSyncAt, issues }
}
