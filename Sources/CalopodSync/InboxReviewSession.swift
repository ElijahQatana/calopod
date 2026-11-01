import CalopodDomain
import CalopodStore
import Foundation

public enum InboxReviewOutcome: String, Codable, Sendable {
    case hold, snoozed, confirmed, failed, unknown, unavailable, stale
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
    /// Overlapping pairs left, counted the way the Inbox counts them: ended events and copies are out.
    public let remainingConflicts: Int
    /// Overlapping pairs that existed when the review began and are gone now. Nil in older sessions.
    public var resolvedConflicts: Int?
    /// Events in those pairs, which is what the Inbox Conflicts filter lists. Nil in older sessions.
    public var remainingConflictEvents: Int?
    /// Nil in older sessions.
    public var snoozed: Int?
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
    public private(set) var queueCount: Int
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
        metrics = InboxConflictMetrics(starting: snapshot, window: metricsWindow, freshnessCutoff: freshnessCutoff, asOf: filter.asOf ?? now)
        lastSnapshot = snapshot
    }

    public var hasUnresolvedActions: Bool { entries.contains { $0.actions.contains { !$0.accounted } } }

    public mutating func advance() {
        while cursor < queueCount && entries[cursor].outcome != nil && entries[cursor].outcome != .stale { cursor += 1 }
    }

    /// Takes events that ended since the queue was made out of it. Held, answered and unclear events
    /// keep their place, so what was recorded is not lost; the queue and the cursor shrink to match.
    @discardableResult
    public mutating func dropEnded(in snapshot: InboxContextSnapshot, asOf: Date, freshnessCutoff: Date) -> Int {
        let known = Set(snapshot.events.map(\.event.sourceKeyHash))
        let current = Set(InboxAttentionQuery.current(snapshot, asOf: asOf, freshnessCutoff: freshnessCutoff).events.map(\.event.sourceKeyHash))
        let drop = Set(entries.prefix(queueCount).filter {
            ($0.outcome == nil || $0.outcome == .stale) && !$0.actions.contains { !$0.accounted }
                && known.contains($0.sourceKeyHash) && !current.contains($0.sourceKeyHash)
        }.map(\.sourceKeyHash))
        guard !drop.isEmpty else { return 0 }
        let before = entries.prefix(cursor).filter { drop.contains($0.sourceKeyHash) }.count
        entries.removeAll { drop.contains($0.sourceKeyHash) }
        queueCount -= drop.count
        cursor -= before
        summary = nil
        return drop.count
    }

    public mutating func updateSummary(freshnessCutoff: Date, asOf: Date? = nil) {
        let attention = InboxAttentionQuery.evaluate(lastSnapshot, filter: InboxAttentionFilter(asOf: asOf), freshnessCutoff: freshnessCutoff)
        let known = Set(lastSnapshot.events.map(\.event.sourceKeyHash))
        let current = Set(InboxAttentionQuery.current(lastSnapshot, asOf: asOf, freshnessCutoff: freshnessCutoff).events.map(\.event.sourceKeyHash))
        // A failed or unclear reply keeps its event counted, unless the event has since ended.
        let uncertain = entries.filter { [.failed, .unknown, .unavailable, .stale].contains($0.outcome) }.map(\.sourceKeyHash)
            .filter { !known.contains($0) || current.contains($0) }
        func count(_ outcome: InboxReviewOutcome) -> Int { entries.filter { $0.outcome == outcome }.count }
        func response(_ response: EventResponseState) -> Int {
            entries.filter { $0.outcome == .confirmed && $0.response == response }.count
        }
        summary = InboxReviewSummary(yes: response(.accepted), no: response(.declined), maybe: response(.tentative),
            hold: count(.hold), failed: count(.failed), unknown: count(.unknown), unavailable: count(.unavailable), stale: count(.stale),
            remainingQueueItems: entries.prefix(queueCount).filter { $0.outcome == nil || $0.outcome == .stale }.count,
            remainingInboxItems: Set(attention.rows.map { $0.item.event.sourceKeyHash }).union(uncertain).count,
            createdConflicts: metrics.createdPairs.count, remainingConflicts: attention.analysis.pairs.count,
            resolvedConflicts: metrics.startingPairs.subtracting(metrics.remainingPairs).count,
            remainingConflictEvents: attention.rows.filter { !$0.conflicts.isEmpty }.count, snoozed: count(.snoozed),
            contextIsComplete: metrics.isComplete && attention.analysis.isComplete,
            attributionIsComplete: metrics.attributionIsComplete)
    }
}

/// One row of the review summary, worded once so the app and the command line show the same thing.
public struct InboxReviewSummaryLine: Equatable, Sendable {
    public enum Emphasis: Sendable { case caution, bad }
    public let label: String
    public let value: Int
    public let detail: String?
    /// What the row means, in a sentence.
    public let help: String
    public let emphasis: Emphasis?
    /// Rows of one section sit together; a new section starts a new group.
    public let section: Int
}

extension InboxReviewSummary {
    public var lines: [InboxReviewSummaryLine] {
        func line(_ label: String, _ value: Int, _ help: String, detail: String? = nil, emphasis: InboxReviewSummaryLine.Emphasis? = nil,
                  section: Int) -> InboxReviewSummaryLine {
            .init(label: label, value: value, detail: detail, help: help, emphasis: value > 0 ? emphasis : nil, section: section)
        }
        let notSent = failed + unavailable + stale
        let parts = [(failed, "Failed"), (unavailable, "Unavailable"), (stale, "Changed first")].filter { $0.0 > 0 }.map { "\($0.1) \($0.0)" }
        var rows = [
            line("Replies recorded", yes + maybe + no,
                 "Answers the calendar confirmed during this review.",
                 detail: "Yes \(yes) · Maybe \(maybe) · No \(no)", section: 0),
            line("Held", hold, "Skipped for now. Nothing was sent, and the event stays in your Inbox.", section: 0),
            line("Outcome unclear", unknown, "A reply may or may not have reached the calendar. It is never sent again; Resume checks it.",
                 emphasis: .caution, section: 0),
        ]
        if let snoozed, snoozed > 0 {
            rows.insert(line("Snoozed", snoozed, "Put away until later. Nothing was sent.", section: 0), at: 2)
        }
        if notSent > 0 {
            rows.append(line("Not sent", notSent, "The calendar did not take the reply, or the event changed first. Nothing was changed.",
                             detail: parts.joined(separator: " · "), section: 0))
        }
        rows += [
            line("Overlapping pairs resolved", resolvedConflicts ?? 0,
                 "Pairs of events that shared time when the review began and no longer do.", section: 1),
            line("New overlapping pairs", createdConflicts,
                 "Pairs that appeared because of an answer given in this review.", emphasis: .bad, section: 1),
            line("Overlapping pairs left", remainingConflicts,
                 "Two events that share time make one pair. The Inbox Conflicts filter lists the events in these pairs.",
                 detail: remainingConflictEvents.map { "\($0) event\($0 == 1 ? "" : "s")" }, section: 1),
            line("Events still in your Inbox", remainingInboxItems,
                 "The same number as All in the Inbox. Ended events and Calopod copies are not counted.", section: 1),
        ]
        return rows
    }
}
