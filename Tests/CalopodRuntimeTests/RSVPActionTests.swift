import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation
import Testing

@Suite("RSVP action recovery")
struct RSVPActionTests {
    private let target = RSVPTarget(provider: "google", connectionID: "connection", calendarBindingID: "binding",
                                    calendarID: "primary", eventID: "invitation")

    @Test func intentAndReceiptSurviveRestart() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let state = LocalStateRepository(database: try CalopodDatabase(path: path))
        let intent = RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .no)
        let provider = ActionStub(state: state, result: .unknown)
        let first = try await RSVPActionExecutor(state: state).perform(intent, using: provider)
        #expect(first.outcome.status == .unknown)
        #expect(first.submissionAccepted)
        let reopened = LocalStateRepository(database: try CalopodDatabase(path: path))
        let retained = try #require(try reopened.rsvpAction(id: intent.id))
        #expect(retained == first)
        let newIntent = RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .yes)
        #expect(throws: RSVPActionStoreError.self) { try reopened.beginRSVPAction(newIntent) }
        await provider.setResult(.confirmed)
        let recovered = try await RSVPActionExecutor(state: reopened).perform(intent, using: provider)
        #expect(recovered.outcome.confirmedResponse == .declined)
        #expect(await provider.writes == 1)
        #expect(await provider.sawPersistedIntent)
    }

    @Test func uncertainSubmissionIsReadWithoutResending() async throws {
        let state = LocalStateRepository(database: try .inMemory())
        let intent = RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .yes)
        let provider = ActionStub(state: state, result: .confirmed, error: .uncertain)
        let executor = RSVPActionExecutor(state: state)
        #expect(try await executor.perform(intent, using: provider).outcome.status == .unknown)
        #expect(try await executor.perform(intent, using: provider).outcome.confirmedResponse == .accepted)
        #expect(await provider.writes == 1)
    }

    @Test func reservationIsAtomicAndIntentImmutable() throws {
        let state = LocalStateRepository(database: try .inMemory())
        let intent = RSVPActionIntent(id: "decision", target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .yes)
        #expect(try state.beginRSVPAction(intent).isNew)
        #expect(try !state.beginRSVPAction(intent).isNew)
        let changed = RSVPActionIntent(id: intent.id, target: target, expectedVersion: "v2", previousResponse: .needsResponse, decision: .no)
        #expect(throws: RSVPActionStoreError.self) { try state.beginRSVPAction(changed) }
    }

    @Test func storageFailureStopsSubmission() async throws {
        let database = try CalopodDatabase.inMemory()
        let state = LocalStateRepository(database: database)
        try database.write { try $0.execute(sql: "DROP TABLE inbox_rsvp_actions") }
        let provider = ActionStub(state: state, result: .confirmed)
        let intent = RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .yes)
        do { _ = try await RSVPActionExecutor(state: state).perform(intent, using: provider); Issue.record("Expected storage failure") }
        catch { }
        #expect(await provider.writes == 0)
    }

    @Test func matchingPreviousResponseDoesNotProveLostRequestCompleted() {
        let intent = RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .accepted, decision: .yes)
        let event = ProviderEvent(provider: "google", connectionID: target.connectionID, calendarID: target.calendarID,
            eventID: target.eventID, seriesID: nil, originalStart: nil, start: nil, end: nil, isAllDay: false,
            availability: .busy, isCancelled: false, isPrivate: false, title: "Sample invitation", updatedAt: nil,
            responseMetadata: EventResponse(state: .accepted))
        let snapshot = RSVPEventSnapshot(target: target, event: event, version: "v2",
            capability: RSVPActionCapability(supportedScopes: [.occurrence]), notification: .googleAllGuests,
            concurrency: .conditionalUpdate)
        let record = RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .unknown))
        #expect(RSVPReadback.outcome(record, snapshot: snapshot).status == .unknown)
    }

    @Test func definitiveFailuresRemainSeparateFromConfirmedResponses() async throws {
        for error in [RSVPActionError.stale, .unavailable(.permission), .rejected] {
            let state = LocalStateRepository(database: try .inMemory())
            let provider = ActionStub(state: state, result: .confirmed, error: error)
            let intent = RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .maybe)
            let result = try await RSVPActionExecutor(state: state).perform(intent, using: provider)
            #expect(result.outcome == error.outcome)
            #expect(result.outcome.confirmedResponse == nil)
            _ = try await RSVPActionExecutor(state: state).perform(intent, using: provider)
            #expect(await provider.writes == 1)
        }
    }
}

private actor ActionStub: RSVPActionProvider {
    let state: LocalStateRepository
    var result: RSVPActionStatus
    let error: RSVPActionError?
    var writes = 0
    var sawPersistedIntent = false

    init(state: LocalStateRepository, result: RSVPActionStatus, error: RSVPActionError? = nil) {
        self.state = state
        self.result = result
        self.error = error
    }

    func setResult(_ result: RSVPActionStatus) { self.result = result }
    func rsvpSnapshot(target: RSVPTarget) async throws -> RSVPEventSnapshot { throw RSVPActionError.rejected }
    func submitRSVP(_ intent: RSVPActionIntent) async throws {
        sawPersistedIntent = try state.rsvpAction(id: intent.id)?.outcome.status == .pending
        writes += 1
        if let error { throw error }
    }
    func reconcileRSVP(_ record: RSVPActionRecord) async throws -> RSVPActionOutcome {
        RSVPActionOutcome(status: result, confirmedResponse: result == .confirmed ? record.intent.decision.responseState : nil)
    }
}
