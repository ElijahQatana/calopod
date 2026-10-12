import CalopodDomain
import CalopodStore
import Foundation

public struct InboxConflictPair: Hashable, Codable, Sendable, Comparable {
    public let first: String
    public let second: String

    public init(_ a: String, _ b: String) {
        first = min(a, b)
        second = max(a, b)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.first, lhs.second) < (rhs.first, rhs.second)
    }

    public func contains(_ key: String) -> Bool { first == key || second == key }
}

public struct InboxConflict: Equatable, Sendable {
    public let pair: InboxConflictPair
    public let overlap: SyncWindow
    public let isConfirmed: Bool
}

public enum InboxContextWarningKind: String, Sendable {
    case noSelectedSources, unknownSource, staleSource, incompleteCoverage
    case unknownAvailability, unknownResponse, unprovenDuplicate, unconfirmedPresence
}

public struct InboxContextWarning: Equatable, Sendable {
    public let kind: InboxContextWarningKind
    public let bindingID: String?
    public let sourceKeyHash: String?
}

public struct InboxConflictAnalysis: Equatable, Sendable {
    public let conflicts: [InboxConflict]
    public let warnings: [InboxContextWarning]
    public var isComplete: Bool {
        !warnings.contains { [.noSelectedSources, .unknownSource, .staleSource, .incompleteCoverage, .unknownAvailability, .unconfirmedPresence].contains($0.kind) }
    }
    public var pairs: Set<InboxConflictPair> { Set(conflicts.filter(\.isConfirmed).map(\.pair)) }
}

/// Conflict inputs are already normalized instants, including complete local
/// days for all-day events. Preserve those endpoints; never round to UTC days.
public enum InboxConflictCalculator {
    public static func analyze(
        _ snapshot: InboxContextSnapshot, window: SyncWindow?, freshnessCutoff: Date,
        responseOverride: (key: String, state: EventResponseState)? = nil
    ) -> InboxConflictAnalysis {
        let sources = Set(snapshot.sources.map(\.bindingID))
        let unconfirmed = Set(snapshot.events.filter { !$0.isPresenceConfirmed }.map(\.event.sourceKeyHash))
        let events = snapshot.events.map(\.event).filter { event in
            sources.contains(event.calendarBindingID) && !event.isCancelled
                && event.startsAt < event.endsAt
                && (window.map { event.endsAt > $0.start && event.startsAt < $0.end } ?? true)
        }
        let blocking = events.filter {
            let response = responseOverride?.key == $0.sourceKeyHash ? responseOverride!.state : $0.currentUserResponse.state
            return response != .declined && $0.availability != "free"
        }.sorted { ($0.startsAt, $0.sourceKeyHash) < ($1.startsAt, $1.sourceKeyHash) }
        var conflicts: [InboxConflict] = []
        for (index, event) in blocking.enumerated() {
            for other in blocking.dropFirst(index + 1) {
                if other.startsAt >= event.endsAt { break }
                guard other.sourceKeyHash != event.sourceKeyHash else { continue }
                let start = max(event.startsAt, other.startsAt)
                let end = min(event.endsAt, other.endsAt)
                if start < end, let overlap = try? SyncWindow(start: start, end: end) {
                    conflicts.append(InboxConflict(pair: InboxConflictPair(event.sourceKeyHash, other.sourceKeyHash),
                                                   overlap: overlap,
                                                   isConfirmed: !unconfirmed.contains(event.sourceKeyHash) && !unconfirmed.contains(other.sourceKeyHash)))
                }
            }
        }
        var warnings: [InboxContextWarning] = []
        if snapshot.sources.isEmpty {
            warnings.append(InboxContextWarning(kind: .noSelectedSources, bindingID: nil, sourceKeyHash: nil))
        }
        for source in snapshot.sources.sorted(by: { $0.bindingID < $1.bindingID }) {
            if source.healthStatus == nil || source.coverage == nil || !["google", "microsoft", "eventkit", "ics"].contains(source.provider) {
                warnings.append(InboxContextWarning(kind: .unknownSource, bindingID: source.bindingID, sourceKeyHash: nil))
            }
            if source.staleSince != nil || source.healthStatus != nil && source.healthStatus != "healthy"
                || source.coverage.map({ $0.observedAt < freshnessCutoff }) == true {
                warnings.append(InboxContextWarning(kind: .staleSource, bindingID: source.bindingID, sourceKeyHash: nil))
            }
            if source.coverage.map({ coverage in
                window.map { coverage.startsAt > $0.start || coverage.endsAt < $0.end } ?? false
            }) != false {
                warnings.append(InboxContextWarning(kind: .incompleteCoverage, bindingID: source.bindingID, sourceKeyHash: nil))
            }
            if snapshot.unprovenDuplicateBindingIDs.contains(source.bindingID) {
                warnings.append(InboxContextWarning(kind: .unprovenDuplicate, bindingID: source.bindingID, sourceKeyHash: nil))
            }
        }
        for event in events.sorted(by: { $0.sourceKeyHash < $1.sourceKeyHash }) {
            if unconfirmed.contains(event.sourceKeyHash) {
                warnings.append(InboxContextWarning(kind: .unconfirmedPresence, bindingID: event.calendarBindingID, sourceKeyHash: event.sourceKeyHash))
            }
            if !["free", "busy", "tentative", "unavailable"].contains(event.availability) {
                warnings.append(InboxContextWarning(kind: .unknownAvailability, bindingID: event.calendarBindingID, sourceKeyHash: event.sourceKeyHash))
            }
            if event.currentUserResponse.state == .unknown {
                warnings.append(InboxContextWarning(kind: .unknownResponse, bindingID: event.calendarBindingID, sourceKeyHash: event.sourceKeyHash))
            }
        }
        return InboxConflictAnalysis(conflicts: conflicts.sorted { $0.pair < $1.pair }, warnings: warnings)
    }

    /// The default attention query can union these IDs with its other reasons.
    /// Reviewing or acknowledging does not affect this conflict-only selection.
    public static func conflictOnlyEvents(
        in snapshot: InboxContextSnapshot, analysis: InboxConflictAnalysis
    ) -> [InboxContextEvent] {
        let keys = Set(analysis.conflicts.filter(\.isConfirmed).flatMap { [$0.pair.first, $0.pair.second] })
        return snapshot.events.filter { keys.contains($0.event.sourceKeyHash) }.sorted {
            ($0.event.startsAt, $0.event.sourceKeyHash) < ($1.event.startsAt, $1.event.sourceKeyHash)
        }
    }

    public static func group(containing key: String, conflicts: [InboxConflict]) -> Set<String> {
        var keys: Set<String> = [key]
        var changed = true
        while changed {
            let previous = keys
            for conflict in conflicts where keys.contains(conflict.pair.first) || keys.contains(conflict.pair.second) {
                keys.insert(conflict.pair.first)
                keys.insert(conflict.pair.second)
            }
            changed = previous != keys
        }
        return keys
    }
}

/// Shared reason vocabulary; the remaining attention-query behavior is built
/// separately from this context model.
public enum InboxAttentionReason: String, Codable, Sendable {
    case needsResponse = "needs-response"
    case maybe
    case changedAfterResponse = "changed-after-response"
    case conflict
}
