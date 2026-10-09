import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Default inbox attention query")
struct InboxAttentionQueryTests {
    @Test("Every normalized response has its own attention behavior", arguments: [
        EventResponseState.needsResponse, .accepted, .tentative, .declined, .organizer, .notApplicable, .unknown
    ])
    func responses(_ response: EventResponseState) throws {
        let fixture = try AttentionFixture()
        // Tentative occupancy and another attendee's unanswered RSVP do not
        // change the normalized current-user reason.
        try fixture.refresh([fixture.event(response: response, availability: "tentative")])
        let rows = try fixture.query().rows
        let expected: [InboxAttentionReason] = response == .needsResponse ? [.needsResponse] : response == .tentative ? [.maybe] : []
        #expect(rows.first?.reasons ?? [] == expected)
        #expect(rows.count == (expected.isEmpty ? 0 : 1))
        #expect(try fixture.repository.inboxActivity(connectionID: "connection").isEmpty)
    }

    @Test("Only answered baselines reopen after meaningful edits", arguments: [
        EventResponseState.needsResponse, .accepted, .tentative, .declined, .organizer, .notApplicable, .unknown
    ])
    func changedResponses(_ response: EventResponseState) throws {
        let fixture = try AttentionFixture()
        try fixture.refresh([fixture.event(response: response)])
        try fixture.refresh([fixture.event(response: response, notes: "Changed agenda")])
        let baselineKnown = [.accepted, .tentative, .declined].contains(response)
        let rows = try fixture.query().rows
        #expect(rows.first?.reasons.contains(.changedAfterResponse) ?? false == baselineKnown)
        #expect(rows.first?.changeTiming == (baselineKnown ? .afterResponse : nil))
        #expect((try fixture.repository.inboxObservation(sourceKeyHash: "event")?.responseBaseline != nil) == baselineKnown)
    }

