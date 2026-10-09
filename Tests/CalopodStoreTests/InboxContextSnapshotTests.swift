import CalopodDomain
import CalopodStore
import Foundation
import Testing

@Suite("Local inbox context snapshot")
struct InboxContextSnapshotTests {
    @Test("Selected originals retain local labels and revisions; duplicate evidence is explicit")
    func selectedSources() throws {
        let fixture = try ContextFixture()
        try fixture.refresh("one", events: [fixture.event("a", binding: "one")])
        try fixture.refresh("two", events: [fixture.event("b", binding: "two")])
        try fixture.refresh("off", events: [fixture.event("off-event", binding: "off")])
        let snapshot = try fixture.repository.inboxContextSnapshot()
        #expect(snapshot.sources.map(\.bindingID) == ["one", "two"])
        #expect(snapshot.sources[0].connectionLabel == "Example account")
        #expect(snapshot.sources[0].calendarLabel == "Calendar one")
        #expect(snapshot.sources[0].healthStatus == "healthy")
        #expect(snapshot.sources[0].coverage?.startsAt == fixture.start)
        #expect(snapshot.events.map(\.event.sourceKeyHash) == ["a", "b"])
        #expect(snapshot.events[0].observation?.revision == 1)
        #expect(try fixture.repository.inboxContextSnapshot(knownDuplicateBindingIDs: ["two"]).events.map(\.event.sourceKeyHash) == ["a"])
        let unproven = try fixture.repository.inboxContextSnapshot(unprovenDuplicateBindingIDs: ["two", "off"])
        #expect(unproven.events.count == 2)
        #expect(unproven.unprovenDuplicateBindingIDs == ["two"])
    }

    @Test("Mapped copies are excluded even before another refresh; acknowledgement keeps originals")
    func mappedCopies() throws {
        let fixture = try ContextFixture()
        try fixture.refresh("one", events: [fixture.event("a", binding: "one")])
        try fixture.refresh("two", events: [fixture.event("copy", binding: "two"), fixture.event("original", binding: "two")])
        try fixture.repository.saveArm(StoredArm(id: "arm", configurationID: "default", sourceBindingIDs: ["one"], targetBindingID: "two", ruleMode: .busy))
        try fixture.repository.saveMirrorMapping(StoredMirrorMapping(mirrorKey: "mapping", armID: "arm", sourceKeyHash: "a", providerEventID: "copy", providerVersion: nil, desiredFingerprint: "synthetic", ownershipKeyID: "synthetic", updatedAt: fixture.start))
        #expect(try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "a", revision: 1))
        let snapshot = try fixture.repository.inboxContextSnapshot()
        #expect(snapshot.events.map(\.event.sourceKeyHash) == ["a", "original"])
        #expect(snapshot.events[0].observation?.acknowledgedRevision == 1)
    }

    @Test("Tombstones are absent and newer retained moves supersede old cached intervals")
    func movesAndRemoval() throws {
        let fixture = try ContextFixture()
        let original = fixture.event("a", binding: "one")
        try fixture.refresh("one", events: [original])
        let moved = fixture.event("a", binding: "one", start: 30_000)
        try fixture.repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "one", windowStart: fixture.start, windowEnd: fixture.end,
            instances: [original], cancelledSourceKeyHashes: [], isFullRefresh: false, cursorUpdates: [], observationInstances: [moved])
        #expect(try fixture.repository.inboxContextSnapshot().events[0].event.startsAt == moved.startsAt)
        try fixture.repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "one", windowStart: fixture.start, windowEnd: fixture.end,
            instances: [], cancelledSourceKeyHashes: ["a"], isFullRefresh: false, cursorUpdates: [])
        #expect(try fixture.repository.inboxContextSnapshot().events.isEmpty)
    }

    @Test("Bounded disappearance retains uncertain context without manufacturing removal")
    func uncertainPresence() throws {
        let fixture = try ContextFixture()
        try fixture.refresh("one", events: [fixture.event("a", binding: "one")])
        try fixture.refresh("one", events: [])
        let snapshot = try fixture.repository.inboxContextSnapshot()
        #expect(snapshot.events.map(\.event.sourceKeyHash) == ["a"])
        #expect(!snapshot.events[0].isPresenceConfirmed)
        #expect(snapshot.events[0].observation?.tombstone == nil)
    }

    @Test("Failed sources stay visible and disabled Connections do not contribute")
    func health() throws {
        let fixture = try ContextFixture()
        try fixture.refresh("one", events: [fixture.event("a", binding: "one")])
        try fixture.repository.markConnectionStale(connectionID: "connection", errorCode: "temporary", now: fixture.end)
        #expect(try fixture.repository.inboxContextSnapshot().sources.allSatisfy { $0.healthStatus == "stale" })
        try fixture.repository.saveConnection(StoredConnection(id: "connection", configurationID: "default", provider: "google", displayLabel: "Example account", isEnabled: false))
        #expect(try fixture.repository.inboxContextSnapshot().sources.isEmpty)
        #expect(try fixture.repository.inboxContextSnapshot().events.isEmpty)
    }
}

private struct ContextFixture {
    let repository: LocalStateRepository
    let start = Date(timeIntervalSince1970: 1000)
    let end = Date(timeIntervalSince1970: 20_000)
    init() throws {
        repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(id: "connection", configurationID: "default", provider: "google", displayLabel: "Example account", isEnabled: true))
        try repository.replaceCalendarBindings(connectionID: "connection", bindings: ["one", "two", "off"].map {
            StoredCalendarBinding(id: $0, connectionID: "connection", providerCalendarID: $0, displayLabel: "Calendar \($0)", isSelected: $0 != "off", isReadOnly: false, responseIdentityScope: .authenticatedUser)
        })
    }
    func event(_ key: String, binding: String, start: Double = 2000) -> StoredNormalizedInstance {
        StoredNormalizedInstance(sourceKeyHash: key, connectionID: "connection", calendarBindingID: binding, providerEventID: key, recurrenceID: nil,
            startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: start + 1000), isAllDay: false, availability: "busy",
            isCancelled: false, isPrivate: false, title: "Example event", contentFingerprint: "synthetic", providerUpdatedAt: nil, currentUserResponse: EventResponse(state: .accepted))
    }
    func refresh(_ binding: String, events: [StoredNormalizedInstance]) throws {
        try repository.applyEventRefresh(connectionID: "connection", calendarBindingID: binding, windowStart: start, windowEnd: end,
            instances: events, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
    }
}
