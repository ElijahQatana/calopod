import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation

public enum InboxReviewSessionError: Error, Equatable {
    case noSession, itemNotQueued, unresolvedDecision, freshDecisionRequired
}

public struct InboxReviewCard: Sendable {
    public let sessionID: String
    public let generation: Int64
    public let context: InboxCalendarContext
    public let providerSnapshot: RSVPEventSnapshot?
}

enum InboxReviewCheckpoint: Sendable {
    case beforeIntent, beforeSending, beforeAdvance, beforeSummary
}

/// Hold the same lock as sync only while refreshing or committing a decision.
/// The caller supplies a source-only refresh that does not acquire this lock again.
public struct InboxReviewSessionController: Sendable {
    private let state: LocalStateRepository
    private let lockURL: URL
    private let checkpoint: @Sendable (InboxReviewCheckpoint) throws -> Void
    private let now: @Sendable () -> Date
    public typealias Refresh = @Sendable () async throws -> InboxContextSnapshot
    public typealias Provider = @Sendable (RSVPTarget) throws -> any RSVPActionProvider

    public init(state: LocalStateRepository, lockURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.init(state: state, lockURL: lockURL, checkpoint: { _ in }, now: now)
    }

    init(state: LocalStateRepository, lockURL: URL, checkpoint: @escaping @Sendable (InboxReviewCheckpoint) throws -> Void,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.state = state
        self.lockURL = lockURL
        self.checkpoint = checkpoint
        self.now = now
    }

    public func session(id: String) throws -> InboxReviewSession { try load(id).0 }

    public func start(filter: InboxAttentionFilter = InboxAttentionFilter(), settings: InboxContextSettings? = nil,
                      metricsWindow: SyncWindow, freshnessCutoff: Date, now: Date? = nil, displayTimeZoneIdentifier: String? = nil) throws -> InboxReviewSession {
        let now = now ?? self.now()
        let lock = try ProcessLock.acquire(at: lockURL)
        defer { withExtendedLifetime(lock) {} }
        try state.pruneInboxReviewSessions(completedBefore: now.addingTimeInterval(-30 * 86_400))
        let snapshot = try state.inboxContextSnapshot()
        var session = try InboxReviewSession(snapshot: snapshot, filter: filter, settings: settings ?? state.inboxContextSettings(),
            metricsWindow: metricsWindow, freshnessCutoff: freshnessCutoff, now: now, displayTimeZoneIdentifier: displayTimeZoneIdentifier)
        session.updateSummary(freshnessCutoff: freshnessCutoff, asOf: now)
        try state.createInboxReviewSession(update(session, generation: 0, now: now),
            connectionIDs: Set(snapshot.sources.map(\.connectionID)))
        return session
    }

    /// Recovery only reads pending/unknown actions. It never submits a response.
    public func resume(id: String? = nil, freshnessCutoff: Date, refresh: Refresh, provider: Provider) async throws -> InboxReviewSession {
        let lock = try ProcessLock.acquire(at: lockURL)
        defer { withExtendedLifetime(lock) {} }
        var (session, generation) = try load(id)
        session.summary = nil
        for index in session.entries.indices {
            for actionIndex in session.entries[index].actions.indices where !session.entries[index].actions[actionIndex].accounted {
                let action = session.entries[index].actions[actionIndex]
                guard let record = try state.rsvpAction(id: action.id) else { throw InboxReviewSessionStoreError.missing }
                let result: RSVPActionRecord
                if record.outcome.status.isUnresolved {
                    do { result = try await RSVPActionExecutor(state: state).reconcile(record, using: provider(record.intent.target)) }
                    catch { result = try state.saveRSVPOutcome(id: record.intent.id, outcome: RSVPActionOutcome(status: .unknown, issue: .uncertain)) }
                } else { result = record }
                let snapshot = try await refreshAfterDecision(refresh, target: result.intent.target)
                try apply(result, index: index, actionIndex: actionIndex, snapshot: snapshot, session: &session,
                          freshnessCutoff: freshnessCutoff)
                try save(session, generation: &generation)
            }
        }
        let snapshot = try await refreshAfterDecision(refresh)
        session.metrics.observeExternalChanges(before: session.lastSnapshot, after: snapshot, freshnessCutoff: freshnessCutoff)
        session.lastSnapshot = snapshot
        session.dropEnded(in: snapshot, asOf: now(), freshnessCutoff: freshnessCutoff)
        try finish(&session, generation: &generation, freshnessCutoff: freshnessCutoff)
        return session
    }