    @Test("Same-refresh edit and response carry uncertain timing", arguments: [
        EventResponseState.accepted, .tentative, .declined
    ])
    func ambiguousResponse(_ response: EventResponseState) throws {
        let fixture = try AttentionFixture()
        try fixture.refresh([fixture.event(response: .needsResponse)])
        try fixture.refresh([fixture.event(response: response, notes: "Edit observed with response")])
        let row = try #require(try fixture.query().rows.first)
        #expect(row.reasons.contains(.changedAfterResponse))
        #expect(row.changeTiming == .uncertain)
        // Unchanged refresh cannot turn uncertain order into proven order.
        try fixture.refresh([fixture.event(response: response, notes: "Edit observed with response")])
        #expect(try fixture.query().rows.first?.changeTiming == .uncertain)
        try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: row.item.observation!.revision)
        #expect(try fixture.query().rows.first?.reasons ?? [] == (response == .tentative ? [.maybe] : []))
    }

    @Test("Response-only transitions establish a new baseline without a change alert")
    func responseOnly() throws {
        let fixture = try AttentionFixture()
        try fixture.refresh([fixture.event(response: .accepted)])
        try fixture.refresh([fixture.event(response: .accepted, notes: "Changed")])
        #expect(try fixture.query().rows.first?.reasons == [.changedAfterResponse])
        try fixture.refresh([fixture.event(response: .declined, notes: "Changed")])
        #expect(try fixture.query().rows.isEmpty)
        try fixture.refresh([fixture.event(response: .unknown, notes: "Another change")])
        #expect(try fixture.query().rows.isEmpty)
    }

    @Test("All reasons survive together, and Maybe exclusion hides the entire event")
    func multipleReasons() throws {
        let fixture = try AttentionFixture()
        let neighbor = fixture.event(key: "other", response: .organizer, start: 10500)
        try fixture.refresh([fixture.event(response: .tentative), neighbor])
        try fixture.refresh([fixture.event(response: .tentative, notes: "Changed"), neighbor])
        let before = try fixture.repository.inboxObservation(sourceKeyHash: "event")
        let row = try #require(try fixture.query().rows.first)
        #expect(row.reasons == [.maybe, .changedAfterResponse, .conflict])
        #expect(row.conflicts.count == 1)
        #expect(row.source.calendarLabel == "Example calendar")
        let filtered = try fixture.query(InboxAttentionFilter(excludeMaybe: true))
        #expect(filtered.rows.map(\.item.event.sourceKeyHash) == ["other"])
        #expect(filtered.rows[0].reasons == [.conflict])
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event") == before)
        try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 2)
        #expect(try fixture.query().rows.first?.reasons == [.maybe, .conflict])
        try fixture.refresh([fixture.event(response: .tentative, notes: "Newer edit"), neighbor])
        try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 2)
        #expect(try fixture.query().rows.first?.reasons == [.maybe, .changedAfterResponse, .conflict])
    }

    @Test("Needs RSVP and real conflicts survive review; settled conflicts stay eligible")
    func reviewAndConflicts() throws {
        let fixture = try AttentionFixture()
        let events = [fixture.event(response: .needsResponse),
                      fixture.event(key: "accepted", response: .accepted, start: 10500),
                      fixture.event(key: "declined", response: .declined, start: 10500),
                      fixture.event(key: "free", response: .accepted, start: 10500, availability: "free")]
        try fixture.refresh(events)
        try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 1)
        let rows = try fixture.query().rows
        #expect(rows.map(\.reasons) == [[.needsResponse, .conflict], [.conflict]])
        let conflicts = try fixture.query(InboxAttentionFilter(conflictsOnly: true))
        #expect(conflicts.rows.map(\.item.event.sourceKeyHash) == ["event", "accepted"])
        try fixture.refresh([fixture.event(response: .needsResponse), fixture.event(key: "accepted", response: .declined, start: 10500)])
        #expect(try fixture.query().rows.first?.reasons == [.needsResponse])
        #expect(try fixture.query(InboxAttentionFilter(conflictsOnly: true)).rows.isEmpty)
    }

    @Test("Confirmed cancellations and removals remain in activity, never attention")
    func tombstones() throws {
        let fixture = try AttentionFixture()
        try fixture.refresh([fixture.event(response: .needsResponse), fixture.event(key: "removed", response: .tentative)])
        try fixture.refresh([], cancelled: ["event"], removed: ["removed"])
        #expect(try fixture.query().rows.isEmpty)
        #expect(try fixture.repository.inboxActivity(connectionID: "connection").count == 2)
    }

    @Test("No filter includes retained history; overlap and both move intervals match once")
    func intervals() throws {
        let fixture = try AttentionFixture()
        let original = fixture.event(response: .tentative)
        try fixture.refresh([original])
        try fixture.refresh([fixture.event(response: .tentative, start: 30000)])
        try fixture.refresh([fixture.event(response: .tentative, start: 30000, notes: "Later edit")])
        #expect(try fixture.query().rows.count == 1)
        for range in [try window(10000, 11000), try window(30000, 31000), try window(10000, 31000)] {
            #expect(try fixture.query(InboxAttentionFilter(window: range)).rows.count == 1)
        }
        for range in [try window(11000, 12000), try window(29000, 30000)] {
            #expect(try fixture.query(InboxAttentionFilter(window: range)).rows.isEmpty)
        }
        // Conflict detection uses the moved event's complete current interval,
        // even when the row matches only its previous interval.
        try fixture.refresh([fixture.event(response: .tentative, start: 30000, notes: "Later edit"),
                             fixture.event(key: "neighbor", response: .accepted, start: 30500)])
        let oldDay = try fixture.query(InboxAttentionFilter(window: window(10000, 11000)))
        #expect(oldDay.rows.count == 1)
        #expect(oldDay.rows[0].reasons == [.maybe, .changedAfterResponse, .conflict])
        #expect(oldDay.rows[0].conflicts[0].overlap.start == date(30500))
        // Moving beyond coverage retains the event with explicit uncertainty.
        try fixture.refresh([fixture.event(response: .tentative, start: 60000)], cached: [])
        #expect(try fixture.query().rows.count == 1)
        let moved = try #require(try fixture.query().rows.first { $0.item.event.sourceKeyHash == "event" })
        #expect(!moved.item.isPresenceConfirmed)
        #expect(try fixture.query().analysis.warnings.contains { $0.kind == .unconfirmedPresence })
    }

    @Test("Recurring occurrences keep distinct identities and stable start ordering")
    func recurrence() throws {
        let fixture = try AttentionFixture()
        try fixture.refresh([fixture.event(key: "occurrence-b", response: .tentative, recurrenceID: "series/2"),
                             fixture.event(key: "occurrence-a", response: .tentative, recurrenceID: "series/1"),
                             fixture.event(key: "earlier", response: .needsResponse, start: 5000)])
        let rows = try fixture.query().rows
        #expect(rows.map(\.item.event.sourceKeyHash) == ["earlier", "occurrence-a", "occurrence-b"])
        #expect(rows.map(\.item.event.recurrenceID) == [nil, "series/1", "series/2"])
        #expect(rows.count == 3)
    }

    @Test("Multi-day and daylight-saving days use normalized local intervals", arguments: ["2026-03-08", "2026-11-01"])
    func localDays(_ day: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let parts = day.split(separator: "-").map { Int($0)! }
        let start = try #require(calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])))
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        #expect(end.timeIntervalSince(start) == (day.contains("03-08") ? 23 : 25) * 3600)
        let fixture = try AttentionFixture()
        let event = fixture.event(response: .needsResponse, start: start.timeIntervalSince1970 - 3600,
                                  end: end.timeIntervalSince1970 + 3600, allDay: true)
        try fixture.refresh([event], coverage: window(start.timeIntervalSince1970 - 86400, end.timeIntervalSince1970 + 86400))
        let result = try fixture.query(InboxAttentionFilter(window: SyncWindow(start: start, end: end)))
        #expect(result.rows.count == 1)
        #expect(result.rows[0].item.event.startsAt == event.startsAt)
        #expect(result.rows[0].item.event.endsAt == event.endsAt)
        #expect(try fixture.query(InboxAttentionFilter(window: window(event.endsAt.timeIntervalSince1970, event.endsAt.timeIntervalSince1970 + 3600))).rows.isEmpty)
    }

    @Test("Stale, missing and partial coverage remains visible, including an empty queue")
    func freshness() throws {
        let fixture = try AttentionFixture()
        try fixture.refresh([fixture.event(response: .accepted)])
        try fixture.repository.markConnectionStale(connectionID: "connection", errorCode: "synthetic-unavailable")
        let empty = try fixture.query()
        #expect(empty.rows.isEmpty)
        #expect(empty.sources[0].coverage?.observedAt == date(500))
        #expect(empty.sources[0].healthStatus == "stale")
        #expect(empty.analysis.warnings.contains { $0.kind == .staleSource })
        #expect(!empty.analysis.isComplete)
        let wider = try fixture.query(InboxAttentionFilter(window: window(-1000, 60000)))
        #expect(wider.analysis.warnings.contains { $0.kind == .incompleteCoverage })
        let missing = InboxAttentionQuery.evaluate(InboxContextSnapshot(sources: [InboxContextSource(bindingID: "empty", connectionID: "empty", provider: "ics")], events: []), freshnessCutoff: date(100))
        #expect(missing.analysisWindow == nil)
        #expect(missing.analysis.warnings.map(\.kind) == [.unknownSource, .incompleteCoverage])
        let none = InboxAttentionQuery.evaluate(InboxContextSnapshot(sources: [], events: []), freshnessCutoff: date(100))
        #expect(none.analysis.warnings.map(\.kind) == [.noSelectedSources])
        #expect(!none.analysis.isComplete)
    }

    @Test("Pruned change history still queues unread changes, and reading never acknowledges")
    func pruning() throws {
        let fixture = try AttentionFixture()
        try fixture.refresh([fixture.event(response: .declined)])
        try fixture.refresh([fixture.event(response: .declined, notes: "Changed")])
        try fixture.refresh([fixture.event(response: .declined, notes: "Changed")], now: date(500 + 91 * 86400))
        #expect(try fixture.repository.inboxActivity(connectionID: "connection").isEmpty)
        #expect(try fixture.query().rows.first?.reasons == [.changedAfterResponse])
        #expect(try fixture.query().rows.first?.reasons == [.changedAfterResponse])
        #expect(try fixture.repository.inboxObservation(sourceKeyHash: "event")?.acknowledgedRevision == nil)
        try fixture.repository.acknowledgeInboxRevision(sourceKeyHash: "event", revision: 2)
        #expect(try fixture.query().rows.isEmpty)
    }

    func date(_ value: Double) -> Date { Date(timeIntervalSince1970: value) }
    func window(_ start: Double, _ end: Double) throws -> SyncWindow { try SyncWindow(start: date(start), end: date(end)) }
}

