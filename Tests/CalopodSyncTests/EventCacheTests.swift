import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Normalized event cache")
struct EventCacheTests {
    @Test("Normalization covers recurrence, privacy, availability, cancellation, and malformed input")
    func normalization() {
        let connection = testConnection()
        let calendar = testCalendar(connectionID: connection.id)
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(86_400)
        let events = [
            event(
                id: "all-day",
                start: start,
                end: end,
                allDay: true,
                availability: .free,
                isPrivate: true,
                title: "Synthetic private day",
                location: "Synthetic room",
                notes: "Synthetic agenda",
                url: "https://calendar.example.test/events/all-day",
                organizer: EventParticipant(
                    name: "Synthetic Organizer",
                    emailAddress: "organizer@example.com"
                ),
                attendees: [
                    EventParticipant(
                        name: "Synthetic Attendee",
                        emailAddress: "attendee@example.com",
                        status: "accepted"
                    ),
                ]
            ),
            event(
                id: "occurrence",
                seriesID: "series",
                originalStart: "2026-03-08T09:00:00-04:00",
                start: start.addingTimeInterval(3_600),
                end: start.addingTimeInterval(5_400),
                availability: .tentative,
                title: "Synthetic recurrence"
            ),
            event(id: "cancelled", isCancelled: true),
            event(
                id: "managed-mirror",
                start: start.addingTimeInterval(7_200),
                end: start.addingTimeInterval(9_000),
                isManagedMirror: true
            ),
            event(id: "missing-end", start: start, end: nil),
            event(
                id: "outside",
                start: end.addingTimeInterval(60),
                end: end.addingTimeInterval(120)
            ),
        ]

        let result = EventNormalizer.normalize(
            events,
            connection: connection,
            calendar: calendar,
            from: start,
            through: end
        )

        #expect(result.instances.count == 2)
        #expect(result.cancelledSourceKeyHashes.count == 1)
        #expect(result.discardedCount == 3)
        #expect(result.ingestion == EventIngestionSummary(excludedMarkedCopyCount: 1, invalidTimespanCount: 1, outOfRangeCount: 1))
        #expect(result.instances[0].isAllDay)
        #expect(result.instances[0].availability == "free")
        #expect(result.instances[0].isPrivate)
        #expect(result.instances[0].location == "Synthetic room")
        #expect(result.instances[0].notes == "Synthetic agenda")
        #expect(result.instances[0].url == "https://calendar.example.test/events/all-day")
        #expect(result.instances[0].organizer?.emailAddress == "organizer@example.com")
        #expect(result.instances[0].attendees.first?.status == "accepted")
        #expect(result.instances[1].availability == "tentative")
        #expect(result.instances[1].recurrenceID == "2026-03-08T09:00:00-04:00")
        #expect(result.instances.allSatisfy { $0.sourceKeyHash.count == 64 })
    }