    public func card(sessionID: String, sourceKeyHash: String? = nil, conflictFromKey: String? = nil, freshnessCutoff: Date,
                     refresh: Refresh, provider: Provider) async throws -> InboxReviewCard? {
        let lock = try ProcessLock.acquire(at: lockURL)
        defer { withExtendedLifetime(lock) {} }
        var (session, generation) = try load(sessionID)
        let snapshot = try await refresh()
        // An event that ended while the review was open is not offered.
        let dropped = session.dropEnded(in: snapshot, asOf: now(), freshnessCutoff: freshnessCutoff)
        let key = sourceKeyHash ?? session.entries.prefix(session.queueCount).dropFirst(session.cursor).first?.sourceKeyHash
        guard let key else {
            if dropped > 0 {
                session.metrics.observeExternalChanges(before: session.lastSnapshot, after: snapshot, freshnessCutoff: freshnessCutoff)
                session.lastSnapshot = snapshot
                try finish(&session, generation: &generation, freshnessCutoff: freshnessCutoff)
            }
            return nil
        }
        if !session.entries.contains(where: { $0.sourceKeyHash == key }) {
            guard session.originalOccurrenceKeys.contains(key), let origin = conflictFromKey,
                  session.entries.contains(where: { $0.sourceKeyHash == origin }) else { throw InboxReviewSessionError.itemNotQueued }
            let group = try InboxCalendarContextBuilder.build(snapshot: snapshot, focusedKey: origin, settings: session.settings,
                                                               freshnessCutoff: freshnessCutoff).conflictGroup
            guard let item = group.first(where: { $0.event.sourceKeyHash == key }) else { throw InboxReviewSessionError.itemNotQueued }
            session.entries.append(InboxReviewEntry(sourceKeyHash: key, startingRevision: item.observation?.revision))
        }
        guard let entry = session.entries.first(where: { $0.sourceKeyHash == key }) else { throw InboxReviewSessionError.itemNotQueued }
        guard !entry.actions.contains(where: { !$0.accounted }) else { throw InboxReviewSessionError.unresolvedDecision }
        session.metrics.observeExternalChanges(before: session.lastSnapshot, after: snapshot, freshnessCutoff: freshnessCutoff)
        session.lastSnapshot = snapshot
        let context = try InboxCalendarContextBuilder.build(snapshot: snapshot, focusedKey: key, settings: session.settings,
                                                            freshnessCutoff: freshnessCutoff)
        let target = try targetFor(context)
        let choices = InboxCalendarContextBuilder.choices(for: context.focused, snapshot: snapshot)
        var providerSnapshot: RSVPEventSnapshot?
        if choices.choices.contains(.yes) {
            let preview: RSVPEventSnapshot
            do { preview = try await provider(target).rsvpSnapshot(target: target) }
            catch {
                session.updateSummary(freshnessCutoff: freshnessCutoff, asOf: now())
                try save(session, generation: &generation)
                return InboxReviewCard(sessionID: session.id, generation: generation, context: context, providerSnapshot: nil)
            }
            guard preview.target == target, matches(context.focused.event, preview.event) else {
                throw InboxReviewSessionError.freshDecisionRequired
            }
            if preview.capability.isEligible, preview.capability.supportedScopes.contains(.occurrence),
               let version = preview.version, !version.isEmpty { providerSnapshot = preview }
        }
        session.updateSummary(freshnessCutoff: freshnessCutoff, asOf: now())
        try save(session, generation: &generation)
        return InboxReviewCard(sessionID: session.id, generation: generation, context: context, providerSnapshot: providerSnapshot)
    }

