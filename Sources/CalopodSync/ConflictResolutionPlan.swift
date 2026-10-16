import CalopodDomain
import CalopodStore
import Foundation

/// One explicit choice for one event. `.hold` means no change and is always allowed.
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
    /// The choice is not offered for this event, for example because the provider can't reply.
    case choiceUnavailable(String)
}

/// What the overlaps would look like if every change were applied. Computed from local data only;
/// nothing is sent. Shared by the Mac screen and, later, iPhone.
public struct ConflictResolutionPreview: Equatable, Sendable {
    /// Decisions that would send a reply, in the order given.
    public let changes: [ConflictDecision]
    /// Events left alone.
    public let unchanged: [String]
    public let conflictsBefore: Set<InboxConflictPair>
    public let conflictsAfter: Set<InboxConflictPair>
    /// False when a source is stale or partly read, so a clean result can't be trusted.
    public let isComplete: Bool

    public var resolved: Set<InboxConflictPair> { conflictsBefore.subtracting(conflictsAfter) }
    public var remaining: Set<InboxConflictPair> { conflictsBefore.intersection(conflictsAfter) }
    public var created: Set<InboxConflictPair> { conflictsAfter.subtracting(conflictsBefore) }
}

public enum ConflictResolutionPlanner {
    /// Checks every decision against what the event actually allows, then projects the combined
    /// result. Throws instead of dropping a decision.
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