    @Test("Expected exclusions, invalid records, and window boundaries are separate")
    func ingestionCategories() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(100)
        let result = EventNormalizer.normalize([
            event(id: "marked-and-mapped", isManagedMirror: true),
            event(id: "mapped", start: nil, end: nil),
            event(id: "", isManagedMirror: true),
            event(id: "missing-time", start: start, end: nil),
            event(id: "zero-duration", start: start, end: start),
            event(id: "reversed", start: end, end: start),
            event(id: "left-boundary", start: start.addingTimeInterval(-10), end: start),
            event(id: "right-boundary", start: end, end: end.addingTimeInterval(10)),
            event(id: "overlap", start: start.addingTimeInterval(-10), end: start.addingTimeInterval(10)),
            event(id: "cancelled", isCancelled: true),
        ], connection: testConnection(), calendar: testCalendar(connectionID: "connection"),
           from: start, through: end, excludedEventIDs: ["marked-and-mapped", "mapped"])
        #expect(result.ingestion == EventIngestionSummary(
            excludedMarkedCopyCount: 1, excludedMappedCopyCount: 1,
            invalidIdentityCount: 1, invalidTimespanCount: 3, outOfRangeCount: 2
        ))
        #expect(result.discardedCount == 8)
        #expect(result.instances.count == 1)
        #expect(result.cancelledSourceKeyHashes.count == 1)
        #expect(result.excludedSourceKeyHashes.count == 2)
        #expect(result.ingestion.warnings == [
            "Ignored event records with invalid identity: 1.",
            "Ignored event records with invalid timespans: 3.",
        ])
        #expect(EventIngestionSummary(excludedMarkedCopyCount: 3, excludedMappedCopyCount: 2, outOfRangeCount: 1).warnings.isEmpty)
        var combined = EventIngestionSummary()
        combined.add(result.ingestion)
        combined.add(result.ingestion)
        #expect(combined.discardedCount == 16)
        #expect(combined.invalidTimespanCount == 6)
    }

    @Test("Wrong provider, connection, or calendar remains an invalid identity")
    func mismatchedIdentity() {
        let result = EventNormalizer.normalize([
            event(id: "wrong-provider", isManagedMirror: true, provider: "google"),
            event(id: "wrong-connection", connectionID: "other-connection"),
            event(id: "wrong-calendar", calendarID: "other-calendar"),
        ], connection: testConnection(), calendar: testCalendar(connectionID: "connection"),
           from: Date(timeIntervalSince1970: 1_000), through: Date(timeIntervalSince1970: 2_000))
        #expect(result.ingestion == EventIngestionSummary(invalidIdentityCount: 3))
        #expect(result.instances.isEmpty)
        #expect(result.excludedSourceKeyHashes.isEmpty)
    }

    @Test("Full and incremental refreshes converge cache and cursors")
    func refreshLifecycle() throws {
        let database = try CalopodDatabase.inMemory()
        let repository = LocalStateRepository(database: database)
        let connection = testConnection()
        let calendar = testCalendar(connectionID: connection.id)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(
            connectionID: connection.id,
            bindings: [calendar]
        )
        let cache = EventCache(repository: repository)
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(86_400)

        let initial = ProviderEventPage(
            events: [
                event(
                    id: "one",
                    start: start,
                    end: start.addingTimeInterval(1_800),
                    location: "Synthetic room",
                    notes: "Synthetic agenda",
                    attendees: [EventParticipant(name: "Synthetic Guest", status: "tentative")]
                ),
                event(
                    id: "two",
                    start: start.addingTimeInterval(1_800),
                    end: start.addingTimeInterval(3_600)
                ),
            ],
            nextSyncToken: "cursor-one",
            refreshMode: .full,
            cursorUpdates: [
                ProviderCursorUpdate(
                    scopeKey: "synthetic-window",
                    value: "cursor-one",
                    scopeStart: start,
                    scopeEnd: end
                ),
            ]
        )
        let initialResult = try cache.apply(
            initial,
            connection: connection,
            calendar: calendar,
            from: start,
            through: end
        )
        #expect(initialResult.storedCount == 2)
        #expect(initialResult.ingestion == EventIngestionSummary())
        let initialStored = try repository.normalizedInstances(
            calendarBindingIDs: [calendar.id],
            from: start,
            through: end
        )
        #expect(initialStored.count == 2)
        #expect(initialStored[0].location == "Synthetic room")
        #expect(initialStored[0].notes == "Synthetic agenda")
        #expect(initialStored[0].attendees.first?.status == "tentative")
        #expect(
            try repository.cursor(
                connectionID: connection.id,
                calendarBindingID: calendar.id,
                scopeKey: "synthetic-window"
            ) == "cursor-one"
        )

        let rediscoveredCalendar = StoredCalendarBinding(
            id: calendar.id,
            connectionID: connection.id,
            providerCalendarID: calendar.providerCalendarID,
            displayLabel: "Renamed synthetic calendar",
            isSelected: false,
            isReadOnly: true
        )
        try repository.replaceCalendarBindings(
            connectionID: connection.id,
            bindings: [rediscoveredCalendar]
        )
        let rediscoveredBindings = try repository.calendarBindings(connectionID: connection.id)
        let preservedBinding = try #require(rediscoveredBindings.first)
        #expect(preservedBinding.isSelected)
        #expect(preservedBinding.displayLabel == "Renamed synthetic calendar")
        #expect(
            try repository.normalizedInstances(
                calendarBindingIDs: [calendar.id],
                from: start,
                through: end
            ).count == 2
        )

        let incremental = ProviderEventPage(
            events: [
                event(
                    id: "one",
                    start: start,
                    end: start.addingTimeInterval(2_400),
                    title: "Synthetic update"
                ),
                event(id: "two", isCancelled: true),
            ],
            nextSyncToken: "cursor-two",
            refreshMode: .incremental,
            cursorUpdates: [
                ProviderCursorUpdate(
                    scopeKey: "synthetic-window",
                    value: "cursor-two",
                    scopeStart: start,
                    scopeEnd: end
                ),
            ]
        )
        let incrementalResult = try cache.apply(
            incremental,
            connection: connection,
            calendar: calendar,
            from: start,
            through: end
        )
        let remaining = try repository.normalizedInstances(
            calendarBindingIDs: [calendar.id],
            from: start,
            through: end
        )

        #expect(incrementalResult.cancelledCount == 1)
        #expect(remaining.count == 1)
        #expect(remaining[0].title == "Synthetic update")
        #expect(remaining[0].endsAt == start.addingTimeInterval(2_400))
        #expect(remaining[0].location == nil)
        #expect(remaining[0].notes == nil)
        #expect(remaining[0].attendees.isEmpty)
        #expect(
            try repository.cursor(
                connectionID: connection.id,
                calendarBindingID: calendar.id,
                scopeKey: "synthetic-window"
            ) == "cursor-two"
        )
        #expect(try repository.connectionHealth(connectionID: connection.id)?.status == "healthy")

        _ = try cache.apply(
            ProviderEventPage(events: [], nextSyncToken: nil, refreshMode: .full),
            connection: connection,
            calendar: calendar,
            from: start,
            through: end
        )
        #expect(
            try repository.normalizedInstances(
                calendarBindingIDs: [calendar.id],
                from: start,
                through: end
            ).isEmpty
        )
    }

    @Test("Stale health keeps the first failure time")
    func staleHealth() throws {
        let database = try CalopodDatabase.inMemory()
        let repository = LocalStateRepository(database: database)
        let connection = testConnection()
        try repository.saveConnection(connection)
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)

        try repository.markConnectionStale(
            connectionID: connection.id,
            errorCode: "temporary",
            now: first
        )
        try repository.markConnectionStale(
            connectionID: connection.id,
            errorCode: "permission",
            now: second
        )
        let storedHealth = try repository.connectionHealth(connectionID: connection.id)
        let health = try #require(storedHealth)

        #expect(health.status == "stale")
        #expect(health.staleSince == first)
        #expect(health.checkedAt == second)
        #expect(health.errorCode == "permission")
    }

    @Test("Response evidence survives refresh independently from availability and content")
    func responseCacheRoundTrip() throws {
        let database = try CalopodDatabase.inMemory()
        let repository = LocalStateRepository(database: database)
        let connection = testConnection()
        let calendar = testCalendar(connectionID: connection.id)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(3_600)
        let cache = EventCache(repository: repository)
        var fingerprints: Set<String> = []
        for state: EventResponseState in [.needsResponse, .tentative, .accepted, .declined, .organizer, .notApplicable, .unknown] {
            let response = EventResponse(state: state, respondedAt: start, evidence: .eventKitCurrentUser)
            let source = event(id: "synthetic", start: start, end: end, availability: .tentative,
                               responseMetadata: response)
            try cache.apply(ProviderEventPage(events: [source], nextSyncToken: nil),
                            connection: connection, calendar: calendar, from: start, through: end)
            let stored = try #require(repository.normalizedInstances(calendarBindingIDs: [calendar.id],
                                                                     from: start, through: end).first)
            #expect(stored.currentUserResponse == response)
            #expect(stored.availability == "tentative")
            fingerprints.insert(stored.contentFingerprint)
        }
        #expect(fingerprints.count == 1)
        let source = event(id: "synthetic", start: start, end: end)
        try cache.apply(ProviderEventPage(events: [source], nextSyncToken: nil, refreshMode: .incremental),
                        connection: connection, calendar: calendar, from: start, through: end)
        let stored = try #require(repository.normalizedInstances(calendarBindingIDs: [calendar.id],
                                                                 from: start, through: end).first)
        #expect(stored.currentUserResponse == .unavailable)
    }

    @Test("ICS response identity remains unsupported")
    func icsResponseIsExplicit() {
        let source = ProviderEvent(provider: "ics", connectionID: "feed", calendarID: "calendar",
                                   eventID: "event", seriesID: nil, originalStart: nil,
                                   start: nil, end: nil, isAllDay: false, availability: .tentative,
                                   isCancelled: false, isPrivate: false, title: nil, updatedAt: nil,
                                   attendees: [EventParticipant(status: "needsAction")])
        #expect(source.currentUserResponse == .readOnlyFeed)
    }

    @Test("Private inbox detail stays out of Busy planning and ingestion diagnostics",
          arguments: [EventResponseState.needsResponse, .tentative, .accepted, .declined, .unknown])
    func inboxPrivacy(_ response: EventResponseState) throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = testConnection()
        let calendar = testCalendar(connectionID: connection.id)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
        let cache = EventCache(repository: repository)
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(10000)
        try cache.apply(ProviderEventPage(events: [event(id: "private", start: start, end: end)], nextSyncToken: nil),
                        connection: connection, calendar: calendar, from: start, through: end)
        let result = try cache.apply(ProviderEventPage(events: [event(id: "private", start: start, end: end,
            title: "Synthetic confidential title", location: "Synthetic confidential room",
            notes: "Synthetic confidential notes", url: "https://example.com/confidential",
            organizer: EventParticipant(name: "Synthetic confidential organizer", emailAddress: "organizer@example.com"),
            attendees: [EventParticipant(emailAddress: "guest@example.com")],
            responseMetadata: EventResponse(state: response, respondedAt: start, evidence: .eventKitCurrentUser))], nextSyncToken: nil),
            connection: connection, calendar: calendar, from: start, through: end)
        #expect(try repository.inboxActivity(connectionID: connection.id).first?.event.notes == "Synthetic confidential notes")
        let sources = try repository.normalizedInstances(calendarBindingIDs: [calendar.id], from: start, through: end)
        let plan = SyncPlanner.plan(arm: StoredArm(id: "arm", configurationID: "default",
            sourceBindingIDs: [calendar.id], targetBindingID: "target", ruleMode: .busy),
            sources: sources, mappings: [], targetEvents: [], window: try SyncWindow(start: start, end: end),
            sourceSnapshotComplete: true)
        let payload = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        let diagnostics = String(decoding: try JSONEncoder().encode(result.ingestion), as: UTF8.self)
        #expect(sources.first?.currentUserResponse.state == response)
        for text in [payload, diagnostics] {
            for privateField in ["Synthetic confidential", "example.com", "responseMetadata", "respondedAt", "eventkit-current-user"] {
                #expect(!text.contains(privateField))
            }
        }
        #expect(plan.items.first?.payload?.title == "Busy")
    }

    @Test("Partial reads do not commit observations, events, coverage or cursors")
    func incompleteRead() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = testConnection()
        let calendar = testCalendar(connectionID: connection.id)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
        let cache = EventCache(repository: repository)
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(10000)
        let partial = ProviderEventPage(events: [event(id: "partial", start: start, end: end)],
            nextSyncToken: "unsafe", cursorUpdates: [ProviderCursorUpdate(scopeKey: "window", value: "unsafe", scopeStart: start, scopeEnd: end)],
            readIsComplete: false)
        #expect(throws: EventCacheError.incompleteRead) {
            try cache.apply(partial, connection: connection, calendar: calendar, from: start, through: end)
        }
        #expect(try repository.inboxActivity(connectionID: connection.id, includeAcknowledged: true).isEmpty)
        #expect(try repository.normalizedInstances(calendarBindingIDs: [calendar.id], from: start, through: end).isEmpty)
        #expect(try repository.inboxCoverage(connectionID: connection.id, calendarBindingID: calendar.id) == nil)
        #expect(try repository.cursor(connectionID: connection.id, calendarBindingID: calendar.id, scopeKey: "window") == nil)
        // A subsequent complete first import still establishes a quiet baseline.
        try cache.apply(ProviderEventPage(events: partial.events, nextSyncToken: nil),
                        connection: connection, calendar: calendar, from: start, through: end)
        #expect(try repository.inboxActivity(connectionID: connection.id).isEmpty)
    }

    @Test("Recurring exceptions, outside-window moves and mirror eviction preserve inbox identity")
    func observationIdentity() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = testConnection()
        let calendar = testCalendar(connectionID: connection.id)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
        let cache = EventCache(repository: repository)
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(10000)
        let original = "2026-11-05T09:00:00Z"
        let other = "2026-11-06T09:00:00Z"
        func refresh(_ events: [ProviderEvent], full: Bool = false) throws {
            try cache.apply(ProviderEventPage(events: events, nextSyncToken: nil, refreshMode: full ? .full : .incremental),
                            connection: connection, calendar: calendar, from: start, through: end)
        }
        try refresh([event(id: "series", originalStart: original, start: start, end: start.addingTimeInterval(1000)),
                     event(id: "series", originalStart: other, start: start.addingTimeInterval(2000), end: start.addingTimeInterval(3000))], full: true)
        try refresh([event(id: "series", originalStart: original, start: end.addingTimeInterval(1000),
                           end: end.addingTimeInterval(2000), notes: "Synthetic moved agenda")])
        let activity = try #require(try repository.inboxActivity(connectionID: connection.id).first)
        #expect(activity.changedFields == ["time", "notes"])
        #expect(activity.previousEvent?.startsAt == start)
        #expect(activity.event.startsAt > end)
        #expect(try repository.normalizedInstances(calendarBindingIDs: [calendar.id], from: start, through: end).count == 1)
        let key = activity.sourceKeyHash
        #expect(try repository.inboxObservation(sourceKeyHash: key)?.revision == 2)
        try refresh([event(id: "series", originalStart: original, isManagedMirror: true)])
        #expect(try repository.inboxObservation(sourceKeyHash: key) == nil)
        #expect(try repository.inboxActivity(connectionID: connection.id, includeAcknowledged: true).isEmpty)
    }

    @Test("Confirmed removals and uncertain disappearance have different inbox evidence")
    func removalEvidence() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = testConnection()
        let calendar = testCalendar(connectionID: connection.id)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
        let cache = EventCache(repository: repository)
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(10000)
        try cache.apply(ProviderEventPage(events: [event(id: "confirmed", start: start, end: end),
                                                 event(id: "uncertain", start: start, end: end)], nextSyncToken: nil),
                        connection: connection, calendar: calendar, from: start, through: end)
        let tombstones = [ProviderTombstoneEvidence.removed, .unconfirmed].enumerated().map { index, evidence in
            ProviderEvent(provider: "eventkit", connectionID: connection.id, calendarID: calendar.providerCalendarID,
                          eventID: index == 0 ? "confirmed" : "uncertain", seriesID: nil, originalStart: nil,
                          start: nil, end: nil, isAllDay: false, availability: .busy, isCancelled: true,
                          isPrivate: false, title: nil, updatedAt: nil, tombstoneEvidence: evidence)
        }
        try cache.apply(ProviderEventPage(events: tombstones, nextSyncToken: nil, refreshMode: .incremental),
                        connection: connection, calendar: calendar, from: start, through: end)
        let activity = try repository.inboxActivity(connectionID: connection.id)
        #expect(activity.count == 1)
        #expect(activity.first?.types == [.removed])
        #expect(activity.first?.event.endsAt == end)
        let uncertainKey = EventNormalizer.sourceKeyHash(provider: connection.provider, connectionID: connection.id,
                                                         calendarBindingID: calendar.id, eventID: "uncertain")
        #expect(try repository.inboxObservation(sourceKeyHash: uncertainKey)?.tombstone == nil)
        #expect(try repository.normalizedInstances(calendarBindingIDs: [calendar.id], from: start, through: end).isEmpty)
    }

    @Test("New coverage establishes baselines and does not manufacture removals")
    func windowExpansion() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = testConnection()
        let calendar = testCalendar(connectionID: connection.id)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
        let cache = EventCache(repository: repository)
        let start = Date(timeIntervalSince1970: 1000)
        let end = start.addingTimeInterval(10000)
        try cache.apply(ProviderEventPage(events: [event(id: "old", start: start, end: start.addingTimeInterval(1000))], nextSyncToken: nil),
                        connection: connection, calendar: calendar, from: start, through: end)
        try cache.apply(ProviderEventPage(events: [event(id: "expanded", start: end, end: end.addingTimeInterval(1000))], nextSyncToken: nil),
                        connection: connection, calendar: calendar, from: start, through: end.addingTimeInterval(10000))
        #expect(try repository.inboxActivity(connectionID: connection.id).isEmpty)
        let key = EventNormalizer.sourceKeyHash(provider: connection.provider, connectionID: connection.id,
                                               calendarBindingID: calendar.id, eventID: "old")
        #expect(try repository.inboxObservation(sourceKeyHash: key)?.tombstone == nil)
    }

    private func testConnection() -> StoredConnection {
        StoredConnection(
            id: "connection",
            configurationID: "default",
            provider: "eventkit",
            displayLabel: "Synthetic Connection",
            isEnabled: true
        )
    }

    private func testCalendar(connectionID: String) -> StoredCalendarBinding {
        StoredCalendarBinding(
            id: "calendar-binding",
            connectionID: connectionID,
            providerCalendarID: "provider-calendar",
            displayLabel: "Synthetic calendar",
            isSelected: true,
            isReadOnly: false
        )
    }

    private func event(
        id: String,
        seriesID: String? = nil,
        originalStart: String? = nil,
        start: Date? = nil,
        end: Date? = nil,
        allDay: Bool = false,
        availability: ProviderAvailability = .busy,
        isCancelled: Bool = false,
        isPrivate: Bool = false,
        title: String? = "Synthetic event",
        isManagedMirror: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        organizer: EventParticipant? = nil,
        attendees: [EventParticipant] = [],
        responseMetadata: EventResponse? = nil,
        provider: String = "eventkit",
        connectionID: String = "connection",
        calendarID: String = "provider-calendar"
    ) -> ProviderEvent {
        ProviderEvent(
            provider: provider,
            connectionID: connectionID,
            calendarID: calendarID,
            eventID: id,
            seriesID: seriesID,
            originalStart: originalStart,
            start: start,
            end: end,
            isAllDay: allDay,
            availability: availability,
            isCancelled: isCancelled,
            isPrivate: isPrivate,
            title: title,
            updatedAt: nil,
            isManagedMirror: isManagedMirror,
            location: location,
            notes: notes,
            url: url,
            organizer: organizer,
            attendees: attendees,
            responseMetadata: responseMetadata
        )
    }
}
