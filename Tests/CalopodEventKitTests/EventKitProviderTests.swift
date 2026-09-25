import CalopodDomain
import CalopodEventKit
import CalopodProviders
import CalopodStore
import Foundation
import Testing

@Suite("EventKit access")
@MainActor
struct EventKitClientTests {
    @Test("Permission is requested only while undecided")
    func deliberatePermissionRequest() async throws {
        let gateway = StubEventKitGateway(status: .notDetermined)
        gateway.statusAfterRequest = .fullAccess
        let client = EventKitClient(gateway: gateway)

        let status = try await client.requestFullAccess()
        let secondStatus = try await client.requestFullAccess()

        #expect(status == .fullAccess)
        #expect(secondStatus == .fullAccess)
        #expect(gateway.requestCount == 1)
    }

    @Test("Denied access blocks calendar reads")
    func deniedAccess() throws {
        let client = EventKitClient(gateway: StubEventKitGateway(status: .denied))

        #expect(throws: ProviderFailure.permissionDenied) {
            try client.calendars()
        }
    }

    @Test("Event reads require an explicit calendar selection")
    func explicitSelection() throws {
        let gateway = StubEventKitGateway(status: .fullAccess)
        let client = EventKitClient(gateway: gateway)
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(throws: ProviderFailure.invalidResponse) {
            try client.events(
                calendarIDs: [],
                from: start,
                through: start.addingTimeInterval(3_600)
            )
        }
        _ = try client.events(
            calendarIDs: ["selected-calendar"],
            from: start,
            through: start.addingTimeInterval(3_600)
        )
        #expect(gateway.lastCalendarIDs == ["selected-calendar"])
    }

    @Test("Store notifications are exposed as invalidation signals")
    func changes() async {
        let gateway = StubEventKitGateway(status: .fullAccess)
        let client = EventKitClient(gateway: gateway)
        let stream = client.changeNotifications()
        var iterator = stream.makeAsyncIterator()

        gateway.signalChange()

        _ = await iterator.next()
    }

    @Test("Managed writes stay scoped to the selected target")
    func managedWrites() throws {
        let gateway = StubEventKitGateway(status: .fullAccess)
        let client = EventKitClient(gateway: gateway)
        let request = eventKitManagedRequest()

        let created = try client.createManagedEvent(calendarID: "target", request: request)
        let updated = try client.updateManagedEvent(
            calendarID: "target",
            providerEventID: created.providerEventID,
            expectedVersion: created.providerVersion,
            request: request
        )
        try client.deleteManagedEvent(
            calendarID: "target",
            providerEventID: updated.providerEventID,
            expectedVersion: updated.providerVersion
        )

        #expect(gateway.lastManagedCalendarID == "target")
        #expect(gateway.lastManagedRequest == request)
        #expect(gateway.deletedProviderEventID == updated.providerEventID)
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
}

@MainActor
private final class StubEventKitGateway: EventKitGateway {
    var authorizationStatus: EventKitAccessStatus
    var statusAfterRequest: EventKitAccessStatus
    var requestCount = 0
    var lastCalendarIDs: [String] = []
    var lastManagedCalendarID: String?
    var lastManagedRequest: ManagedEventWriteRequest?
    var deletedProviderEventID: String?
    private var continuation: AsyncStream<Void>.Continuation?

    init(status: EventKitAccessStatus) {
        authorizationStatus = status
        statusAfterRequest = status
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
