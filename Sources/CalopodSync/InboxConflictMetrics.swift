import CalopodDomain
import CalopodStore
import Foundation

public enum InboxConflictMetricsError: Error, Equatable {
    case invalidConfirmedResponse
    case responseNotObserved
}

/// Persisted with review sessions. Counts are lower
/// bounds when sources are incomplete; a zero never proves no conflicts then.
public struct InboxConflictMetrics: Codable, Equatable, Sendable {
    public let window: SyncWindow
    /// Events that ended by this time are left out of every count, as in the Inbox. Nil in older sessions.
    public let asOf: Date?
    public let startingIsComplete: Bool
    public let startingPairs: Set<InboxConflictPair>
    public private(set) var createdPairs: Set<InboxConflictPair> = []
    public private(set) var externalPairs: Set<InboxConflictPair> = []
    public private(set) var uncertainPairs: Set<InboxConflictPair> = []
    public private(set) var remainingPairs: Set<InboxConflictPair>
    public private(set) var isComplete: Bool
    public private(set) var attributionIsComplete: Bool

    public init(starting snapshot: InboxContextSnapshot, window: SyncWindow, freshnessCutoff: Date, asOf: Date? = nil) {
        self.window = window
        self.asOf = asOf
        let analysis = Self.analyze(snapshot, window: window, asOf: asOf, freshnessCutoff: freshnessCutoff)
        startingIsComplete = analysis.isComplete
        startingPairs = analysis.pairs
        remainingPairs = analysis.pairs
        isComplete = analysis.isComplete
        attributionIsComplete = analysis.isComplete
    }

    private static func analyze(_ snapshot: InboxContextSnapshot, window: SyncWindow, asOf: Date?, freshnessCutoff: Date) -> InboxConflictAnalysis {
        InboxConflictCalculator.analyze(
            InboxAttentionQuery.current(snapshot, asOf: asOf, freshnessCutoff: freshnessCutoff),
            window: window, freshnessCutoff: freshnessCutoff)
    }

    private func upcoming(_ snapshot: InboxContextSnapshot, _ freshnessCutoff: Date) -> InboxContextSnapshot {
        InboxAttentionQuery.current(snapshot, asOf: asOf, freshnessCutoff: freshnessCutoff)
    }

    /// Only the action layer's confirmed response belongs here. Intent, Hold,
    /// acknowledgement, failure, and unknown outcomes cannot create a count.
    /// Compare the validated pre-write snapshot with the complete post-write
    /// refresh, isolating the chosen response from simultaneous external edits.
    public mutating func recordConfirmedDecision(
        sourceKeyHash: String, response: EventResponseState,
        before: InboxContextSnapshot, after: InboxContextSnapshot, freshnessCutoff: Date
    ) throws {
        guard [.accepted, .tentative, .declined].contains(response) else {
            throw InboxConflictMetricsError.invalidConfirmedResponse
        }
        guard let original = before.events.first(where: { $0.event.sourceKeyHash == sourceKeyHash })?.event else {
            throw InboxConflictMetricsError.responseNotObserved
        }
        let updated = after.events.first(where: { $0.event.sourceKeyHash == sourceKeyHash })?.event
        guard updated?.currentUserResponse.state == response || updated == nil && response == .declined else {
            throw InboxConflictMetricsError.responseNotObserved
        }
        let prior = InboxConflictCalculator.analyze(upcoming(before, freshnessCutoff), window: window, freshnessCutoff: freshnessCutoff)
        let current = InboxConflictCalculator.analyze(upcoming(after, freshnessCutoff), window: window, freshnessCutoff: freshnessCutoff)
        let projected = InboxConflictCalculator.analyze(upcoming(before, freshnessCutoff), window: window, freshnessCutoff: freshnessCutoff,
                                                       responseOverride: (sourceKeyHash, response))
        let additions = current.pairs.subtracting(prior.pairs)
        let candidates = projected.pairs.subtracting(prior.pairs).intersection(additions)
        var attributable: Set<InboxConflictPair> = []
        var uncertain: Set<InboxConflictPair> = []
        if startingIsComplete && prior.isComplete && current.isComplete, let updated,
           sameOccupancy(original, updated, compareResponse: false) {
            for pair in candidates {
                let otherKey = pair.first == sourceKeyHash ? pair.second : pair.first
                if let oldOther = before.events.first(where: { $0.event.sourceKeyHash == otherKey })?.event,
                   let newOther = after.events.first(where: { $0.event.sourceKeyHash == otherKey })?.event,
                   sameOccupancy(oldOther, newOther, compareResponse: true) {
                    attributable.insert(pair)
                } else { uncertain.insert(pair) }
            }
        } else {
            uncertain = additions
        }
        createdPairs.formUnion(attributable.subtracting(startingPairs))
        uncertainPairs.formUnion(uncertain)
        externalPairs.formUnion(additions.subtracting(attributable).subtracting(uncertain))
        remainingPairs = current.pairs
        isComplete = current.isComplete
        attributionIsComplete = attributionIsComplete && prior.isComplete && current.isComplete && uncertain.isEmpty
    }

    public mutating func recordUncertainDecision(after: InboxContextSnapshot, freshnessCutoff: Date) {
        let current = InboxConflictCalculator.analyze(upcoming(after, freshnessCutoff), window: window, freshnessCutoff: freshnessCutoff)
        uncertainPairs.formUnion(current.pairs.subtracting(remainingPairs))
        remainingPairs = current.pairs
        isComplete = false
        attributionIsComplete = false
    }

    /// A refresh without a confirmed review response cannot increase created.
    public mutating func observeExternalChanges(
        before: InboxContextSnapshot, after: InboxContextSnapshot, freshnessCutoff: Date
    ) {
        let prior = InboxConflictCalculator.analyze(upcoming(before, freshnessCutoff), window: window, freshnessCutoff: freshnessCutoff)
        let current = InboxConflictCalculator.analyze(upcoming(after, freshnessCutoff), window: window, freshnessCutoff: freshnessCutoff)
        let additions = current.pairs.subtracting(prior.pairs)
        if prior.isComplete && current.isComplete { externalPairs.formUnion(additions) }
        else { uncertainPairs.formUnion(additions) }
        remainingPairs = current.pairs
        isComplete = current.isComplete
        attributionIsComplete = attributionIsComplete && prior.isComplete && current.isComplete
    }
}

private func sameOccupancy(_ lhs: StoredNormalizedInstance, _ rhs: StoredNormalizedInstance, compareResponse: Bool) -> Bool {
    lhs.sourceKeyHash == rhs.sourceKeyHash && lhs.calendarBindingID == rhs.calendarBindingID
        && lhs.startsAt == rhs.startsAt && lhs.endsAt == rhs.endsAt && lhs.isAllDay == rhs.isAllDay
        && lhs.availability == rhs.availability && lhs.isCancelled == rhs.isCancelled
        && (!compareResponse || lhs.currentUserResponse.state == rhs.currentUserResponse.state)
}
