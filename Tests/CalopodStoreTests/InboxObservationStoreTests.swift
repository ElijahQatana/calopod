import CalopodDomain
import CalopodStore
import Foundation
import GRDB
import Testing

@Suite("Inbox observation ledger")
struct InboxObservationStoreTests {
    @Test("First import, response baseline, unchanged refresh and new arrivals")
    func baseline() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        let baseline = try #require(try fixture.repository.inboxObservation(sourceKeyHash: "event"))
        #expect(baseline.revision == 1)
        #expect(baseline.responseBaseline?.event.title == "Synthetic event")
        #expect(baseline.responseTiming == .observedBaseline)
        #expect(try fixture.activity().isEmpty)
        try fixture.refresh([fixture.event(), fixture.event(key: "new")])
        let activity = try fixture.activity()
        #expect(activity.count == 1)
        #expect(activity[0].types == [.newEvent])
        try fixture.refresh([fixture.event(), fixture.event(key: "new")])
        #expect(try fixture.activity().count == 1)
    }

    @Test("Edit, acknowledgement, newer edit, and a racing old acknowledgement")
    func revisions() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        try fixture.refresh([fixture.event(notes: "First edit")])
        #expect(try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 2))
        #expect(try fixture.activity().isEmpty)
        try fixture.refresh([fixture.event(notes: "Second edit")])
        #expect(try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 2))
        let observation = try #require(try fixture.repository.inboxObservation(sourceKeyHash: "event"))
        #expect(observation.revision == 3)
        #expect(observation.acknowledgedRevision == 2)
        #expect(observation.responseBaseline?.revision == 1)
        let activity = try fixture.activity()
        #expect(activity.count == 1)
        #expect(activity[0].revision == 3)
        #expect(activity[0].changedFields == ["notes"])
        #expect(activity[0].responseTiming == .afterResponse)
        #expect(try fixture.activity(all: true).count == 2)
        #expect(try !fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 4))
    }

    @Test("Response and edit together retain uncertain timing")
    func responses() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event(response: .needsResponse)])
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.responseBaseline == nil)
        try fixture.refresh([fixture.event(notes: "Edited with response", response: .accepted)])
        let activity = try #require(try fixture.activity().first)
        #expect(activity.types == [.contentChanged, .responseChanged])
        #expect(activity.responseTiming == .uncertain)
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.responseBaseline?.revision == 2)
        try fixture.refresh([fixture.event(notes: "Edited with response", response: .tentative)])
        #expect(try fixture.activity().first?.types == [.responseChanged])
    }

    @Test("Version churn, participant order and unrelated RSVP do not reopen a revision")
    func churn() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event(attendees: [EventParticipant(name: "Guest", status: "accepted")])])
        try fixture.refresh([fixture.event(attendees: [EventParticipant(name: "Guest", status: "declined")], fingerprint: "different")])
        #expect(try fixture.activity().isEmpty)
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.revision == 1)
    }

    @Test("Moves and confirmed tombstones retain both intervals and deduplicate retries")
    func tombstones() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        let moved = fixture.event(start: 3000)
        try fixture.refresh([moved])
        let move = try #require(try fixture.activity().first)
        #expect(move.previousEvent?.startsAt == Date(timeIntervalSince1970: 1000))
        #expect(move.event.startsAt == Date(timeIntervalSince1970: 3000))
        try fixture.refresh([], cancelled: ["event"], full: false)
        try fixture.refresh([], cancelled: ["event"], full: false)
        #expect(try fixture.activity().count == 2)
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.tombstone == .cancelled)
        try fixture.refresh([], removed: ["event"], full: false)
        try fixture.refresh([], removed: ["event"], full: false)
        #expect(try fixture.activity().count == 3)
        #expect(try fixture.activity().first?.event.startsAt == moved.startsAt)
    }

    @Test("Older snapshots recover a previous interval from retained activity")
    func legacyMove() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        try fixture.refresh([fixture.event(start: 3000)])
        try fixture.database.write { db in
            let data = try #require(try Data.fetchOne(db, sql: "SELECT snapshot FROM inbox_observations WHERE source_key_hash = 'event'"))
            var snapshot = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            snapshot.removeValue(forKey: "previousInterval")
            try db.execute(sql: "UPDATE inbox_observations SET snapshot = ? WHERE source_key_hash = 'event'",
                           arguments: [try JSONSerialization.data(withJSONObject: snapshot)])
        }
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.previousInterval?.start == fixture.start)
        try fixture.refresh([fixture.event(start: 3000)])
        try fixture.refresh([fixture.event(start: 3000)], now: fixture.start.addingTimeInterval(91 * 86400))
        #expect(try fixture.activity(all: true).isEmpty)
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.previousInterval?.start == fixture.start)
    }

    @Test("Latest move interval survives review, pruning and restart")
    func retainedMove() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-move-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let fixture = try Fixture(path: path)
            try fixture.refresh([fixture.event()])
            try fixture.refresh([fixture.event(start: 3000)])
            try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 2)
            try fixture.refresh([fixture.event(start: 3000)], now: fixture.start.addingTimeInterval(91 * 86400))
            #expect(try fixture.activity(all: true).isEmpty)
            #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.previousInterval == SyncWindow(start: fixture.start, end: fixture.start.addingTimeInterval(1000)))
            try fixture.repository.clearInboxHistory(connectionID: "connection")
        }
        let repository = LocalStateRepository(database: try CalopodDatabase(path: path))
        #expect(try repository.inboxObservation(sourceKeyHash: "event")?.previousInterval?.start == Date(timeIntervalSince1970: 1000))
        try repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar",
            windowStart: Date(timeIntervalSince1970: 1000), windowEnd: Date(timeIntervalSince1970: 20000),
            instances: [try Fixture().event(start: 5000)], cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [])
        #expect(try repository.inboxObservation(sourceKeyHash: "event")?.previousInterval?.start == Date(timeIntervalSince1970: 3000))
    }

    @Test("Omissions, unavailable calendars, deselection and window shifts are not removal proof")
    func incompleteEvidence() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        try fixture.refresh([], full: false)
        try fixture.repository.markConnectionStale(connectionID: "connection", errorCode: "temporary")
        try fixture.repository.setCalendarSelection(id: "calendar", isSelected: false)
        try fixture.refresh([], start: 5000, end: 10000)
        try fixture.repository.replaceCalendarBindings(connectionID: "connection", bindings: [])
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.tombstone == nil)
        #expect(try fixture.activity().isEmpty)
    }

    @Test("Transaction failure rolls back event, activity, baseline and cursor together")
    func rollback() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        try fixture.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_cursor BEFORE INSERT ON provider_cursors
                BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END;
                """)
        }
        #expect(throws: (any Error).self) {
            try fixture.refresh([fixture.event(notes: "Must roll back")], cursor: "failed")
        }
        #expect(try fixture.activity().isEmpty)
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.revision == 1)
        #expect(try fixture.repository.normalizedInstances(calendarBindingIDs: ["calendar"], from: fixture.start, through: fixture.end).first?.notes == nil)
        #expect(try fixture.repository.cursor(connectionID: "connection", calendarBindingID: "calendar", scopeKey: "window") == nil)
    }

    @Test("Pruning and history reset preserve baselines, revision counters and review state")
    func retention() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        try fixture.refresh([fixture.event(notes: "Reviewed")])
        try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 2)
        try fixture.refresh([fixture.event(notes: "Reviewed")], now: fixture.start.addingTimeInterval(91 * 86400))
        #expect(try fixture.activity(all: true).isEmpty)
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.acknowledgedRevision == 2)
        try fixture.refresh([fixture.event(notes: "New edit")])
        try fixture.repository.clearInboxHistory(connectionID: "connection")
        try fixture.refresh([fixture.event(notes: "New edit")])
        #expect(try fixture.activity().isEmpty)
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.revision == 3)
        try fixture.refresh([fixture.event(notes: "After reset")])
        #expect(try fixture.activity().first?.revision == 4)
        try fixture.repository.removeConnection(id: "connection")
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event") == nil)
        #expect(try fixture.activity(all: true).isEmpty)
    }

    @Test("Count retention bounds history without dropping current observations")
    func countRetention() throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        try fixture.refresh((0..<1002).map { fixture.event(key: "new-\($0)") })
        #expect(try fixture.activity(all: true).count == 1000)
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "new-0")?.revision == 1)
        #expect(try fixture.repository.inboxCoverage(connectionID: "connection", calendarBindingID: "calendar")?.endsAt == fixture.end)
    }

    @Test("An incremental refresh of the same window renews coverage, a different window does not", arguments: [
        (1000.0, 20000.0, 9000.0), (1000.0, 19000.0, 2000.0), (2000.0, 20000.0, 2000.0)
    ])
    func incrementalCoverage(start: Double, end: Double, observed: Double) throws {
        let fixture = try Fixture()
        try fixture.refresh([fixture.event()])
        try fixture.refresh([], full: false, start: start, end: end, now: Date(timeIntervalSince1970: 9000))
        let coverage = try #require(try fixture.repository.inboxCoverage(connectionID: "connection", calendarBindingID: "calendar"))
        #expect(coverage.observedAt == Date(timeIntervalSince1970: observed))
        #expect(coverage.startsAt == fixture.start && coverage.endsAt == fixture.end)
    }

    @Test("Restart preserves private snapshots and acknowledgement")
    func restart() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-restart-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let fixture = try Fixture(path: path)
            try fixture.refresh([fixture.event()])
            try fixture.refresh([fixture.event(notes: "Reviewed")])
            try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 2)
        }
        let repository = LocalStateRepository(database: try CalopodDatabase(path: path))
        #expect(try repository.inboxObservation(sourceKeyHash: "event")?.acknowledgedRevision == 2)
        #expect(try repository.inboxActivity(connectionID: "connection").isEmpty)
        #expect(try repository.inboxActivity(connectionID: "connection", includeAcknowledged: true).count == 1)
    }
}

private struct Fixture {
    let database: CalopodDatabase
    let repository: LocalStateRepository
    let start = Date(timeIntervalSince1970: 1000)
    let end = Date(timeIntervalSince1970: 20000)

    init(path: String? = nil) throws {
        database = try path.map { try CalopodDatabase(path: $0) } ?? CalopodDatabase.inMemory()
        repository = LocalStateRepository(database: database)
        try repository.saveConnection(StoredConnection(id: "connection", configurationID: "default", provider: "eventkit", displayLabel: "Synthetic", isEnabled: true))
        try repository.replaceCalendarBindings(connectionID: "connection", bindings: [StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "source", displayLabel: "Synthetic", isSelected: true, isReadOnly: true)])
    }

    func event(key: String = "event", notes: String? = nil, response: EventResponseState = .accepted,
               start: Double = 1000, attendees: [EventParticipant] = [], fingerprint: String = "synthetic") -> StoredNormalizedInstance {
        StoredNormalizedInstance(sourceKeyHash: key, connectionID: "connection", calendarBindingID: "calendar",
            providerEventID: key, recurrenceID: nil, startsAt: Date(timeIntervalSince1970: start),
            endsAt: Date(timeIntervalSince1970: start + 1000), isAllDay: false, availability: "busy",
            isCancelled: false, isPrivate: false, title: "Synthetic event", contentFingerprint: fingerprint,
            providerUpdatedAt: nil, notes: notes, attendees: attendees, currentUserResponse: EventResponse(state: response))
    }

    func refresh(_ events: [StoredNormalizedInstance], cancelled: [String] = [], removed: [String] = [],
                 full: Bool = true, start: Double = 1000, end: Double = 20000, cursor: String? = nil,
                 now: Date = Date(timeIntervalSince1970: 2000)) throws {
        try repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar",
            windowStart: Date(timeIntervalSince1970: start), windowEnd: Date(timeIntervalSince1970: end),
            instances: events, cancelledSourceKeyHashes: cancelled, isFullRefresh: full,
            cursorUpdates: cursor.map { [StoredCursorUpdate(scopeKey: "window", value: $0, scopeStart: nil, scopeEnd: nil)] } ?? [],
            now: now, removedSourceKeyHashes: removed)
    }

    func activity(all: Bool = false) throws -> [InboxActivity] {
        try repository.inboxActivity(connectionID: "connection", includeAcknowledged: all)
    }
}
