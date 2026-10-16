import CalopodDomain
import CalopodStore
import Foundation

/// `.hold` means no change and is always allowed.
public struct ConflictDecision: Equatable, Sendable {
    public let sourceKeyHash: String
    public let choice: InboxConflictChoice

    public init(sourceKeyHash: String, choice: InboxConflictChoice) {
        self.sourceKeyHash = sourceKeyHash
        self.choice = choice
    }
}

public enum ConflictResolutionError: Error, Equatable, Sendable {
    case unknownEvent(String)
    case duplicateDecision(String)
    case choiceUnavailable(String)
}

/// Overlaps after applying every change, from local data only. Nothing is sent.
public struct ConflictResolutionPreview: Equatable, Sendable {
    public let changes: [ConflictDecision]
    public let unchanged: [String]
    public let conflictsBefore: Set<InboxConflictPair>
    public let conflictsAfter: Set<InboxConflictPair>
    /// False when a source is stale or partly read.
    public let isComplete: Bool

    public var resolved: Set<InboxConflictPair> { conflictsBefore.subtracting(conflictsAfter) }
    public var remaining: Set<InboxConflictPair> { conflictsBefore.intersection(conflictsAfter) }
    public var created: Set<InboxConflictPair> { conflictsAfter.subtracting(conflictsBefore) }
}

public enum ConflictResolutionPlanner {
    /// Rejects choices the event doesn't allow, then projects the combined result.
    public static func preview(
        _ decisions: [ConflictDecision],
        in snapshot: InboxContextSnapshot,
        window: SyncWindow?,
        freshnessCutoff: Date
    ) throws -> ConflictResolutionPreview {
        var seen = Set<String>()
        var overrides: [String: EventResponseState] = [:]
        var changes: [ConflictDecision] = []
        var unchanged: [String] = []
        for decision in decisions {
            let key = decision.sourceKeyHash
            guard seen.insert(key).inserted else { throw ConflictResolutionError.duplicateDecision(key) }
            guard let item = snapshot.events.first(where: { $0.event.sourceKeyHash == key }) else {
                throw ConflictResolutionError.unknownEvent(key)
            }
            guard InboxCalendarContextBuilder.choices(for: item, snapshot: snapshot)
                .choices.contains(decision.choice) else {
                throw ConflictResolutionError.choiceUnavailable(key)
            }
            if let response = decision.choice.response {
                overrides[key] = response
                changes.append(decision)
            } else {
                unchanged.append(key)
            }
        }
        let before = InboxConflictCalculator.analyze(snapshot, window: window, freshnessCutoff: freshnessCutoff)
        let after = InboxConflictCalculator.analyze(
            snapshot, window: window, freshnessCutoff: freshnessCutoff, responseOverrides: overrides
        )
        return ConflictResolutionPreview(
            changes: changes,
            unchanged: unchanged,
            conflictsBefore: before.pairs,
            conflictsAfter: after.pairs,
            isComplete: before.isComplete && after.isComplete
        )
    }
}
