import CalopodDomain
@testable import CalopodEventKit
import CalopodProviders
import CalopodStore
import EventKit
import Foundation
import Testing

@Suite("EventKit access")
struct EventKitClientTests {
    @Test("Permission is requested only while undecided")
    func deliberatePermissionRequest() async throws {
        let gateway = StubEventKitGateway(status: .notDetermined, statusAfterRequest: .fullAccess)
        let client = EventKitClient(gateway: gateway)

        let status = try await client.requestFullAccess()
        let secondStatus = try await client.requestFullAccess()

        #expect(status == .fullAccess)
        #expect(secondStatus == .fullAccess)
        #expect(await gateway.requestCount == 1)
    }

    @Test("Denied access blocks calendar reads")
    func deniedAccess() async {
        let client = EventKitClient(gateway: StubEventKitGateway(status: .denied))

        await #expect(throws: ProviderFailure.permissionDenied) {
            try await client.calendars()
        }
    }

    @Test("Event reads require an explicit calendar selection")
    func explicitSelection() async throws {
        let gateway = StubEventKitGateway(status: .fullAccess)
        let client = EventKitClient(gateway: gateway)
        let start = Date(timeIntervalSince1970: 1_000)

        await #expect(throws: ProviderFailure.invalidResponse) {
            try await client.events(
                calendarIDs: [],
                from: start,
                through: start.addingTimeInterval(3_600)
            )
        }
        _ = try await client.events(
            calendarIDs: ["selected-calendar"],
            from: start,
            through: start.addingTimeInterval(3_600)
        )
        #expect(await gateway.lastCalendarIDs == ["selected-calendar"])
    }

    @Test("Store notifications are exposed as invalidation signals")
    func changes() async {
        let gateway = StubEventKitGateway(status: .fullAccess)
        let client = EventKitClient(gateway: gateway)
        let stream = await client.changeNotifications()
        var iterator = stream.makeAsyncIterator()

        await gateway.signalChange()

        _ = await iterator.next()
    }

    @Test("Managed writes stay scoped to the selected target")
    func managedWrites() async throws {
        let gateway = StubEventKitGateway(status: .fullAccess)
        let client = EventKitClient(gateway: gateway)
        let request = eventKitManagedRequest()

        let created = try await client.createManagedEvent(calendarID: "target", request: request)
        let updated = try await client.updateManagedEvent(
            calendarID: "target",
            providerEventID: created.providerEventID,
            expectedVersion: created.providerVersion,
            request: request
        )
        try await client.deleteManagedEvent(
            calendarID: "target",
            providerEventID: updated.providerEventID,
            expectedVersion: updated.providerVersion
        )

        #expect(await gateway.lastManagedCalendarID == "target")
        #expect(await gateway.lastManagedRequest == request)
        #expect(await gateway.deletedProviderEventID == updated.providerEventID)
    }

    @Test("Managed target reads stay scoped to the selected target")
    func managedReads() async throws {
        let expected = [
            ManagedEventSnapshot(
                providerEventID: "synthetic-event",
                providerVersion: "v1",
                payload: eventKitManagedRequest().payload,
                markerStatus: .parsed,
                provenance: eventKitManagedRequest().provenance
            ),
        ]
        let gateway = StubEventKitGateway(status: .fullAccess, managedSnapshots: expected)
        let client = EventKitClient(gateway: gateway)
        let start = Date(timeIntervalSince1970: 1_000)

        let snapshots = try await client.managedEvents(
            calendarID: "target",
            from: start,
            through: start.addingTimeInterval(3_600)
        )

        #expect(await gateway.lastManagedCalendarID == "target")
        #expect(snapshots == expected)
    }

    @Test("Full details use native fields without alerts or invitees")
    func fullDetailsPresentation() throws {
        let event = EKEvent(eventStore: EKEventStore())
        event.addAlarm(EKAlarm(relativeOffset: -300))
        let request = eventKitFullDetailsRequest()

        try EventKitManagedEventPresentation.apply(request, to: event)

        #expect(event.title == request.payload.title)
        #expect(event.location == request.payload.location)
        #expect(event.notes == request.payload.notes)
        #expect(event.alarms?.isEmpty != false)
        #expect(event.attendees == nil)
        #expect(event.url?.scheme == "calopod")
        #expect(event.url?.host == "managed")
    }
}

