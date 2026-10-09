import CalopodDomain
import CalopodStore
import Foundation

public enum InboxConflictChoice: String, Sendable {
    case yes, maybe, no, hold

    public var response: EventResponseState? {
        switch self {
        case .yes: .accepted
        case .maybe: .tentative
        case .no: .declined
        case .hold: nil
        }
    }
}

public struct InboxEventChoices: Equatable, Sendable {
    public let sourceKeyHash: String
    public let choices: [InboxConflictChoice]
    public let unavailableReasons: [RSVPUnavailableReason]
    public var requiresManualProviderEdit: Bool { choices == [.hold] }
}

public struct InboxContextRow: Equatable, Sendable {
    public let event: InboxContextEvent
    public let source: InboxContextSource
    public let visibleInterval: SyncWindow
    public let isFocused: Bool
}

public struct InboxResponseProjection: Equatable, Sendable {
    public let choice: InboxConflictChoice
    public let conflicts: [InboxConflict]
}

public enum InboxCalendarContextError: Error, Equatable {
    case eventUnavailable
    case previewChanged
    case actionUnavailable
}

/// A preview retains the exact local evidence used to make a decision. The
/// provider action layer must also re-read the provider revision before writing.
public struct InboxCalendarContext: Equatable, Sendable {
    public let focused: InboxContextEvent
    public let source: InboxContextSource
    public let visibleWindow: SyncWindow
    public let analysisWindow: SyncWindow
    public let rows: [InboxContextRow]
    public let analysis: InboxConflictAnalysis
    public let focusedConflicts: [InboxConflict]
    public let conflictGroup: [InboxContextEvent]
    public let choices: [InboxEventChoices]
    public let projections: [InboxResponseProjection]
    public let attentionReasons: [InboxAttentionReason]
    public let snapshot: InboxContextSnapshot
}

public enum InboxCalendarContextBuilder {
    public static func build(
        snapshot: InboxContextSnapshot, focusedKey: String,
        settings: InboxContextSettings, freshnessCutoff: Date
    ) throws -> InboxCalendarContext {
        guard let focused = snapshot.events.first(where: { $0.event.sourceKeyHash == focusedKey }),
              !focused.event.isCancelled,
              let source = snapshot.sources.first(where: { $0.bindingID == focused.event.calendarBindingID }) else {
            throw InboxCalendarContextError.eventUnavailable
        }
        let visible = try SyncWindow(
            start: focused.event.startsAt.addingTimeInterval(-Double(settings.beforeMinutes) * 60),
            end: focused.event.startsAt.addingTimeInterval(Double(settings.afterMinutes) * 60)
        )
        // Find the whole connected group in retained originals, including a
        // neighbor whose duration reaches well beyond the focused event.
        let retainedStart = snapshot.events.map(\.event.startsAt).min() ?? visible.start
        let retainedEnd = snapshot.events.map(\.event.endsAt).max() ?? visible.end
        let retainedWindow = try SyncWindow(start: min(retainedStart, visible.start), end: max(retainedEnd, visible.end))
        let retained = InboxConflictCalculator.analyze(snapshot, window: retainedWindow, freshnessCutoff: freshnessCutoff)
        let groupKeys = InboxConflictCalculator.group(containing: focusedKey, conflicts: retained.conflicts)
        let group = snapshot.events.filter { groupKeys.contains($0.event.sourceKeyHash) }.sorted {
            ($0.event.startsAt, $0.event.sourceKeyHash) < ($1.event.startsAt, $1.event.sourceKeyHash)
        }
        let window = try SyncWindow(start: min(visible.start, group.map(\.event.startsAt).min() ?? focused.event.startsAt),
                                    end: max(visible.end, group.map(\.event.endsAt).max() ?? focused.event.endsAt))
        let analysis = InboxConflictCalculator.analyze(snapshot, window: window, freshnessCutoff: freshnessCutoff)
        let conflicts = analysis.conflicts.filter { $0.pair.contains(focusedKey) }
        let rows = try snapshot.events.compactMap { item -> InboxContextRow? in
            let event = item.event
            guard !event.isCancelled, event.currentUserResponse.state != .declined, event.availability != "free",
                  event.endsAt > visible.start, event.startsAt < visible.end,
                  let source = snapshot.sources.first(where: { $0.bindingID == event.calendarBindingID }) else { return nil }
            return InboxContextRow(event: item, source: source,
                visibleInterval: try SyncWindow(start: max(event.startsAt, visible.start), end: min(event.endsAt, visible.end)),
                isFocused: event.sourceKeyHash == focusedKey)
        }.sorted { ($0.event.event.startsAt, $0.event.event.sourceKeyHash) < ($1.event.event.startsAt, $1.event.event.sourceKeyHash) }
        let projections = [InboxConflictChoice.yes, .maybe, .no].map { choice in
            let projected = InboxConflictCalculator.analyze(snapshot, window: window, freshnessCutoff: freshnessCutoff,
                responseOverride: (focusedKey, choice.response!))
            return InboxResponseProjection(choice: choice, conflicts: projected.conflicts.filter { $0.pair.contains(focusedKey) })
        }
        // Other default attention reasons are supplied by the attention query.
        let reasons: [InboxAttentionReason] = conflicts.isEmpty ? [] : [.conflict]
        return InboxCalendarContext(
            focused: focused, source: source, visibleWindow: visible, analysisWindow: window,
            rows: rows, analysis: analysis, focusedConflicts: conflicts, conflictGroup: group,
            choices: group.map { choices(for: $0, snapshot: snapshot) }, projections: projections,
            attentionReasons: reasons, snapshot: snapshot
        )
    }