private struct AttentionFixture {
    let repository: LocalStateRepository

    init() throws {
        repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(id: "connection", configurationID: "default", provider: "google", displayLabel: "Example Connection", isEnabled: true))
        try repository.replaceCalendarBindings(connectionID: "connection", bindings: [StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "source", displayLabel: "Example calendar", isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser)])
    }

    func event(key: String = "event", response: EventResponseState, start: Double = 10000, end: Double? = nil,
               notes: String? = nil, availability: String = "busy", allDay: Bool = false,
               recurrenceID: String? = nil) -> StoredNormalizedInstance {
        StoredNormalizedInstance(sourceKeyHash: key, connectionID: "connection", calendarBindingID: "calendar",
            providerEventID: recurrenceID == nil ? key : "series", recurrenceID: recurrenceID,
            startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: end ?? start + 1000),
            isAllDay: allDay, availability: availability, isCancelled: false, isPrivate: false,
            title: "Example invitation", contentFingerprint: "synthetic", providerUpdatedAt: nil, notes: notes,
            attendees: [EventParticipant(name: "Example guest", emailAddress: "guest@example.com", status: "needsAction")],
            currentUserResponse: EventResponse(state: response, evidence: .googleSelf))
    }

    func refresh(_ events: [StoredNormalizedInstance], cancelled: [String] = [], removed: [String] = [],
                 cached: [StoredNormalizedInstance]? = nil, coverage: SyncWindow? = nil,
                 now: Date = Date(timeIntervalSince1970: 500)) throws {
        try repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar",
            windowStart: coverage?.start ?? Date(timeIntervalSince1970: 0),
            windowEnd: coverage?.end ?? Date(timeIntervalSince1970: 50000),
            instances: cached ?? events, cancelledSourceKeyHashes: cancelled, isFullRefresh: true,
            cursorUpdates: [], now: now, observationInstances: events, removedSourceKeyHashes: removed)
    }

    func query(_ filter: InboxAttentionFilter = InboxAttentionFilter()) throws -> InboxAttentionResult {
        InboxAttentionQuery.evaluate(try repository.inboxContextSnapshot(), filter: filter,
                                     freshnessCutoff: Date(timeIntervalSince1970: 100))
    }
}
