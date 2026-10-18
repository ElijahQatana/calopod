import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Copies written by an arm in the inbox")
struct InboxCopyConflictTests {
    @Test("A full-details copy with the source's guests is no item and no conflict; other guests keep it", arguments: [
        (["ana", "bo", "cy"], false), (["ana", "bo", "dee"], true), ([], false),
        // The calendar made the user organizer of the copy and listed the original's organizer too.
        (["ana", "bo", "cy", "me"], false),
    ])
    func copyWithGuests(copyGuests: [String], shown: Bool) throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(id: "c", configurationID: "d", provider: "eventkit", displayLabel: "Example", isEnabled: true))
        try repository.replaceCalendarBindings(connectionID: "c", bindings: ["a", "b"].map {
            StoredCalendarBinding(id: $0, connectionID: "c", providerCalendarID: $0, displayLabel: "Calendar \($0)", isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser)
        })
        try repository.saveArm(StoredArm(id: "arm", configurationID: "d", sourceBindingIDs: ["a"], targetBindingID: "b", ruleMode: .fullDetails))
        func people(_ names: [String]) -> [EventParticipant] { names.map { EventParticipant(name: $0, emailAddress: "\($0)@example.com") } }
        func event(_ key: String, _ binding: String, _ title: String, _ state: EventResponseState, _ evidence: ResponseEvidence,
                   start: Double, guests: [String] = []) -> StoredNormalizedInstance {
            StoredNormalizedInstance(sourceKeyHash: key, connectionID: "c", calendarBindingID: binding, providerEventID: key, recurrenceID: nil,
                startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: start + 1800), isAllDay: false, availability: "busy",
                isCancelled: false, isPrivate: false, title: title, contentFingerprint: "x", providerUpdatedAt: nil,
                organizer: EventParticipant(name: "me", emailAddress: "me@example.com"),
                attendees: people(guests), currentUserResponse: EventResponse(state: state, evidence: evidence))
        }
        let guests = ["ana", "bo", "cy"]
        let window = try SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100_000))
        let now = Date(timeIntervalSince1970: 500)
        func refresh(_ binding: String, _ events: [StoredNormalizedInstance]) throws {
            try repository.applyEventRefresh(connectionID: "c", calendarBindingID: binding, windowStart: window.start, windowEnd: window.end,
                instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [], now: now)
        }
        try refresh("a", [event("sync", "a", "Regular Sync", .organizer, .eventKitCurrentUser, start: 10_000, guests: guests)])
        try refresh("b", [
            event("copy", "b", "Regular Sync", copyGuests.contains("me") ? .organizer : .unknown,
                  copyGuests.contains("me") ? .eventKitCurrentUser : .none, start: 10_000, guests: copyGuests),
            event("ops", "b", "Ops Meeting", .accepted, .eventKitCurrentUser, start: 50_000),
            event("mariana", "b", "Sync - Mariana", .accepted, .eventKitCurrentUser, start: 50_000),
        ])
        let rows = InboxAttentionQuery.evaluate(try repository.inboxContextSnapshot(), freshnessCutoff: now).rows
        let keys = Set(rows.map(\.item.event.sourceKeyHash))
        #expect(keys == (shown ? ["sync", "copy", "ops", "mariana"] : ["ops", "mariana"]))
        #expect(rows.allSatisfy { $0.reasons == [.conflict] })
        #expect(try repository.inboxCopyDiagnoses()["copy"]?.first?.isCopy == !shown)
    }

    @Test("A copy that other arms copy onward is still a copy, and the whole queue shows only the real overlap")
    func copyThatIsCopiedOnward() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(id: "c", configurationID: "d", provider: "eventkit", displayLabel: "Example", isEnabled: true))
        try repository.replaceCalendarBindings(connectionID: "c", bindings: ["a", "b", "far"].map {
            StoredCalendarBinding(id: $0, connectionID: "c", providerCalendarID: $0, displayLabel: "Calendar \($0)", isSelected: $0 != "far", isReadOnly: false, responseIdentityScope: .authenticatedUser)
        })
        try repository.saveArm(StoredArm(id: "in", configurationID: "d", sourceBindingIDs: ["a"], targetBindingID: "b", ruleMode: .fullDetails))
        try repository.saveArm(StoredArm(id: "onward", configurationID: "d", sourceBindingIDs: ["b"], targetBindingID: "far", ruleMode: .busy))
        func event(_ key: String, _ binding: String, _ title: String, _ state: EventResponseState, _ evidence: ResponseEvidence,
                   start: Double, guests: Int = 0) -> StoredNormalizedInstance {
            StoredNormalizedInstance(sourceKeyHash: key, connectionID: "c", calendarBindingID: binding, providerEventID: key, recurrenceID: nil,
                startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: start + 1800), isAllDay: false, availability: "busy",
                isCancelled: false, isPrivate: false, title: title, contentFingerprint: "x", providerUpdatedAt: nil,
                attendees: (0..<guests).map { EventParticipant(name: "g\($0)", emailAddress: "g\($0)@example.com") },
                currentUserResponse: EventResponse(state: state, evidence: evidence))
        }
        let now = Date(timeIntervalSince1970: 500)
        func refresh(_ binding: String, _ events: [StoredNormalizedInstance]) throws {
            try repository.applyEventRefresh(connectionID: "c", calendarBindingID: binding, windowStart: Date(timeIntervalSince1970: 0),
                windowEnd: Date(timeIntervalSince1970: 100_000), instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [], now: now)
        }
        try refresh("a", [event("spaces", "a", "Spaces Sync", .organizer, .eventKitCurrentUser, start: 10_000, guests: 6)])
        try refresh("b", [
            event("copy", "b", "Spaces Sync", .unknown, .none, start: 10_000),
            event("ops", "b", "Ops Meeting", .accepted, .eventKitCurrentUser, start: 50_000),
            event("mariana", "b", "Sync - Mariana", .accepted, .eventKitCurrentUser, start: 50_000),
        ])
        // The arm that reads calendar b copies the leaked copy onward, so it is a mapped source.
        try repository.saveMirrorMapping(StoredMirrorMapping(mirrorKey: "m", armID: "onward", sourceKeyHash: "copy", providerEventID: "x",
            providerVersion: nil, desiredFingerprint: "x", ownershipKeyID: "k", updatedAt: now))
        let result = InboxAttentionQuery.evaluate(try repository.inboxContextSnapshot(), freshnessCutoff: now)
        #expect(Set(result.rows.map(\.item.event.sourceKeyHash)) == ["ops", "mariana"])
        #expect(try repository.inboxDroppedCopies().keys.contains("copy"))
    }
}
