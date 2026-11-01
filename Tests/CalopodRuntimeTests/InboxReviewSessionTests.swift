import CalopodDomain
import CalopodProviders
@testable import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Durable inbox review")
struct InboxReviewSessionTests {
    enum Interruption: Error { case stopped }

    @Test(arguments: [InboxReviewCheckpoint.beforeIntent, .beforeSending, .beforeAdvance, .beforeSummary])
    func interruptionRecovery(point: InboxReviewCheckpoint) async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        let card = try #require(try await f.card(session.id))
        let interrupted = InboxReviewSessionController(state: f.state, lockURL: f.lockURL, checkpoint: {
            if $0 == point { throw Interruption.stopped }
        })
        do {
            _ = try await interrupted.decide(.yes, card: card, freshnessCutoff: f.cutoff, refresh: f.refresh, provider: f.provider)
            Issue.record("Expected interruption")
        } catch Interruption.stopped { }
        let reopened = try f.reopen()
        let resumed = try await reopened.resume(f, id: session.id)
        let writes = await f.remote.writes
        if point == .beforeIntent {
            #expect(writes == 0)
            #expect(resumed.cursor == 0)
            #expect(resumed.summary?.yes == 0)
        } else if point == .beforeSending {
            #expect(writes == 0)
            #expect(resumed.summary?.unknown == 1)
            #expect(resumed.hasUnresolvedActions)
        } else {
            #expect(writes == 1)
            #expect(resumed.cursor == 1)
            #expect(resumed.summary?.yes == 1)
        }
        #expect(resumed.summary != nil)
    }

    @Test func remoteSuccessBeforeLocalReceiptDoesNotSendAgain() async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        let card = try #require(try await f.card(session.id))
        try f.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER stop_receipt BEFORE UPDATE ON inbox_rsvp_actions
                WHEN NEW.status = 'accepted' BEGIN SELECT RAISE(ABORT, 'interrupted receipt'); END
                """)
        }
        do { _ = try await f.decide(.no, card); Issue.record("Expected receipt failure") } catch { }
        let stored = try #require(try f.state.inboxReviewSession(id: session.id))
        let interrupted = try JSONDecoder().decode(InboxReviewSession.self, from: stored.snapshot)
        #expect(interrupted.cursor == 0)
        #expect(interrupted.summary == nil)
        try f.database.write { try $0.execute(sql: "DROP TRIGGER stop_receipt") }
        let resumed = try await f.reopen().resume(f, id: session.id)
        #expect(resumed.summary?.no == 1)
        #expect(resumed.summary?.unknown == 0)
        #expect(await f.remote.writes == 1)
        #expect(resumed.entries[0].response == .declined)
    }

    @Test func holdAndMaybeAdvanceAcrossRestartsAndNewSessions() async throws {
        let f = try ReviewFixture(keys: ["a", "b"])
        defer { f.remove() }
        let session = try f.start(settings: InboxContextSettings(beforeMinutes: 15, afterMinutes: 30))
        let first = try #require(try await f.card(session.id))
        _ = try await f.decide(.hold, first)
        let resumed = try await f.reopen().resume(f, id: session.id)
        #expect(resumed.cursor == 1)
        #expect(resumed.settings.beforeMinutes == 15)
        #expect(try f.state.inboxObservation(sourceKeyHash: "a")?.acknowledgedRevision == nil)
        let second = try #require(try await f.card(session.id))
        #expect(second.context.focused.event.sourceKeyHash == "b")
        let done = try await f.decide(.maybe, second)
        #expect(done.summary?.hold == 1)
        #expect(done.summary?.maybe == 1)
        #expect(done.summary?.queueReviewed == true)
        #expect(done.summary?.inboxResolved == false)
        #expect(try await f.card(session.id) == nil)
        let again = try await f.reopen().resume(f, id: session.id)
        #expect(again.summary?.maybe == 1)
        #expect(await f.remote.writes == 1)
        let new = try f.start()
        #expect(new.entries.map(\.sourceKeyHash) == ["a", "b"])
    }

    @Test func snoozeLeavesTheQueueWithoutSendingAndHoldStaysSeparate() async throws {
        let f = try ReviewFixture(keys: ["a", "b"])
        defer { f.remove() }
        let session = try f.start()
        let first = try #require(try await f.card(session.id))
        let held = try await f.decide(.hold, first)
        #expect(try f.state.inboxSnoozes().isEmpty)
        let second = try #require(try await f.card(session.id))
        let done = try await f.controller.snooze(until: Date(timeIntervalSince1970: 5000), card: second,
                                                 freshnessCutoff: f.cutoff, refresh: f.refresh)
        #expect(held.entries[0].outcome == .hold)
        #expect(done.entries[1].outcome == .snoozed)
        #expect(done.summary?.snoozed == 1)
        #expect(done.summary?.hold == 1)
        #expect(done.summary?.queueReviewed == true)
        #expect(done.summary?.remainingInboxItems == 1)
        #expect(done.summary?.lines.contains { $0.label == "Snoozed" && $0.value == 1 } == true)
        #expect(try f.state.inboxSnoozes().keys.sorted() == ["b"])
        #expect(try f.state.inboxObservation(sourceKeyHash: "b")?.acknowledgedRevision == nil)
        #expect(await f.remote.writes == 0)
        #expect(try f.start(filter: InboxAttentionFilter(asOf: Date(timeIntervalSince1970: 0))).entries.map(\.sourceKeyHash) == ["a"])
    }

    @Test func fixedQueueFiltersAndFreshCards() async throws {
        let f = try ReviewFixture(keys: ["a", "b"])
        defer { f.remove() }
        try await f.remote.replace("b", response: .tentative)
        let session = try f.start(filter: InboxAttentionFilter(excludeMaybe: true))
        #expect(session.entries.map(\.sourceKeyHash) == ["a"])
        let old = try #require(try await f.card(session.id))
        try await f.remote.replace("a", title: "Revised example")
        try await f.remote.add("new")
        do { _ = try await f.decide(.yes, old); Issue.record("Expected fresh card") }
        catch InboxCalendarContextError.previewChanged { }
        #expect(await f.remote.writes == 0)
        let resumed = try await f.reopen().resume(f, id: session.id)
        #expect(resumed.entries.map(\.sourceKeyHash) == ["a"])
        let current = try #require(try await f.card(session.id))
        #expect(current.context.focused.event.title == "Revised example")
        _ = try await f.decide(.yes, current)
        #expect(try await f.card(session.id) == nil)
    }

    @Test func providerVersionChangeRequiresAnotherDecision() async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        let card = try #require(try await f.card(session.id))
        await f.remote.setVersion("v2")
        let stale = try await f.decide(.yes, card)
        #expect(stale.cursor == 0)
        #expect(stale.summary?.queueReviewed == false)
        #expect(stale.summary?.stale == 1)
        #expect(stale.summary?.yes == 0)
        #expect(await f.remote.writes == 0)
        let fresh = try #require(try await f.card(session.id))
        let confirmed = try await f.decide(.yes, fresh)
        #expect(confirmed.summary?.yes == 1)
        #expect(confirmed.summary?.stale == 0)
    }

    @Test func unknownAndFailedAreSeparateAndRecoveryDoesNotRetry() async throws {
        for mode in [ReviewRemote.Mode.unknown, .failed] {
            let f = try ReviewFixture()
            defer { f.remove() }
            let session = try f.start()
            await f.remote.setMode(mode)
            let card = try #require(try await f.card(session.id))
            _ = try await f.decide(.yes, card)
            let resumed = try await f.reopen().resume(f, id: session.id)
            #expect(resumed.summary?.yes == 0)
            #expect(resumed.summary?.unknown == (mode == .unknown ? 1 : 0))
            #expect(resumed.summary?.failed == (mode == .failed ? 1 : 0))
            #expect(await f.remote.writes == 1)
            if mode == .unknown {
                let unavailable: InboxReviewSessionController.Provider = { _ in throw RSVPActionError.unavailable(.permission) }
                let noAccess = try await f.reopen().resume(id: session.id, freshnessCutoff: f.cutoff, refresh: f.refresh, provider: unavailable)
                #expect(noAccess.summary?.unknown == 1)
                do { _ = try await f.card(session.id, key: "a"); Issue.record("Expected unresolved decision") }
                catch InboxReviewSessionError.unresolvedDecision { }
            }
        }
    }

    @Test func conflictRevisitReplacesFinalTotalAndKeepsDistinctCreatedPairs() async throws {
        let f = try ReviewFixture(keys: ["a", "b"], overlapping: true)
        defer { f.remove() }
        try await f.remote.replace("a", response: .declined)
        try await f.remote.replace("b", response: .accepted)
        try await f.remote.replace("a", title: "Changed example")
        let session = try f.start()
        #expect(session.entries.map(\.sourceKeyHash) == ["a"])
        let first = try #require(try await f.card(session.id))
        let accepted = try await f.decide(.yes, first)
        #expect(accepted.summary?.createdConflicts == 1)
        #expect(accepted.summary?.remainingConflicts == 1)
        let revisit = try #require(try await f.card(session.id, key: "a"))
        let declined = try await f.decide(.no, revisit)
        #expect(declined.summary?.yes == 0)
        #expect(declined.summary?.no == 1)
        #expect(declined.summary?.createdConflicts == 1)
        #expect(declined.summary?.remainingConflicts == 0)
        let resumed = try await f.reopen().resume(f, id: session.id)
        #expect(resumed.summary == declined.summary)
    }

    @Test func declineDisappearanceAndRepeatedMaybeKeepOneFinalOutcome() async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        let first = try #require(try await f.card(session.id))
        _ = try await f.decide(.maybe, first)
        let again = try #require(try await f.card(session.id, key: "a"))
        let repeated = try await f.decide(.maybe, again)
        #expect(repeated.summary?.maybe == 1)
        await f.remote.setMode(.disappear)
        let decline = try #require(try await f.card(session.id, key: "a"))
        _ = try await f.decide(.no, decline)
        let resumed = try await f.reopen().resume(f, id: session.id)
        #expect(resumed.summary?.no == 1)
        #expect(resumed.summary?.maybe == 0)
        #expect(resumed.summary?.remainingInboxItems == 0)
        #expect(await f.remote.writes == 3)
        #expect(try f.start().entries.isEmpty)
    }

    @Test func recurringTargetAndConflictNavigationSurviveRestart() async throws {
        let f = try ReviewFixture(keys: ["a", "b"], overlapping: true)
        defer { f.remove() }
        try await f.remote.replace("a", response: .declined, series: "series")
        try await f.remote.replace("b", response: .accepted)
        try await f.remote.replace("a", title: "Changed example")
        let session = try f.start()
        let card = try #require(try await f.card(session.id))
        #expect(card.providerSnapshot?.target.seriesID == "series")
        #expect(card.providerSnapshot?.target.originalStart == "2026-11-05T14:00:00Z")
        _ = try await f.decide(.yes, card)
        let other = try #require(try await f.controller.card(sessionID: session.id, sourceKeyHash: "b", conflictFromKey: "a",
            freshnessCutoff: f.cutoff, refresh: f.refresh, provider: f.provider))
        _ = try await f.decide(.no, other)
        let resumed = try await f.reopen().resume(f, id: session.id)
        #expect(resumed.queueCount == 1)
        #expect(resumed.entries.count == 2)
        #expect(resumed.cursor == 1)
        #expect(resumed.summary?.yes == 1)
        #expect(resumed.summary?.no == 1)
        #expect(resumed.summary?.createdConflicts == 1)
        #expect(resumed.summary?.remainingConflicts == 0)
        #expect(try await f.card(session.id) == nil)
    }

    @Test(arguments: ["cursor", "summary"])
    func transactionFailureDuringAdvanceOrSummary(part: String) async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        let card = try #require(try await f.card(session.id))
        let condition = part == "cursor" ? "json_extract(NEW.snapshot, '$.cursor') = 1" : "json_extract(NEW.snapshot, '$.summary.yes') = 1"
        try f.database.write { db in
            try db.execute(sql: "CREATE TRIGGER stop_session BEFORE UPDATE ON inbox_review_sessions WHEN \(condition) BEGIN SELECT RAISE(ABORT, 'interrupted session'); END")
        }
        do { _ = try await f.decide(.yes, card); Issue.record("Expected session failure") } catch { }
        try f.database.write { try $0.execute(sql: "DROP TRIGGER stop_session") }
        let reopened = try f.reopen()
        let resumed = try await reopened.resume(freshnessCutoff: f.cutoff, refresh: f.refresh, provider: f.provider)
        #expect(resumed.id == session.id)
        #expect(resumed.cursor == 1)
        #expect(resumed.summary?.yes == 1)
        #expect(await f.remote.writes == 1)
    }

    @Test func otherReviewerAndRefreshRespectTheLockAndOldCards() async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        let old = try #require(try await f.card(session.id))
        let other = try #require(try await f.card(session.id))
        do {
            let lock = try ProcessLock.acquire(at: f.lockURL)
            defer { withExtendedLifetime(lock) {} }
            do { _ = try await f.decide(.yes, other); Issue.record("Expected busy") }
            catch CalopodRuntimeError.busy { }
        }
        _ = try await f.decide(.yes, other)
        do { _ = try await f.decide(.no, old); Issue.record("Expected obsolete card") }
        catch InboxReviewSessionError.freshDecisionRequired { }
        #expect(await f.remote.writes == 1)
    }

    @Test func readOnlySourcesKeepContextAndHoldWithoutProviderAccess() async throws {
        let f = try ReviewFixture(backend: "eventkit")
        defer { f.remove() }
        let session = try f.start()
        let unavailable: InboxReviewSessionController.Provider = { _ in throw RSVPActionError.unavailable(.unsupported) }
        let card = try #require(try await f.controller.card(sessionID: session.id, freshnessCutoff: f.cutoff, refresh: f.refresh, provider: unavailable))
        #expect(card.providerSnapshot == nil)
        #expect(card.context.choices.first?.choices == [.hold])
        let done = try await f.controller.decide(.hold, card: card, freshnessCutoff: f.cutoff, refresh: f.refresh, provider: unavailable)
        #expect(done.summary?.hold == 1)
        #expect(await f.remote.writes == 0)
    }

    @Test func concurrentEditKeepsItsNewerRevisionUnread() async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        await f.remote.setMode(.edited)
        let card = try #require(try await f.card(session.id))
        let confirmed = try await f.decide(.yes, card)
        let observation = try #require(try f.state.inboxObservation(sourceKeyHash: "a"))
        #expect(observation.revision > (observation.acknowledgedRevision ?? 0))
        #expect(confirmed.summary?.yes == 1)
        #expect(confirmed.summary?.remainingInboxItems == 1)
        #expect(try await f.card(session.id) == nil)
    }

    @Test func cancellationBeforeDecisionDoesNotWrite() async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        let card = try #require(try await f.card(session.id))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.decide(.yes, card)
        }
        do { _ = try await task.value; Issue.record("Expected cancellation") } catch is CancellationError { }
        let resumed = try await f.reopen().resume(f, id: session.id)
        #expect(resumed.cursor == 0)
        #expect(await f.remote.writes == 0)
    }

    @Test func failedPostDecisionRefreshPreservesConfirmedTotalAndShowsStaleContext() async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        let card = try #require(try await f.card(session.id))
        let refresh: InboxReviewSessionController.Refresh = {
            if await f.remote.writes > 0 { throw ProviderFailure.temporaryFailure(retryAfterSeconds: nil) }
            return try f.state.inboxContextSnapshot()
        }
        let done = try await f.controller.decide(.yes, card: card, freshnessCutoff: f.cutoff, refresh: refresh, provider: f.provider)
        #expect(done.summary?.yes == 1)
        #expect(done.summary?.contextIsComplete == false)
        #expect(done.summary?.inboxResolved == false)
        #expect(done.cursor == 1)
    }

    @Test func incompleteContextAndUnavailableCardsRemainOutstanding() async throws {
        let f = try ReviewFixture()
        defer { f.remove() }
        let session = try f.start()
        try f.state.markConnectionStale(connectionID: "connection", errorCode: "temporary")
        let resumed = try await f.reopen().resume(f, id: session.id)
        #expect(resumed.summary?.contextIsComplete == false)
        let deferred = try f.controller.deferUnavailable(sessionID: session.id, sourceKeyHash: "a", freshnessCutoff: f.cutoff)
        #expect(deferred.summary?.unavailable == 1)
        #expect(deferred.summary?.inboxResolved == false)
        #expect(await f.remote.writes == 0)
    }
}

private struct ReviewFixture {
    let root: URL
    let database: CalopodDatabase
    let state: LocalStateRepository
    let remote: ReviewRemote
    var lockURL: URL { root.appendingPathComponent("state.sqlite.lock") }
    var cutoff: Date { Date(timeIntervalSince1970: 0) }
    var window: SyncWindow { try! SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100_000)) }
    var controller: InboxReviewSessionController { InboxReviewSessionController(state: state, lockURL: lockURL, now: { Date(timeIntervalSince1970: 0) }) }
    var refresh: InboxReviewSessionController.Refresh { { try state.inboxContextSnapshot() } }
    var provider: InboxReviewSessionController.Provider { { _ in remote } }

    init(keys: [String] = ["a"], overlapping: Bool = false, backend: String = "google") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try CalopodDatabase(path: root.appendingPathComponent("state.sqlite").path)
        state = LocalStateRepository(database: database)
        try state.saveConnection(StoredConnection(id: "connection", configurationID: "config", provider: backend, displayLabel: "Example", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "connection", bindings: [StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "primary", displayLabel: "Example", isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser)])
        let events = keys.enumerated().map { index, key in
            Self.event(key, start: overlapping ? 10_000 : 10_000 + Double(index) * 20_000)
        }
        remote = ReviewRemote(state: state, events: events, lockURL: root.appendingPathComponent("state.sqlite.lock"))
        try Self.apply(state, events: events)
    }

    static func event(_ key: String, start: Double = 10_000, response: EventResponseState = .needsResponse,
                      title: String = "Example invitation", series: String? = nil) -> StoredNormalizedInstance {
        StoredNormalizedInstance(sourceKeyHash: key, connectionID: "connection", calendarBindingID: "calendar", providerEventID: key,
            recurrenceID: series == nil ? nil : "2026-11-05T14:00:00Z", startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: start + 1000),
            isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false, title: title, contentFingerprint: "example", providerUpdatedAt: nil,
            currentUserResponse: EventResponse(state: response, evidence: .googleSelf, actionCapability: RSVPActionCapability(supportedScopes: [.occurrence])), providerSeriesID: series)
    }

    static func apply(_ state: LocalStateRepository, events: [StoredNormalizedInstance], removed: [String] = []) throws {
        try state.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar", windowStart: Date(timeIntervalSince1970: 0),
            windowEnd: Date(timeIntervalSince1970: 100_000), instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [], removedSourceKeyHashes: removed)
    }
    func start(filter: InboxAttentionFilter = InboxAttentionFilter(), settings: InboxContextSettings? = nil) throws -> InboxReviewSession {
        try controller.start(filter: filter, settings: settings, metricsWindow: window, freshnessCutoff: cutoff)
    }
    func card(_ id: String, key: String? = nil) async throws -> InboxReviewCard? {
        try await controller.card(sessionID: id, sourceKeyHash: key, freshnessCutoff: cutoff, refresh: refresh, provider: provider)
    }
    func decide(_ choice: InboxConflictChoice, _ card: InboxReviewCard) async throws -> InboxReviewSession {
        try await controller.decide(choice, card: card, freshnessCutoff: cutoff, refresh: refresh, provider: provider)
    }
    func reopen() throws -> InboxReviewSessionController {
        InboxReviewSessionController(state: LocalStateRepository(database: try CalopodDatabase(path: root.appendingPathComponent("state.sqlite").path)), lockURL: lockURL, now: { Date(timeIntervalSince1970: 0) })
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

private extension InboxReviewSessionController {
    func resume(_ f: ReviewFixture, id: String) async throws -> InboxReviewSession {
        try await resume(id: id, freshnessCutoff: f.cutoff, refresh: f.refresh, provider: f.provider)
    }
}

private actor ReviewRemote: RSVPActionProvider {
    enum Mode { case confirmed, failed, unknown, disappear, edited }
    let state: LocalStateRepository
    var events: [StoredNormalizedInstance]
    var version = "v1"
    var mode = Mode.confirmed
    var writes = 0
    let lockURL: URL
    init(state: LocalStateRepository, events: [StoredNormalizedInstance], lockURL: URL) {
        self.state = state
        self.events = events
        self.lockURL = lockURL
    }
    func setVersion(_ value: String) { version = value }
    func setMode(_ value: Mode) { mode = value }
    func replace(_ key: String, response: EventResponseState? = nil, title: String? = nil, series: String? = nil) throws {
        let index = events.firstIndex { $0.sourceKeyHash == key }!
        let old = events[index]
        events[index] = ReviewFixture.event(key, start: old.startsAt.timeIntervalSince1970, response: response ?? old.currentUserResponse.state,
                                          title: title ?? old.title!, series: series ?? old.providerSeriesID)
        try ReviewFixture.apply(state, events: events)
    }
    func add(_ key: String) throws {
        events.append(ReviewFixture.event(key, start: 70_000))
        try ReviewFixture.apply(state, events: events)
    }
    func rsvpSnapshot(target: RSVPTarget) async throws -> RSVPEventSnapshot {
        guard let local = events.first(where: { $0.providerEventID == target.eventID }) else { throw ProviderFailure.httpStatus(404) }
        guard local.providerSeriesID == target.seriesID, (target.seriesID == nil ? nil : local.recurrenceID) == target.originalStart else { throw RSVPActionError.stale }
        let event = ProviderEvent(provider: "google", connectionID: target.connectionID, calendarID: target.calendarID, eventID: target.eventID,
            seriesID: target.seriesID, originalStart: target.originalStart, start: local.startsAt, end: local.endsAt, isAllDay: false,
            availability: .busy, isCancelled: false, isPrivate: false, title: local.title, updatedAt: nil, responseMetadata: local.currentUserResponse)
        return RSVPEventSnapshot(target: target, event: event, version: version, capability: RSVPActionCapability(supportedScopes: [.occurrence]),
                                 notification: .googleAllGuests, concurrency: .conditionalUpdate)
    }
    func submitRSVP(_ intent: RSVPActionIntent) async throws {
        try await rsvpSnapshot(target: intent.target).validate(intent)
        #expect(try state.rsvpAction(id: intent.id)?.outcome.status == .pending)
        let stored = try #require(try state.inboxReviewSession())
        let session = try JSONDecoder().decode(InboxReviewSession.self, from: stored.snapshot)
        #expect(session.entries.contains { $0.actions.contains { $0.id == intent.id } })
        do {
            _ = try ProcessLock.acquire(at: lockURL)
            Issue.record("Refresh acquired the decision lock")
        } catch CalopodRuntimeError.busy { }
        writes += 1
        if mode == .failed { throw RSVPActionError.rejected }
        if mode == .unknown { throw RSVPActionError.uncertain }
        if mode == .disappear && intent.decision == .no {
            events.removeAll { $0.providerEventID == intent.target.eventID }
            try ReviewFixture.apply(state, events: events, removed: [intent.target.eventID])
        } else {
            try replace(intent.target.eventID, response: intent.decision.responseState)
            if mode == .edited { try replace(intent.target.eventID, title: "Concurrent example edit") }
        }
    }
    func reconcileRSVP(_ record: RSVPActionRecord) async throws -> RSVPActionOutcome {
        if mode == .unknown { return RSVPActionOutcome(status: .unknown, issue: .uncertain) }
        if !events.contains(where: { $0.providerEventID == record.intent.target.eventID }) { return RSVPReadback.missing(record) }
        return try await RSVPReadback.outcome(record, snapshot: rsvpSnapshot(target: record.intent.target))
    }
}
