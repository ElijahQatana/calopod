import CalopodDomain
import CalopodGoogle
import CalopodProviders
import Foundation
import Testing

@Suite("Google invitation responses")
struct GoogleRSVPTests {
    private let authorization = RSVPAuthorization(identityScope: .authenticatedUser, canRespond: true)
    private let target = RSVPTarget(provider: "google", connectionID: "connection", calendarBindingID: "binding",
                                    calendarID: "primary-copy", eventID: "occurrence", seriesID: "series",
                                    originalStart: "2026-11-05T14:00:00Z")

    @Test(arguments: [RSVPDecision.yes, .no, .maybe])
    func responseUpdatesOnlySelf(_ decision: RSVPDecision) async throws {
        let transport = GoogleRSVPTransport()
        let client = GoogleCalendarClient(transport: transport)
        let snapshot = try await client.rsvpSnapshot(accessToken: "synthetic", target: target, authorization: authorization)
        #expect(snapshot.capability.supportedScopes == [.occurrence])
        #expect(snapshot.notification == .googleAllGuests)
        #expect(snapshot.concurrency == .conditionalUpdate)
        let intent = RSVPActionIntent(target: target, expectedVersion: try #require(snapshot.version),
                                      previousResponse: snapshot.event.currentUserResponse.state, decision: decision)
        try await client.submitRSVP(accessToken: "synthetic", intent: intent, authorization: authorization)
        let record = RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .accepted))
        let result = try await client.reconcileRSVP(accessToken: "synthetic", record: record, authorization: authorization)
        #expect(result.confirmedResponse == decision.responseState)
        let requests = await transport.requests
        let write = try #require(requests.first { $0.httpMethod == "PATCH" })
        #expect(write.url?.path == "/calendar/v3/calendars/primary-copy/events/occurrence")
        let writeURL = try #require(write.url)
        #expect(URLComponents(url: writeURL, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "sendUpdates", value: "all")])
        #expect(write.value(forHTTPHeaderField: "If-Match") == "v1")
        let bodyData = try #require(write.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(Set(body.keys) == ["attendees", "attendeesOmitted"])
        #expect(body["attendeesOmitted"] as? Bool == true)
        let attendees = try #require(body["attendees"] as? [[String: String]])
        #expect(attendees.count == 1)
        #expect(attendees[0]["email"] == "invitee@example.com")
        #expect(Set(attendees[0].keys) == ["email", "responseStatus"])
        let after = try await client.rsvpSnapshot(accessToken: "synthetic", target: target, authorization: authorization)
        #expect(after.event.title == snapshot.event.title)
        #expect(after.event.notes == snapshot.event.notes)
        #expect(after.event.start == snapshot.event.start)
        #expect(after.event.attendees[0] == snapshot.event.attendees[0])
        #expect(requests.filter { $0.httpMethod == "PATCH" }.count == 1)
    }

    @Test func staleRevisionAndConditionalRaceDoNotConfirm() async throws {
        let intent = RSVPActionIntent(target: target, expectedVersion: "old", previousResponse: .needsResponse, decision: .yes)
        let transport = GoogleRSVPTransport()
        let client = GoogleCalendarClient(transport: transport)
        await #expect(throws: RSVPActionError.stale) {
            try await client.submitRSVP(accessToken: "synthetic", intent: intent, authorization: authorization)
        }
        #expect(await transport.requests.count == 1)
        let race = GoogleCalendarClient(transport: GoogleRSVPTransport(writeStatus: 412))
        await #expect(throws: RSVPActionError.stale) {
            try await race.submitRSVP(accessToken: "synthetic", intent: validIntent(.yes), authorization: authorization)
        }
    }

    @Test func unavailableIdentityPermissionAndSeriesNeverWrite() async throws {
        for authorization in [RSVPAuthorization(identityScope: .unverified, canRespond: true),
                              RSVPAuthorization(identityScope: .authenticatedUser, canRespond: false)] {
            let transport = GoogleRSVPTransport()
            let client = GoogleCalendarClient(transport: transport)
            let snapshot = try await client.rsvpSnapshot(accessToken: "synthetic", target: target, authorization: authorization)
            #expect(!snapshot.capability.isEligible)
            await #expect(throws: RSVPActionError.self) {
                try await client.submitRSVP(accessToken: "synthetic", intent: validIntent(.yes), authorization: authorization)
            }
            #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
        }
        for extra in [#""recurrence":["RRULE:FREQ=DAILY"]"#,
                      #""organizer":{"self":true,"email":"organizer@example.com"}"#,
                      #""extendedProperties":{"private":{"calopodSchema":"1"}}"#,
                      #""attendees":[{"email":"other@example.com","responseStatus":"needsAction"}]"#] {
            let transport = GoogleRSVPTransport(extra: extra)
            let client = GoogleCalendarClient(transport: transport)
            let snapshot = try await client.rsvpSnapshot(accessToken: "synthetic", target: target, authorization: authorization)
            #expect(!snapshot.capability.isEligible)
            await #expect(throws: RSVPActionError.self) {
                try await client.submitRSVP(accessToken: "synthetic", intent: validIntent(.yes), authorization: authorization)
            }
            #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    @Test func rejectionAndUnknownCompletionRemainDistinct() async throws {
        for (status, expected) in [(403, RSVPActionError.unavailable(.permission)), (400, .rejected), (500, .uncertain), (0, .uncertain)] {
            let transport = GoogleRSVPTransport(writeStatus: status)
            let client = GoogleCalendarClient(transport: transport)
            await #expect(throws: expected) {
                try await client.submitRSVP(accessToken: "synthetic", intent: validIntent(.maybe), authorization: authorization)
            }
            #expect(await transport.requests.filter { $0.httpMethod == "PATCH" }.count == 1)
        }
        let transport = GoogleRSVPTransport(writeStatus: 0)
        let client = GoogleCalendarClient(transport: transport)
        let intent = validIntent(.yes)
        do { try await client.submitRSVP(accessToken: "synthetic", intent: intent, authorization: authorization) } catch { }
        let result = try await client.reconcileRSVP(accessToken: "synthetic",
            record: RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .unknown)), authorization: authorization)
        #expect(result.confirmedResponse == .accepted)
        #expect(await transport.requests.filter { $0.httpMethod == "PATCH" }.count == 1)
    }

    @Test func declineDisappearanceRequiresProviderReceipt() async throws {
        let transport = GoogleRSVPTransport(disappear: true)
        let client = GoogleCalendarClient(transport: transport)
        let intent = validIntent(.no)
        try await client.submitRSVP(accessToken: "synthetic", intent: intent, authorization: authorization)
        let confirmed = try await client.reconcileRSVP(accessToken: "synthetic",
            record: RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .unknown), submissionAccepted: true), authorization: authorization)
        #expect(confirmed.confirmedResponse == .declined)
        #expect(confirmed.disappearedAfterDecline)
        let unknown = try await client.reconcileRSVP(accessToken: "synthetic",
            record: RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .unknown)), authorization: authorization)
        #expect(unknown.status == .unknown)
    }

    @Test func singleEventsDoNotEnableSeriesActions() async throws {
        let singleTarget = RSVPTarget(provider: target.provider, connectionID: target.connectionID,
            calendarBindingID: target.calendarBindingID, calendarID: target.calendarID, eventID: target.eventID)
        for (index, extra) in ["", #""recurrence":["RRULE:FREQ=DAILY"]"#].enumerated() {
            let client = GoogleCalendarClient(transport: GoogleRSVPTransport(extra: #""recurringEventId":null,"originalStartTime":null"# + (extra.isEmpty ? "" : "," + extra)))
            let snapshot = try await client.rsvpSnapshot(accessToken: "synthetic", target: singleTarget, authorization: authorization)
            #expect(snapshot.capability.isEligible == (index == 0))
            #expect(!snapshot.capability.supportedScopes.contains(.series))
        }
    }

    private func validIntent(_ decision: RSVPDecision) -> RSVPActionIntent {
        RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: decision)
    }
}