    public func decide(_ choice: InboxConflictChoice, card: InboxReviewCard, freshnessCutoff: Date,
                       refresh: Refresh, provider: Provider) async throws -> InboxReviewSession {
        let lock = try ProcessLock.acquire(at: lockURL)
        defer { withExtendedLifetime(lock) {} }
        var (session, generation) = try load(card.sessionID)
        guard generation == card.generation else { throw InboxReviewSessionError.freshDecisionRequired }
        let key = card.context.focused.event.sourceKeyHash
        guard let index = session.entries.firstIndex(where: { $0.sourceKeyHash == key }) else { throw InboxReviewSessionError.itemNotQueued }
        guard !session.entries[index].actions.contains(where: { !$0.accounted }) else { throw InboxReviewSessionError.unresolvedDecision }
        let before = try await refresh()
        _ = try InboxCalendarContextBuilder.revalidate(card.context, against: before, chosenKey: key,
                                                       choice: choice, freshnessCutoff: freshnessCutoff)
        try Task.checkCancellation()
        try checkpoint(.beforeIntent)
        session.summary = nil
        if choice == .hold {
            session.entries[index].outcome = .hold
            session.entries[index].response = nil
            session.metrics.observeExternalChanges(before: session.lastSnapshot, after: before, freshnessCutoff: freshnessCutoff)
            session.lastSnapshot = before
            try save(session, generation: &generation)
        } else {
            guard let preview = card.providerSnapshot, let version = preview.version,
                  let decision = RSVPDecision(rawValue: choice.rawValue) else { throw InboxReviewSessionError.freshDecisionRequired }
            let intent = RSVPActionIntent(target: preview.target, expectedVersion: version,
                                          previousResponse: preview.event.currentUserResponse.state, decision: decision)
            try preview.validate(intent)
            session.entries[index].outcome = .unknown
            session.entries[index].response = nil
            session.entries[index].actions.append(InboxReviewAction(id: intent.id, revision: card.context.focused.observation?.revision, before: before))
            let record = try await RSVPActionExecutor(state: state).perform(intent, using: provider(intent.target),
                sessionUpdate: update(session, generation: generation), beforeSubmission: { try checkpoint(.beforeSending) })
            generation += 1
            let after = try await refreshAfterDecision(refresh, target: record.intent.target)
            try apply(record, index: index, actionIndex: session.entries[index].actions.count - 1,
                      snapshot: after, session: &session, freshnessCutoff: freshnessCutoff)
            try save(session, generation: &generation)
        }
        try finish(&session, generation: &generation, freshnessCutoff: freshnessCutoff)
        return session
    }

    /// A vanished or unsupported card can be explicitly deferred without an RSVP.
    public func deferUnavailable(sessionID: String, sourceKeyHash: String, freshnessCutoff: Date, hold: Bool = false) throws -> InboxReviewSession {
        let lock = try ProcessLock.acquire(at: lockURL)
        defer { withExtendedLifetime(lock) {} }
        var (session, generation) = try load(sessionID)
        guard let index = session.entries.firstIndex(where: { $0.sourceKeyHash == sourceKeyHash }),
              (hold ? !session.entries[index].actions.contains(where: { !$0.accounted }) && session.entries[index].outcome != .unknown
                    : session.entries[index].outcome == nil && session.entries[index].actions.isEmpty) else {
            throw InboxReviewSessionError.itemNotQueued
        }
        session.summary = nil
        session.entries[index].outcome = hold ? .hold : .unavailable
        try save(session, generation: &generation)
        try finish(&session, generation: &generation, freshnessCutoff: freshnessCutoff)
        return session
    }