@Suite("EventKit connection state")
struct EventKitConnectionServiceTests {
    @Test("Discovered calendars start unselected and keep later choices")
    func selectionSafety() throws {
        let database = try CalopodDatabase.inMemory()
        let state = LocalStateRepository(database: database)
        let service = EventKitConnectionService(state: state)
        let calendars = [
            EventKitCalendarSnapshot(
                id: "calendar-one",
                title: "Synthetic one",
                sourceID: "source-one",
                sourceTitle: "Synthetic source",
                sourceType: "caldav",
                allowsContentModifications: true
            ),
            EventKitCalendarSnapshot(
                id: "calendar-two",
                title: "Synthetic two",
                sourceID: "source-two",
                sourceTitle: "Local",
                sourceType: "local",
                allowsContentModifications: false
            ),
        ]

        let connection = try service.connect(calendars: calendars)
        let first = try state.calendarBindings(connectionID: connection.id)

        #expect(connection.displayLabel == "Calendars on this Mac")
        #expect(first.count == 2)
        #expect(first.allSatisfy { !$0.isSelected })
        #expect(first.first { $0.providerCalendarID == "calendar-two" }?.isReadOnly == true)

        try database.write { database in
            try database.execute(
                sql: "UPDATE calendar_bindings SET is_selected = 1 WHERE provider_calendar_id = ?",
                arguments: ["calendar-one"]
            )
        }
        let refreshed = try service.refreshCalendars(
            calendars.reversed(),
            connectionID: connection.id
        )
        #expect(refreshed.first { $0.providerCalendarID == "calendar-one" }?.isSelected == true)
    }

    @Test("Calendar refresh preserves configured routes when calendars disappear")
    func configuredRoutesSurviveMissingCalendars() throws {
        let database = try CalopodDatabase.inMemory()
        let state = LocalStateRepository(database: database)
        let service = EventKitConnectionService(state: state)
        let connection = try service.connect(calendars: [
            calendarSnapshot(id: "source"),
            calendarSnapshot(id: "target"),
            calendarSnapshot(id: "unused"),
        ])
        let bindings = try state.calendarBindings(connectionID: connection.id)
        let source = try #require(bindings.first { $0.providerCalendarID == "source" })
        let target = try #require(bindings.first { $0.providerCalendarID == "target" })
        try state.saveArm(
            StoredArm(
                id: "synthetic-arm",
                configurationID: connection.configurationID,
                sourceBindingIDs: [source.id],
                targetBindingID: target.id,
                ruleMode: .busy
            )
        )

        let refreshed = try service.refreshCalendars(
            [calendarSnapshot(id: "new")],
            connectionID: connection.id
        )

        #expect(refreshed.contains { $0.providerCalendarID == "new" })
        #expect(!refreshed.contains { $0.providerCalendarID == "unused" })
        let stored = try state.calendarBindings(connectionID: connection.id)
        #expect(stored.contains { $0.id == source.id })
        #expect(stored.contains { $0.id == target.id })
        #expect(!stored.contains { $0.providerCalendarID == "unused" })
        #expect(try state.arms() == [
            StoredArm(
                id: "synthetic-arm",
                configurationID: connection.configurationID,
                sourceBindingIDs: [source.id],
                targetBindingID: target.id,
                ruleMode: .busy
            ),
        ])
    }

    @Test("Calendar selection is stored explicitly")
    func storedSelection() throws {
        let database = try CalopodDatabase.inMemory()
        let state = LocalStateRepository(database: database)
        let service = EventKitConnectionService(state: state)
        let connection = try service.connect(
            calendars: [
                EventKitCalendarSnapshot(
                    id: "calendar",
                    title: "Synthetic calendar",
                    sourceID: "source",
                    sourceTitle: "Synthetic source",
                    sourceType: "local",
                    allowsContentModifications: true
                ),
            ]
        )
        let binding = try #require(state.calendarBindings(connectionID: connection.id).first)

        let selectedValue = try state.setCalendarSelection(id: binding.id, isSelected: true)
        let deselectedValue = try state.setCalendarSelection(id: binding.id, isSelected: false)
        let selected = try #require(selectedValue)
        let deselected = try #require(deselectedValue)

        #expect(selected.isSelected)
        #expect(!deselected.isSelected)
    }

    @Test("EventKit source labels identify likely direct providers")
    func sourceClassification() {
        #expect(
            EventKitSourceClassifier.likelyDirectProvider(
                sourceType: "caldav",
                sourceLabel: "Google"
            ) == .google
        )
        #expect(
            EventKitSourceClassifier.likelyDirectProvider(
                sourceType: "exchange",
                sourceLabel: "Work"
            ) == .microsoft
        )
        #expect(
            EventKitSourceClassifier.likelyDirectProvider(
                sourceType: "caldav",
                sourceLabel: "Synthetic CalDAV"
            ) == nil
        )
    }

    private func calendarSnapshot(id: String) -> EventKitCalendarSnapshot {
        EventKitCalendarSnapshot(
            id: id,
            title: "Synthetic \(id)",
            sourceID: "synthetic-source",
            sourceTitle: "Synthetic source",
            sourceType: "local",
            allowsContentModifications: true
        )
    }
}