private actor GoogleRSVPTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var event: [String: Any]
    let writeStatus: Int
    let disappear: Bool
    var didWrite = false

    init(extra: String = "", writeStatus: Int = 200, disappear: Bool = false) {
        let json = #"{"id":"occurrence","etag":"v1","recurringEventId":"series","originalStartTime":{"dateTime":"2026-11-05T14:00:00Z"},"start":{"dateTime":"2026-11-05T14:00:00Z"},"end":{"dateTime":"2026-11-05T15:00:00Z"},"summary":"Sample invitation","description":"Sample notes","organizer":{"email":"organizer@example.com"},"attendees":[{"email":"other@example.com","responseStatus":"accepted","optional":true},{"email":"invitee@example.com","self":true,"responseStatus":"needsAction"}]}"#
        var object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        if !extra.isEmpty {
            let overrides = try! JSONSerialization.jsonObject(with: Data(("{" + extra + "}").utf8)) as! [String: Any]
            object.merge(overrides) { _, new in new }
        }
        event = object
        self.writeStatus = writeStatus
        self.disappear = disappear
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.httpMethod == "PATCH" {
            if writeStatus == 200 || writeStatus == 0 {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let selfUpdate = (body["attendees"] as! [[String: Any]])[0]
                var attendees = event["attendees"] as! [[String: Any]]
                let index = attendees.firstIndex { $0["self"] as? Bool == true }!
                attendees[index]["responseStatus"] = selfUpdate["responseStatus"]
                event["attendees"] = attendees
                event["etag"] = "v2"
                didWrite = true
            }
            if writeStatus == 0 { throw URLError(.timedOut) }
            return HTTPResponse(statusCode: writeStatus, body: Data())
        }
        if disappear && didWrite { return HTTPResponse(statusCode: 404, body: Data()) }
        return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: event))
    }
}
