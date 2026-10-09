import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Inbox context cache integration")
struct InboxContextIntegrationTests {
    @Test("Marked mirrors never enter context; acknowledged accepted conflicts remain until a confirmed change")
    func cacheIntegration() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = StoredConnection(id: "connection", configurationID: "default", provider: "google", displayLabel: "Example account", isEnabled: true)
        let calendar = StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "calendar", displayLabel: "Example calendar", isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 20_000)
        let now = Date(timeIntervalSince1970: 500)
        func providerEvent(_ key: String, response: EventResponseState = .accepted, mirror: Bool = false, notes: String? = nil, updatedAt: Date? = nil, attendees: [EventParticipant] = []) -> ProviderEvent {
            ProviderEvent(provider: "google", connectionID: connection.id, calendarID: calendar.providerCalendarID,
                eventID: key, seriesID: nil, originalStart: nil, start: Date(timeIntervalSince1970: 10_000),
                end: Date(timeIntervalSince1970: 12_000), isAllDay: false, availability: .busy,
                isCancelled: false, isPrivate: false, title: "Example event", updatedAt: updatedAt,
                isManagedMirror: mirror, notes: notes, attendees: attendees, responseMetadata: EventResponse(state: response, evidence: .googleSelf))
        }
        func refresh(_ events: [ProviderEvent]) throws {
            try EventCache(repository: repository).apply(ProviderEventPage(events: events, nextSyncToken: nil, refreshMode: .full), connection: connection, calendar: calendar, from: start, through: end, now: now)
        }
        try refresh([providerEvent("a"), providerEvent("b"), providerEvent("mirror", mirror: true)])
        let snapshot = try repository.inboxContextSnapshot()
        #expect(snapshot.events.count == 2)
        let key = EventNormalizer.sourceKeyHash(provider: "google", connectionID: connection.id, calendarBindingID: calendar.id, eventID: "a")
        #expect(try repository.acknowledgeInboxRevision(sourceKeyHash: key, revision: 1))
        let acknowledged = try repository.inboxContextSnapshot()
        let preview = try InboxCalendarContextBuilder.build(snapshot: acknowledged, focusedKey: key, settings: repository.inboxContextSettings(), freshnessCutoff: Date(timeIntervalSince1970: 100))
        #expect(preview.attentionReasons == [.conflict])
        #expect(preview.focusedConflicts.count == 1)
        #expect(InboxConflictCalculator.conflictOnlyEvents(in: acknowledged, analysis: preview.analysis).count == 2)
        #expect(preview.choices.allSatisfy { $0.choices == [.hold] })
        // A provider re-read with unchanged meaningful content must not force
        // another decision just because the observed timestamp advanced.
        try EventCache(repository: repository).apply(ProviderEventPage(events: [providerEvent("a"), providerEvent("b")], nextSyncToken: nil, refreshMode: .full), connection: connection, calendar: calendar, from: start, through: end, now: now.addingTimeInterval(10))
        #expect(try InboxCalendarContextBuilder.revalidate(preview, against: repository.inboxContextSnapshot(), chosenKey: key, choice: .hold, freshnessCutoff: now).event.sourceKeyHash == key)
        try refresh([providerEvent("a", updatedAt: now.addingTimeInterval(20), attendees: [EventParticipant(name: "Example guest", status: "tentative")]), providerEvent("b")])
        #expect(try InboxCalendarContextBuilder.revalidate(preview, against: repository.inboxContextSnapshot(), chosenKey: key, choice: .hold, freshnessCutoff: now).event.sourceKeyHash == key)
        try refresh([providerEvent("a"), providerEvent("b", notes: "Edited while reviewing")])
        #expect(throws: InboxCalendarContextError.previewChanged) {
            try InboxCalendarContextBuilder.revalidate(preview, against: repository.inboxContextSnapshot(), chosenKey: key, choice: .hold, freshnessCutoff: now)
        }
        try refresh([providerEvent("a"), providerEvent("b", response: .declined)])
        let updated = try InboxCalendarContextBuilder.build(snapshot: repository.inboxContextSnapshot(), focusedKey: key, settings: repository.inboxContextSettings(), freshnessCutoff: now)
        #expect(updated.focusedConflicts.isEmpty)
        #expect(updated.attentionReasons.isEmpty)
        #expect(try repository.inboxObservation(sourceKeyHash: key)?.acknowledgedRevision == 1)
    }
}
