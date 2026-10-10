import CalopodDomain
import CalopodStore
import Foundation
import Testing

@Suite("Review session storage")
struct InboxReviewSessionStoreTests {
    @Test func journalAndSessionReservationRollBackTogether() throws {
        let state = LocalStateRepository(database: try .inMemory())
        try state.createInboxReviewSession(update("session", generation: 0), connectionIDs: [])
        let target = RSVPTarget(provider: "google", connectionID: "connection", calendarBindingID: "binding", calendarID: "primary", eventID: "sample")
        let intent = RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .yes)
        #expect(throws: InboxReviewSessionStoreError.changed) {
            try state.beginRSVPAction(intent, sessionUpdate: update("session", generation: 1))
        }
        #expect(try state.rsvpAction(id: intent.id) == nil)
        #expect(try state.inboxReviewSession(id: "session")?.generation == 0)
        #expect(try state.beginRSVPAction(intent, sessionUpdate: update("session", generation: 0)).isNew)
        #expect(try state.inboxReviewSession(id: "session")?.generation == 1)
    }

    @Test func retentionKeepsUnfinishedAndUnknownSessions() throws {
        let state = LocalStateRepository(database: try .inMemory())
        for (id, complete, unknown) in [("done", true, false), ("unfinished", false, false), ("unknown", true, true)] {
            try state.createInboxReviewSession(update(id, generation: 0, complete: complete, unknown: unknown), connectionIDs: [])
        }
        try state.pruneInboxReviewSessions(completedBefore: Date(timeIntervalSince1970: 100))
        #expect(try state.inboxReviewSession(id: "done") == nil)
        #expect(try state.inboxReviewSession(id: "unfinished") != nil)
        #expect(try state.inboxReviewSession(id: "unknown") != nil)
        #expect(try state.inboxReviewSession() != nil)
    }

    @Test func connectionRemovalErasesSessionAndActionEvidence() throws {
        let state = LocalStateRepository(database: try .inMemory())
        try state.saveConnection(StoredConnection(id: "connection", configurationID: "config", provider: "google", displayLabel: "Example", isEnabled: true))
        try state.createInboxReviewSession(update("private", generation: 0), connectionIDs: ["connection"])
        let target = RSVPTarget(provider: "google", connectionID: "connection", calendarBindingID: "binding", calendarID: "primary", eventID: "sample")
        let intent = RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .no)
        _ = try state.beginRSVPAction(intent)
        try state.removeConnection(id: "connection")
        #expect(try state.inboxReviewSession(id: "private") == nil)
        #expect(try state.rsvpAction(id: intent.id) == nil)
    }

    private func update(_ id: String, generation: Int64, complete: Bool = false, unknown: Bool = false) -> InboxReviewSessionUpdate {
        InboxReviewSessionUpdate(id: id, expectedGeneration: generation, snapshot: Data("private".utf8), completed: complete,
                                 hasUnresolvedActions: unknown, updatedAt: Date(timeIntervalSince1970: 1))
    }
}
