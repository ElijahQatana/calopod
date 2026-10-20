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

/// How one finished sync run ended.
public struct SyncRunMark: Codable, Equatable, Sendable {
    public let at: Date
    public let failed: Bool

    public init(at: Date, failed: Bool) {
        self.at = at
        self.failed = failed
    }
}

/// When the Mac last looked at one calendar.
public struct CalendarUpdate: Codable, Equatable, Sendable {
    public let calendarID: String
    public let at: Date

    public init(calendarID: String, at: Date) {
        self.calendarID = calendarID
        self.at = at
    }
}

public struct SyncStatus: SnapshotRecord {
    public static let recordID = "sync-status"

    public let lastSyncAt: Date?
    public let issues: [SyncIssue]
    /// The most recent finished runs, oldest first. Nil in a feed from an older Mac.
    public let runs: [SyncRunMark]?
    /// Nil in a feed from an older Mac.
    public let calendarUpdates: [CalendarUpdate]?

    public var id: String { Self.recordID }

    public init(
        lastSyncAt: Date?, issues: [SyncIssue] = [], runs: [SyncRunMark]? = nil, calendarUpdates: [CalendarUpdate]? = nil
    ) {
        self.lastSyncAt = lastSyncAt
        self.issues = issues
        self.runs = runs
        self.calendarUpdates = calendarUpdates
    }

    private enum CodingKeys: String, CodingKey { case lastSyncAt, issues, runs, calendarUpdates }
}