    private func apply(_ record: RSVPActionRecord, index: Int, actionIndex: Int, snapshot: InboxContextSnapshot,
                       session: inout InboxReviewSession, freshnessCutoff: Date) throws {
        let status = record.outcome.status
        let action = session.entries[index].actions[actionIndex]
        let confirmed = status == .confirmed && record.outcome.confirmedResponse == record.intent.decision.responseState
        let outcome: InboxReviewOutcome = switch status {
        case .failed: .failed
        case .stale: .stale
        case .unavailable: .unavailable
        default: .unknown
        }
        session.entries[index].outcome = confirmed ? .confirmed : outcome
        session.entries[index].response = confirmed ? record.outcome.confirmedResponse : nil
        session.entries[index].actions[actionIndex].accounted = !status.isUnresolved
        if confirmed {
            do {
                try session.metrics.recordConfirmedDecision(sourceKeyHash: session.entries[index].sourceKeyHash,
                    response: record.intent.decision.responseState, before: action.before, after: snapshot, freshnessCutoff: freshnessCutoff)
            } catch InboxConflictMetricsError.responseNotObserved {
                // A confirmed receipt survives a partial refresh; pair attribution stays incomplete.
                session.metrics.recordUncertainDecision(after: snapshot, freshnessCutoff: freshnessCutoff)
            }
            if let revision = action.revision {
                _ = try state.acknowledgeInboxRevision(sourceKeyHash: session.entries[index].sourceKeyHash, revision: revision)
            }
        } else {
            session.metrics.observeExternalChanges(before: session.lastSnapshot, after: snapshot, freshnessCutoff: freshnessCutoff)
        }
        session.lastSnapshot = snapshot
    }

    private func refreshAfterDecision(_ refresh: Refresh, target: RSVPTarget? = nil) async throws -> InboxContextSnapshot {
        do { return try await refresh() }
        catch {
            let ids = try target.map { [$0.connectionID] } ?? state.inboxContextSnapshot().sources.map(\.connectionID)
            for id in Set(ids) { try state.markConnectionStale(connectionID: id, errorCode: "inbox-review-refresh") }
            return try state.inboxContextSnapshot()
        }
    }

    private func finish(_ session: inout InboxReviewSession, generation: inout Int64, freshnessCutoff: Date) throws {
        try checkpoint(.beforeAdvance)
        session.advance()
        try save(session, generation: &generation)
        try checkpoint(.beforeSummary)
        session.updateSummary(freshnessCutoff: freshnessCutoff, asOf: now())
        try save(session, generation: &generation)
    }

    private func load(_ id: String?) throws -> (InboxReviewSession, Int64) {
        guard let stored = try state.inboxReviewSession(id: id) else { throw InboxReviewSessionError.noSession }
        return (try JSONDecoder().decode(InboxReviewSession.self, from: stored.snapshot), stored.generation)
    }

    private func update(_ session: InboxReviewSession, generation: Int64, now: Date = Date()) throws -> InboxReviewSessionUpdate {
        InboxReviewSessionUpdate(id: session.id, expectedGeneration: generation, snapshot: try JSONEncoder().encode(session),
            completed: session.cursor == session.queueCount && session.summary?.queueReviewed == true, hasUnresolvedActions: session.hasUnresolvedActions, updatedAt: now,
            connectionIDs: Set(session.lastSnapshot.sources.map(\.connectionID)))
    }

    private func save(_ session: InboxReviewSession, generation: inout Int64) throws {
        try state.saveInboxReviewSession(update(session, generation: generation))
        generation += 1
    }

    private func matches(_ local: StoredNormalizedInstance, _ remote: ProviderEvent) -> Bool {
        local.providerEventID == remote.eventID && local.connectionID == remote.connectionID
            && local.providerSeriesID == remote.seriesID
            && local.startsAt == remote.start && local.endsAt == remote.end
            && local.isAllDay == remote.isAllDay && local.isCancelled == remote.isCancelled
            && local.isPrivate == remote.isPrivate && local.availability == remote.availability.rawValue
            && local.title == remote.title && local.location == remote.location && local.notes == remote.notes
            && local.url == remote.url && local.organizer?.name == remote.organizer?.name
            && local.organizer?.emailAddress == remote.organizer?.emailAddress
            && local.currentUserResponse.state == remote.currentUserResponse.state
    }

    private func targetFor(_ context: InboxCalendarContext) throws -> RSVPTarget {
        let event = context.focused.event
        guard let binding = try state.calendarBinding(id: event.calendarBindingID) else { throw InboxReviewSessionError.freshDecisionRequired }
        // Provider snapshot validates recurrence scope and the exact occurrence again.
        return RSVPTarget(provider: context.source.provider, connectionID: event.connectionID,
                          calendarBindingID: event.calendarBindingID, calendarID: binding.providerCalendarID,
                          eventID: event.providerEventID, seriesID: event.providerSeriesID,
                          originalStart: event.providerSeriesID == nil ? nil : event.recurrenceID)
    }
}
