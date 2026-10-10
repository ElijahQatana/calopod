import CalopodDomain
import CalopodStore
import Foundation

public enum InboxReviewOutcome: String, Codable, Sendable {
    case hold, confirmed, failed, unknown, unavailable, stale
}

public struct InboxReviewAction: Codable, Equatable, Sendable {
    public let id: String
    public let revision: Int64?
    public let before: InboxContextSnapshot
    public var accounted = false

    public init(id: String, revision: Int64?, before: InboxContextSnapshot) {
        self.id = id
        self.revision = revision
        self.before = before
    }
}

public struct InboxReviewEntry: Codable, Equatable, Sendable {
    public let sourceKeyHash: String
    public let startingRevision: Int64?
    public var actions: [InboxReviewAction] = []
    public var outcome: InboxReviewOutcome?
    public var response: EventResponseState?

    public init(sourceKeyHash: String, startingRevision: Int64?) {
        self.sourceKeyHash = sourceKeyHash
        self.startingRevision = startingRevision
    }
}

public struct InboxReviewSummary: Codable, Equatable, Sendable {
    public let yes: Int
    public let no: Int
    public let maybe: Int
    public let hold: Int
    public let failed: Int
    public let unknown: Int
    public let unavailable: Int
    public let stale: Int
    public let remainingQueueItems: Int
    public let remainingInboxItems: Int
    public let createdConflicts: Int
    public let remainingConflicts: Int
    public let contextIsComplete: Bool
    public let attributionIsComplete: Bool
    public var queueReviewed: Bool { remainingQueueItems == 0 }
    public var inboxResolved: Bool { remainingInboxItems == 0 && remainingConflicts == 0 && contextIsComplete && unknown == 0 }
}

/// A fixed queue. Refreshes change cards and outstanding counts, never membership.
public struct InboxReviewSession: Codable, Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public let filter: InboxAttentionFilter
    public let settings: InboxContextSettings
    public let displayTimeZoneIdentifier: String?
    public var entries: [InboxReviewEntry]
    public let queueCount: Int
    public let originalOccurrenceKeys: Set<String>
    public var cursor = 0
    public var metrics: InboxConflictMetrics
    public var lastSnapshot: InboxContextSnapshot
    public var summary: InboxReviewSummary?

    public init(snapshot: InboxContextSnapshot, filter: InboxAttentionFilter, settings: InboxContextSettings,
                metricsWindow: SyncWindow, freshnessCutoff: Date, now: Date = Date(),
                id: String = UUID().uuidString.lowercased(), displayTimeZoneIdentifier: String? = nil) {
        self.id = id
        startedAt = now
        self.filter = filter
        self.settings = settings
        self.displayTimeZoneIdentifier = displayTimeZoneIdentifier
        entries = InboxAttentionQuery.evaluate(snapshot, filter: filter, freshnessCutoff: freshnessCutoff).rows.map {
            InboxReviewEntry(sourceKeyHash: $0.item.event.sourceKeyHash, startingRevision: $0.item.observation?.revision)
        }
        queueCount = entries.count
        originalOccurrenceKeys = Set(snapshot.events.map { $0.event.sourceKeyHash })
        metrics = InboxConflictMetrics(starting: snapshot, window: metricsWindow, freshnessCutoff: freshnessCutoff)
        lastSnapshot = snapshot
    }

    public var hasUnresolvedActions: Bool { entries.contains { $0.actions.contains { !$0.accounted } } }

    public mutating func advance() {
        while cursor < queueCount && entries[cursor].outcome != nil && entries[cursor].outcome != .stale { cursor += 1 }
    }

    public mutating func updateSummary(freshnessCutoff: Date) {
        let attention = InboxAttentionQuery.evaluate(lastSnapshot, freshnessCutoff: freshnessCutoff)
        let uncertain = entries.filter { [.failed, .unknown, .unavailable, .stale].contains($0.outcome) }.map(\.sourceKeyHash)
        func count(_ outcome: InboxReviewOutcome) -> Int { entries.filter { $0.outcome == outcome }.count }
        func response(_ response: EventResponseState) -> Int {
            entries.filter { $0.outcome == .confirmed && $0.response == response }.count
        }
        summary = InboxReviewSummary(yes: response(.accepted), no: response(.declined), maybe: response(.tentative),
            hold: count(.hold), failed: count(.failed), unknown: count(.unknown), unavailable: count(.unavailable), stale: count(.stale),
            remainingQueueItems: entries.prefix(queueCount).filter { $0.outcome == nil || $0.outcome == .stale }.count,
            remainingInboxItems: Set(attention.rows.map { $0.item.event.sourceKeyHash }).union(uncertain).count,
            createdConflicts: metrics.createdPairs.count, remainingConflicts: metrics.remainingPairs.count,
            contextIsComplete: metrics.isComplete && attention.analysis.isComplete,
            attributionIsComplete: metrics.attributionIsComplete)
    }
}