private actor StubEventKitGateway: EventKitGateway {
    var authorizationStatus: EventKitAccessStatus
    var statusAfterRequest: EventKitAccessStatus
    var requestCount = 0
    var lastCalendarIDs: [String] = []
    var lastManagedCalendarID: String?
    var lastManagedRequest: ManagedEventWriteRequest?
    var deletedProviderEventID: String?
    var managedSnapshots: [ManagedEventSnapshot] = []
    private var continuation: AsyncStream<Void>.Continuation?

    init(
        status: EventKitAccessStatus,
        statusAfterRequest: EventKitAccessStatus? = nil,
        managedSnapshots: [ManagedEventSnapshot] = []
    ) {
        authorizationStatus = status
        self.statusAfterRequest = statusAfterRequest ?? status
        self.managedSnapshots = managedSnapshots
    }

    func requestFullAccess() async throws {
        requestCount += 1
        authorizationStatus = statusAfterRequest
    }

    func calendars() -> [EventKitCalendarSnapshot] {
        []
    }

    func events(
        calendarIDs: [String],
        from start: Date,
        through end: Date
    ) -> [ProviderEvent] {
        lastCalendarIDs = calendarIDs
        return []
    }

    func managedEvents(
        calendarID: String,
        from start: Date,
        through end: Date
    ) -> [ManagedEventSnapshot] {
        lastManagedCalendarID = calendarID
        return managedSnapshots
    }

    func createManagedEvent(
        calendarID: String,
        request: ManagedEventWriteRequest
    ) throws -> ManagedEventWriteResult {
        lastManagedCalendarID = calendarID
        lastManagedRequest = request
        return ManagedEventWriteResult(providerEventID: "synthetic-created", providerVersion: "v1")
    }

    func updateManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?,
        request: ManagedEventWriteRequest
    ) throws -> ManagedEventWriteResult {
        lastManagedCalendarID = calendarID
        lastManagedRequest = request
        return ManagedEventWriteResult(providerEventID: providerEventID, providerVersion: "v2")
    }

    func deleteManagedEvent(
        calendarID: String,
        providerEventID: String,
        expectedVersion: String?
    ) throws {
        lastManagedCalendarID = calendarID
        deletedProviderEventID = providerEventID
    }

    func changeNotifications() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func signalChange() {
        continuation?.yield()
    }
}

private func eventKitManagedRequest() -> ManagedEventWriteRequest {
    ManagedEventWriteRequest(
        desiredFingerprint: "synthetic-fingerprint",
        payload: DesiredEventPayload(
            startsAt: Date(timeIntervalSince1970: 2_000),
            endsAt: Date(timeIntervalSince1970: 3_000),
            isAllDay: false,
            availability: "busy",
            title: "Busy",
            isPrivate: nil
        ),
        provenance: ManagedEventProvenance(
            configurationID: "synthetic-configuration",
            armID: "synthetic-arm",
            mirrorKey: "synthetic-mirror",
            sourceKeyHash: "synthetic-source",
            ruleMode: .busy,
            ownershipKeyID: "synthetic-key",
            authenticationTag: "synthetic-tag"
        )
    )
}

private func eventKitFullDetailsRequest() -> ManagedEventWriteRequest {
    ManagedEventWriteRequest(
        desiredFingerprint: "synthetic-full-details-fingerprint",
        payload: DesiredEventPayload(
            startsAt: Date(timeIntervalSince1970: 2_000),
            endsAt: Date(timeIntervalSince1970: 3_000),
            isAllDay: false,
            availability: "busy",
            title: "Synthetic planning session",
            isPrivate: nil,
            location: "Synthetic room",
            notes: "Synthetic agenda and participant context"
        ),
        provenance: ManagedEventProvenance(
            configurationID: "synthetic-configuration",
            armID: "synthetic-arm",
            mirrorKey: "synthetic-mirror",
            sourceKeyHash: "synthetic-source",
            ruleMode: .fullDetails,
            ownershipKeyID: "synthetic-key",
            authenticationTag: "synthetic-tag"
        )
    )
}

@Suite("EventKit all-day dates")
@MainActor
struct EventKitAllDayTests {
    @Test("A source day lands on the same day in the Mac's zone", arguments: [
        "Asia/Tokyo", "Europe/Paris", "America/Los_Angeles",
    ])
    func sameDay(sourceZone: String) throws {
        var source = Calendar(identifier: .gregorian)
        source.timeZone = TimeZone(identifier: sourceZone)!
        let start = source.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let payload = DesiredEventPayload(
            startsAt: start, endsAt: source.date(byAdding: .day, value: 1, to: start)!,
            isAllDay: true, availability: "busy", title: "Busy", isPrivate: nil,
            timeZoneIdentifier: sourceZone
        )
        let mac = TimeZone(identifier: "America/New_York")!

        let (first, last) = EventKitManagedEventPresentation.dates(for: payload, in: mac)

        var local = Calendar(identifier: .gregorian)
        local.timeZone = mac
        #expect(local.dateComponents([.year, .month, .day, .hour], from: first) == DateComponents(year: 2026, month: 10, day: 5, hour: 0))
        #expect(local.dateComponents([.year, .month, .day, .hour, .minute, .second], from: last)
            == DateComponents(year: 2026, month: 10, day: 5, hour: 23, minute: 59, second: 59))
    }
}
