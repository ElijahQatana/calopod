import CalopodDomain
import CalopodStore
import Foundation

public struct InboxAttentionFilter: Codable, Equatable, Sendable {
    public let window: SyncWindow?
    public let excludeMaybe: Bool
    public let conflictsOnly: Bool

    /// A nil window includes all relevant retained occurrences, not just today.
    /// CLI date parsing supplies normalized local-day or timestamp boundaries.
    public init(window: SyncWindow? = nil, excludeMaybe: Bool = false, conflictsOnly: Bool = false) {
        self.window = window
        self.excludeMaybe = excludeMaybe
        self.conflictsOnly = conflictsOnly
    }
}

/// Private local detail for one source occurrence, with every applicable reason.
public struct InboxAttentionRow: Equatable, Sendable {
    public let item: InboxContextEvent
    public let source: InboxContextSource
    public let reasons: [InboxAttentionReason]
    /// Uncertain order must not be rendered as a proven change after an RSVP.
    public let changeTiming: InboxResponseTiming?
    public let conflicts: [InboxConflict]
}

public struct InboxAttentionResult: Equatable, Sendable {
    public let rows: [InboxAttentionRow]
    /// Per-source retained coverage and freshness, including sources with no rows.
    public let sources: [InboxContextSource]
    public let analysisWindow: SyncWindow?
    public let analysis: InboxConflictAnalysis
}

/// A pure local query. Listing and filtering neither acknowledge nor write.
public enum InboxAttentionQuery {
    public static func evaluate(
        _ snapshot: InboxContextSnapshot, filter: InboxAttentionFilter = InboxAttentionFilter(),
        freshnessCutoff: Date
    ) -> InboxAttentionResult {
        // Analyze complete current intervals before filtering rows. A moved
        // event matching its old date can still conflict at its new date.
        let starts = snapshot.sources.compactMap { $0.coverage?.startsAt }
            + snapshot.events.map { $0.event.startsAt }
            + (filter.window.map { [$0.start] } ?? [])
        let ends = snapshot.sources.compactMap { $0.coverage?.endsAt }
            + snapshot.events.map { $0.event.endsAt }
            + (filter.window.map { [$0.end] } ?? [])
        let window = starts.min().flatMap { start in
            ends.max().flatMap { try? SyncWindow(start: start, end: $0) }
        }
        let analysis = InboxConflictCalculator.analyze(snapshot, window: window, freshnessCutoff: freshnessCutoff)
        let confirmed = analysis.conflicts.filter(\.isConfirmed)
        var rows: [InboxAttentionRow] = []
        for item in snapshot.events {
            let event = item.event
            guard !event.isCancelled, item.observation?.tombstone == nil,
                  let source = snapshot.sources.first(where: { $0.bindingID == event.calendarBindingID }) else { continue }
            if filter.excludeMaybe && event.currentUserResponse.state == .tentative { continue }
            if let range = filter.window {
                let currentMatches = event.endsAt > range.start && event.startsAt < range.end
                let previousMatches = item.observation?.previousInterval.map {
                    $0.end > range.start && $0.start < range.end
                } ?? false
                guard currentMatches || previousMatches else { continue }
            }
            var reasons: [InboxAttentionReason] = []
            // Trust normalized current-user metadata. Occupancy, arbitrary
            // attendees, and action availability never imply an unanswered RSVP.
            if event.currentUserResponse.state == .needsResponse { reasons.append(.needsResponse) }
            if event.currentUserResponse.state == .tentative { reasons.append(.maybe) }
            var changeTiming: InboxResponseTiming?
            if let observation = item.observation, observation.responseBaseline != nil,
               observation.revision > (observation.acknowledgedRevision ?? 0),
               [.afterResponse, .uncertain].contains(observation.responseTiming) {
                reasons.append(.changedAfterResponse)
                changeTiming = observation.responseTiming
            }
            let conflicts = confirmed.filter { $0.pair.contains(event.sourceKeyHash) }
            if !conflicts.isEmpty { reasons.append(.conflict) }
            guard !reasons.isEmpty, !filter.conflictsOnly || !conflicts.isEmpty else { continue }
            rows.append(InboxAttentionRow(item: item, source: source, reasons: reasons,
                                          changeTiming: changeTiming, conflicts: conflicts))
        }
        rows.sort { ($0.item.event.startsAt, $0.item.event.sourceKeyHash) < ($1.item.event.startsAt, $1.item.event.sourceKeyHash) }
        return InboxAttentionResult(rows: rows, sources: snapshot.sources.sorted { $0.bindingID < $1.bindingID },
                                    analysisWindow: window, analysis: analysis)
    }
}
