import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Recurring EventKit occurrences")
struct RecurringEventTests {
    @Test("Shared event IDs retain every bounded occurrence")
    func storesEveryOccurrence() throws {
        let fixture = try RecurringCacheFixture()
        let events = [60.0, 120.0, 180.0].map { fixture.event(at: $0) }
        try fixture.refresh(events)
        let instances = try fixture.instances()
        #expect(instances.count == 3)
        #expect(Set(instances.map(\.sourceKeyHash)).count == 3)
        #expect(instances.map(\.startsAt) == events.map { $0.start! })
        #expect(Set(instances.map(\.providerEventID)) == ["synthetic-series"])

        try fixture.refresh(Array(events.reversed()))
        #expect(try fixture.instances() == instances)
        #expect(EventNormalizer.normalize(
            events, connection: fixture.connection, calendar: fixture.calendar,
            from: Date(timeIntervalSince1970: 100), through: Date(timeIntervalSince1970: 150)
        ).instances.count == 1)
    }

    @Test("Moved and cancelled occurrences do not replace their siblings")
    func editsAndCancelsOneOccurrence() throws {
        let fixture = try RecurringCacheFixture()
        try fixture.refresh([60.0, 120.0, 180.0].map { fixture.event(at: $0) })
        let before = try fixture.instances()
        try #require(before.count == 3)
        try fixture.refresh([fixture.event(at: 120, movedTo: 140)], mode: .incremental)
        let moved = try fixture.instances()
        #expect(Set(moved.map(\.sourceKeyHash)) == Set(before.map(\.sourceKeyHash)))
        #expect(moved.map(\.startsAt) == [60.0, 140.0, 180.0].map(Date.init(timeIntervalSince1970:)))
        try fixture.refresh([fixture.event(at: 120, cancelled: true)], mode: .incremental)
        #expect(try fixture.instances().map(\.sourceKeyHash) == [before[0].sourceKeyHash, before[2].sourceKeyHash])
    }

    @Test(arguments: ["eventkit", "google", "microsoft"])
    func preservesUnrelatedIdentities(provider: String) throws {
        let fixture = try RecurringCacheFixture(provider: provider)
        let plain = fixture.event(at: 60, recurring: false)
        let recurring = fixture.event(at: 60)
        let normalize: (ProviderEvent) -> StoredNormalizedInstance = { event in
            EventNormalizer.normalize(
                [event], connection: fixture.connection, calendar: fixture.calendar,
                from: fixture.start, through: fixture.end
            ).instances[0]
        }
        #expect((normalize(plain).sourceKeyHash == normalize(recurring).sourceKeyHash) == (provider != "eventkit"))
    }
}

private struct RecurringCacheFixture {
    let repository: LocalStateRepository
    let connection: StoredConnection
    let calendar: StoredCalendarBinding
    let start = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 300)

    init(provider: String = "eventkit") throws {
        repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        connection = StoredConnection(id: "connection", configurationID: "default", provider: provider, displayLabel: "Synthetic", isEnabled: true)
        calendar = StoredCalendarBinding(id: "source", connectionID: "connection", providerCalendarID: "source", displayLabel: "Synthetic source", isSelected: true, isReadOnly: false)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
    }

    func event(at original: Double, movedTo: Double? = nil, cancelled: Bool = false, recurring: Bool = true) -> ProviderEvent {
        ProviderEvent(
            provider: connection.provider, connectionID: connection.id, calendarID: calendar.providerCalendarID,
            eventID: "synthetic-series", seriesID: recurring ? "synthetic-series" : nil,
            originalStart: recurring ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: original)) : nil,
            start: cancelled ? nil : Date(timeIntervalSince1970: movedTo ?? original),
            end: cancelled ? nil : Date(timeIntervalSince1970: (movedTo ?? original) + 30),
            isAllDay: false, availability: .busy, isCancelled: cancelled, isPrivate: false,
            title: "Synthetic recurring event", updatedAt: nil,
            notes: "Synthetic agenda", url: "https://example.com/meeting"
        )
    }

    func refresh(_ events: [ProviderEvent], mode: ProviderRefreshMode = .full) throws {
        try EventCache(repository: repository).apply(
            ProviderEventPage(events: events, nextSyncToken: nil, refreshMode: mode),
            connection: connection, calendar: calendar, from: start, through: end
        )
    }

    func instances() throws -> [StoredNormalizedInstance] {
        try repository.normalizedInstances(calendarBindingIDs: [calendar.id], from: start, through: end)
    }
}
