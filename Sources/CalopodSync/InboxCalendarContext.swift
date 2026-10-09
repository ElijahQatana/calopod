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
        let reasons: [InboxAttentionReason] = conflicts.contains(where: \.isConfirmed) ? [.conflict] : []
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
        if !item.isPresenceConfirmed { reasons.append(.unsupportedResponse) }
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

    /// Relevant event, source, capability, or coverage changes require a fresh
    /// card. An unchanged refresh and provider version churn do not invalidate
    /// a decision merely because the observation timestamp advanced.
    public static func revalidate(
        _ preview: InboxCalendarContext, against current: InboxContextSnapshot,
        chosenKey: String, choice: InboxConflictChoice, freshnessCutoff: Date
    ) throws -> InboxContextEvent {
        guard sameDecisionEvidence(preview.snapshot, current, window: preview.analysisWindow) else { throw InboxCalendarContextError.previewChanged }
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

private func sameDecisionEvidence(_ lhs: InboxContextSnapshot, _ rhs: InboxContextSnapshot, window: SyncWindow) -> Bool {
    guard lhs.unprovenDuplicateBindingIDs == rhs.unprovenDuplicateBindingIDs else { return false }
    let oldSources = lhs.sources.sorted { $0.bindingID < $1.bindingID }
    let newSources = rhs.sources.sorted { $0.bindingID < $1.bindingID }
    guard oldSources.count == newSources.count else { return false }
    for (old, new) in zip(oldSources, newSources) {
        guard old.bindingID == new.bindingID, old.connectionID == new.connectionID,
              old.connectionLabel == new.connectionLabel, old.calendarLabel == new.calendarLabel,
              old.provider == new.provider, old.responseIdentityScope == new.responseIdentityScope,
              old.coverage?.startsAt == new.coverage?.startsAt, old.coverage?.endsAt == new.coverage?.endsAt,
              old.healthStatus == new.healthStatus, old.staleSince == new.staleSince else { return false }
    }
    func relevant(_ snapshot: InboxContextSnapshot) -> [InboxContextEvent] {
        snapshot.events.filter { $0.event.startsAt < window.end && $0.event.endsAt > window.start }
            .sorted { $0.event.sourceKeyHash < $1.event.sourceKeyHash }
    }
    let oldEvents = relevant(lhs)
    let newEvents = relevant(rhs)
    guard oldEvents.count == newEvents.count else { return false }
    for (old, new) in zip(oldEvents, newEvents) {
        let a = old.event
        let b = new.event
        guard old.isPresenceConfirmed == new.isPresenceConfirmed,
              old.observation?.revision == new.observation?.revision,
              old.observation?.tombstone == new.observation?.tombstone,
              a.sourceKeyHash == b.sourceKeyHash, a.connectionID == b.connectionID,
              a.calendarBindingID == b.calendarBindingID, a.providerEventID == b.providerEventID,
              a.recurrenceID == b.recurrenceID, a.startsAt == b.startsAt, a.endsAt == b.endsAt,
              a.isAllDay == b.isAllDay, a.availability == b.availability,
              a.isCancelled == b.isCancelled, a.isPrivate == b.isPrivate,
              a.title == b.title, a.location == b.location, a.notes == b.notes, a.url == b.url,
              a.organizer?.name == b.organizer?.name, a.organizer?.emailAddress == b.organizer?.emailAddress,
              a.currentUserResponse == b.currentUserResponse else { return false }
    }
    return true
}
