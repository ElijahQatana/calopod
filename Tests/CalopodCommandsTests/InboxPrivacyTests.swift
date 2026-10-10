@testable import CalopodCommands
import CalopodDomain
import CalopodProviders
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Test
func retainedInboxEvidenceStaysOutOfShareableDiagnostics() throws {
    let state = LocalStateRepository(database: try .inMemory())
    let connection = StoredConnection(id: "private-connection", configurationID: "default", provider: "google",
        displayLabel: "Private account", isEnabled: true)
    let calendar = StoredCalendarBinding(id: "private-binding", connectionID: connection.id,
        providerCalendarID: "private-calendar", displayLabel: "Private calendar", isSelected: true, isReadOnly: false)
    try state.saveConnection(connection)
    try state.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
    let start = Date(timeIntervalSince1970: 1000)
    let end = start.addingTimeInterval(3600)
    let event = ProviderEvent(provider: "google", connectionID: connection.id, calendarID: calendar.providerCalendarID,
        eventID: "private-event", seriesID: "private-series", originalStart: "2026-11-05T14:00:00Z",
        start: start, end: end, isAllDay: false, availability: .busy, isCancelled: false, isPrivate: false,
        title: "Private invitation", updatedAt: nil, notes: "Private notes", url: "https://example.com/private",
        organizer: EventParticipant(emailAddress: "organizer@example.com"),
        responseMetadata: EventResponse(state: .needsResponse, evidence: .googleSelf))
    try EventCache(repository: state).apply(ProviderEventPage(events: [event], nextSyncToken: "private-cursor"),
        connection: connection, calendar: calendar, from: start, through: end, now: start)
    let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lock")
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let session = try InboxReviewSessionController(state: state, lockURL: lockURL).start(
        metricsWindow: SyncWindow(start: start, end: end), freshnessCutoff: start, now: start)
    #expect(session.entries.count == 1)
    let retained = try #require(try state.inboxReviewSession(id: session.id))
    #expect(String(decoding: retained.snapshot, as: UTF8.self).contains("Private notes"))
    let target = RSVPTarget(provider: "google", connectionID: connection.id, calendarBindingID: calendar.id,
        calendarID: calendar.providerCalendarID, eventID: event.eventID, seriesID: event.seriesID, originalStart: event.originalStart)
    let intent = RSVPActionIntent(target: target, expectedVersion: "private-version", previousResponse: .needsResponse, decision: .yes)
    _ = try state.beginRSVPAction(intent)
    #expect(try state.rsvpAction(id: intent.id)?.intent == intent)
    try state.markConnectionStale(connectionID: connection.id, errorCode: "private-provider-error")
    let check = try providerHealthCheck(connections: [connection], repository: state)
    let counts = try supportConfigurationCounts(repository: state)
    let payload = CommandPayload(status: "failed", message: "Provider health needs attention.", items: [check],
        connectionCount: counts.connectionCount, selectedCalendarCount: counts.selectedCalendarCount)
    for command in ["doctor", "support.export", "agent.status"] {
        for format in [OutputFormat.human, .json] {
            let output = try OutputRenderer.render(command: command, payload: payload, format: format, showIDs: true)
            for privateField in ["private-", "Private", "example.com", intent.id, session.id,
                                 "responseMetadata", "expectedVersion", "snapshot", "syncToken"] {
                #expect(!output.contains(privateField))
            }
        }
    }
    #expect(check.reason == "provider")
    #expect(counts.connectionCount == 1)
    #expect(counts.selectedCalendarCount == 1)
}