    public static func choices(for item: InboxContextEvent, snapshot: InboxContextSnapshot) -> InboxEventChoices {
        let event = item.event
        guard let source = snapshot.sources.first(where: { $0.bindingID == event.calendarBindingID }) else {
            return InboxEventChoices(sourceKeyHash: event.sourceKeyHash, choices: [.hold], unavailableReasons: [.identityUnverified])
        }
        var reasons = event.currentUserResponse.actionCapability.unavailableReasons
        if source.responseIdentityScope != .authenticatedUser { reasons.append(.identityUnverified) }
        if !["google", "microsoft"].contains(source.provider) { reasons.append(.providerReadOnly) }
        if [.organizer, .notApplicable].contains(event.currentUserResponse.state) || event.isCancelled {
            reasons.append(.notAnInvitation)
        }
        if event.currentUserResponse.state == .unknown { reasons.append(.unsupportedResponse) }
        let capability = event.currentUserResponse.actionCapability
        if !capability.isEligible || !capability.supportedScopes.contains(.occurrence) {
            if reasons.isEmpty { reasons.append(.unsupportedResponse) }
        }
        let uniqueReasons = Array(Set(reasons.map(\.rawValue))).sorted().compactMap(RSVPUnavailableReason.init(rawValue:))
        return InboxEventChoices(sourceKeyHash: event.sourceKeyHash,
            choices: uniqueReasons.isEmpty ? [.yes, .no, .maybe, .hold] : [.hold], unavailableReasons: uniqueReasons)
    }

    /// Any event, source, capability, or coverage change requires a fresh card,
    /// including changes to the other members of the conflict group.
    public static func revalidate(
        _ preview: InboxCalendarContext, against current: InboxContextSnapshot,
        chosenKey: String, choice: InboxConflictChoice, freshnessCutoff: Date
    ) throws -> InboxContextEvent {
        guard current == preview.snapshot else { throw InboxCalendarContextError.previewChanged }
        guard preview.conflictGroup.contains(where: { $0.event.sourceKeyHash == chosenKey }),
              let event = current.events.first(where: { $0.event.sourceKeyHash == chosenKey }) else {
            throw InboxCalendarContextError.eventUnavailable
        }
        guard choices(for: event, snapshot: current).choices.contains(choice) else {
            throw InboxCalendarContextError.actionUnavailable
        }
        // Changing freshness warnings also requires redisplaying the card.
        // Existing incomplete context remains explicit; the action layer must
        // validate the chosen provider revision before any RSVP write.
        if choice != .hold && InboxConflictCalculator.analyze(current, window: preview.analysisWindow,
                                                              freshnessCutoff: freshnessCutoff).warnings != preview.analysis.warnings {
            throw InboxCalendarContextError.previewChanged
        }
        return event
    }
}
