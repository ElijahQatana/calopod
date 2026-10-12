import CalopodDomain
@testable import CalopodEventKit
import CalopodGoogle
import CalopodMicrosoft
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Synthetic EventKit all-day boundaries")
struct AllDayBoundaryTests {
    @Test("Inclusive EventKit ends survive serialization and a second plan", arguments:
        ["2026-10-05", "2026-03-08", "2026-11-01"], [1, 3]
    )
    func exclusiveEnds(day: String, duration: Int) async throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = try #require(AllDayDate.midnight(of: day, in: zone))
        let end = try #require(calendar.date(byAdding: .day, value: duration, to: start))
        if duration == 1 {
            let hours = day == "2026-03-08" ? 23 : day == "2026-11-01" ? 25 : 24
            #expect(end.timeIntervalSince(start) == Double(hours * 3_600))
        }
        let connection = StoredConnection(
            id: "synthetic-connection", configurationID: "synthetic-configuration",
            provider: "eventkit", displayLabel: "Synthetic connection", isEnabled: true
        )
        let binding = StoredCalendarBinding(
            id: "synthetic-source", connectionID: connection.id, providerCalendarID: "synthetic-calendar",
            displayLabel: "Synthetic calendar", isSelected: true, isReadOnly: false
        )
        let readEnd = try #require(EventKitAllDayDates.exclusiveEnd(
            end.addingTimeInterval(-1), isAllDay: true, in: zone
        ))
        let event = ProviderEvent(
            provider: "eventkit", connectionID: connection.id, calendarID: binding.providerCalendarID,
            eventID: "synthetic-event", seriesID: nil, originalStart: nil, start: start, end: readEnd,
            isAllDay: true, availability: .busy, isCancelled: false, isPrivate: false,
            title: "Synthetic day", updatedAt: nil, timeZoneIdentifier: zone.identifier
        )
        let source = try #require(EventNormalizer.normalize(
            [event], connection: connection, calendar: binding, from: start, through: end
        ).instances.first)
        #expect(source.startsAt == start)
        #expect(source.endsAt == end)
        let window = try SyncWindow(start: start, end: end)
        let days = AllDayDate.days(startsAt: start, endsAt: end, timeZoneIdentifier: zone.identifier)
        #expect(days.start < days.end)

        for provider in ["eventkit", "google", "microsoft"] {
            let arm = StoredArm(
                id: "synthetic-arm", configurationID: connection.configurationID,
                sourceBindingIDs: [binding.id], targetBindingID: "synthetic-target", ruleMode: .busy
            )
            let first = SyncPlanner.plan(
                arm: arm, sources: [source], mappings: [], targetEvents: [],
                window: window, sourceSnapshotComplete: true
            )
            let item = try #require(first.items.first)
            #expect(first.items.map(\.action) == [.create])
            let payload = try #require(item.payload)
            let (writtenStart, writtenEnd) = EventKitManagedEventPresentation.dates(for: payload, in: zone)
            #expect(writtenStart == start)
            #expect(writtenEnd == end.addingTimeInterval(-1))
            #expect(EventKitAllDayDates.exclusiveEnd(writtenEnd, isAllDay: true, in: zone) == end)
            let request = ManagedEventWriteRequest(
                desiredFingerprint: SyncPlanner.desiredFingerprint(payload: payload, ruleMode: .busy),
                payload: payload,
                provenance: ManagedEventProvenance(
                    configurationID: connection.configurationID, armID: arm.id, mirrorKey: item.mirrorKey,
                    sourceKeyHash: source.sourceKeyHash, ruleMode: .busy,
                    ownershipKeyID: "synthetic-key", authenticationTag: "synthetic-tag"
                )
            )
            let transport = AllDayEchoTransport(provider: provider)
            let snapshots: [ManagedEventSnapshot]
            if provider == "eventkit" {
                snapshots = [ManagedEventSnapshot(
                    providerEventID: "synthetic-target-event", providerVersion: "v1",
                    payload: DesiredEventPayload(
                        startsAt: writtenStart,
                        endsAt: try #require(EventKitAllDayDates.exclusiveEnd(writtenEnd, isAllDay: true, in: zone)),
                        isAllDay: true, availability: payload.availability, title: payload.title,
                        isPrivate: nil, timeZoneIdentifier: zone.identifier
                    ), markerStatus: .parsed, provenance: request.provenance
                )]
            } else if provider == "google" {
                let client = GoogleCalendarClient(transport: transport)
                _ = try await client.createManagedEvent(accessToken: "synthetic", calendarID: "target", request: request)
                snapshots = try await client.managedEvents(
                    accessToken: "synthetic", calendarID: "target", from: start, through: end
                )
            } else {
                let client = MicrosoftGraphClient(transport: transport)
                _ = try await client.createManagedEvent(accessToken: "synthetic", calendarID: "target", request: request)
                snapshots = try await client.managedEvents(
                    accessToken: "synthetic", calendarID: "target", from: start, through: end
                )
            }
            if provider != "eventkit" {
                let body = try #require(await transport.writtenBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                if provider == "google" {
                    #expect(object["start"] as? [String: String] == ["date": days.start])
                    #expect(object["end"] as? [String: String] == ["date": days.end])
                } else {
                    #expect(object["start"] as? [String: String] == ["dateTime": "\(days.start)T00:00:00.0000000", "timeZone": "UTC"])
                    #expect(object["end"] as? [String: String] == ["dateTime": "\(days.end)T00:00:00.0000000", "timeZone": "UTC"])
                }
            }
            let read = try #require(snapshots.first)
            let readPayload = try #require(read.payload)
            #expect(readPayload.isAllDay)
            let fingerprint = SyncPlanner.desiredFingerprint(payload: readPayload, ruleMode: .busy)
            #expect(fingerprint == request.desiredFingerprint)
            let second = SyncPlanner.plan(
                arm: arm, sources: [source],
                mappings: [StoredMirrorMapping(
                    mirrorKey: item.mirrorKey, armID: arm.id, sourceKeyHash: source.sourceKeyHash,
                    providerEventID: "synthetic-target-event", providerVersion: "v1",
                    desiredFingerprint: request.desiredFingerprint, ownershipKeyID: "synthetic-key", updatedAt: start
                )],
                targetEvents: [TargetEventObservation(
                    calendarBindingID: arm.targetBindingID, providerEventID: "synthetic-target-event",
                    mirrorKey: item.mirrorKey, contentFingerprint: fingerprint, ownershipStatus: .verified
                )], window: window, sourceSnapshotComplete: true
            )
            #expect(second.items.map(\.action) == [.noOp])
        }
    }

    @Test("Last-second ends normalize once without shortening the span", arguments: [1, 3])
    func lastSecondEnd(duration: Int) throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = try #require(AllDayDate.midnight(of: "2026-10-05", in: zone))
        let exclusiveEnd = try #require(calendar.date(byAdding: .day, value: duration, to: start))
        let expected = AllDayDate.days(startsAt: start, endsAt: exclusiveEnd, timeZoneIdentifier: zone.identifier)
        let normalized = try #require(EventKitAllDayDates.exclusiveEnd(
            exclusiveEnd.addingTimeInterval(-1), isAllDay: true, in: zone
        ))
        let actual = AllDayDate.days(startsAt: start, endsAt: normalized, timeZoneIdentifier: zone.identifier)
        #expect(actual.start == expected.start)
        #expect(actual.end == expected.end)
        #expect(EventKitAllDayDates.exclusiveEnd(normalized, isAllDay: true, in: zone) == normalized)
        #expect(EventKitAllDayDates.exclusiveEnd(exclusiveEnd.addingTimeInterval(-1), isAllDay: false, in: zone)
            == exclusiveEnd.addingTimeInterval(-1))
        #expect(EventKitAllDayDates.exclusiveEnd(nil, isAllDay: true, in: zone) == nil)
    }
}

private actor AllDayEchoTransport: HTTPTransport {
    let provider: String
    var writtenBody: Data?

    init(provider: String) { self.provider = provider }

    func send(_ request: URLRequest) throws -> HTTPResponse {
        if request.httpMethod == "POST" {
            writtenBody = request.httpBody
            return HTTPResponse(statusCode: 200, body: Data(
                #"{"id":"synthetic-target-event","etag":"v1","changeKey":"v1"}"#.utf8
            ))
        }
        #expect(request.httpMethod == "GET")
        let body = try #require(writtenBody)
        var event = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        event["id"] = "synthetic-target-event"
        let page: [String: Any] = provider == "google"
            ? ["timeZone": "UTC", "items": [event]] : ["value": [event]]
        return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: page))
    }
}
