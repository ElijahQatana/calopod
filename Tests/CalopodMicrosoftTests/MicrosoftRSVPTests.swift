import CalopodDomain
import CalopodMicrosoft
import CalopodProviders
import Foundation
import Testing

@Suite("Microsoft invitation responses")
struct MicrosoftRSVPTests {
    private let authorization = RSVPAuthorization(identityScope: .authenticatedUser, canRespond: true)
    private let target = RSVPTarget(provider: "microsoft", connectionID: "connection", calendarBindingID: "binding",
                                    calendarID: "default-copy", eventID: "occurrence", seriesID: "series",
                                    originalStart: "2026-11-05T14:00:00Z")

    @Test(arguments: [RSVPDecision.yes, .no, .maybe])
    func dedicatedActionPreservesEvent(_ decision: RSVPDecision) async throws {
        let transport = MicrosoftRSVPTransport()
        let client = MicrosoftGraphClient(transport: transport)
        let snapshot = try await client.rsvpSnapshot(accessToken: "synthetic", target: target, authorization: authorization)
        #expect(snapshot.capability.supportedScopes == [.occurrence])
        #expect(snapshot.notification == .microsoftOrganizer)
        #expect(snapshot.concurrency == .preflightOnly)
        let intent = validIntent(decision)
        try await client.submitRSVP(accessToken: "synthetic", intent: intent, authorization: authorization)
        let result = try await client.reconcileRSVP(accessToken: "synthetic",
            record: RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .accepted)), authorization: authorization)
        #expect(result.confirmedResponse == decision.responseState)
        let requests = await transport.requests
        let write = try #require(requests.first { $0.httpMethod == "POST" })
        let action = decision == .yes ? "accept" : decision == .no ? "decline" : "tentativelyAccept"
        #expect(write.url?.path == "/v1.0/me/calendars/default-copy/events/occurrence/" + action)
        #expect(write.value(forHTTPHeaderField: "Prefer")?.contains("ImmutableId") == true)
        let bodyData = try #require(write.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Bool])
        #expect(body == ["sendResponse": true])
        let after = try await client.rsvpSnapshot(accessToken: "synthetic", target: target, authorization: authorization)
        #expect(after.event.title == snapshot.event.title)
        #expect(after.event.notes == snapshot.event.notes)
        #expect(after.event.start == snapshot.event.start)
        #expect(after.event.attendees == snapshot.event.attendees)
        #expect(requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func staleOrUnavailableActionsNeverSubmit() async throws {
        let transport = MicrosoftRSVPTransport()
        let client = MicrosoftGraphClient(transport: transport)
        let stale = RSVPActionIntent(target: target, expectedVersion: "old", previousResponse: .needsResponse, decision: .yes)
        await #expect(throws: RSVPActionError.stale) {
            try await client.submitRSVP(accessToken: "synthetic", intent: stale, authorization: authorization)
        }
        for proof in [RSVPAuthorization(identityScope: .unverified, canRespond: true),
                      RSVPAuthorization(identityScope: .authenticatedUser, canRespond: false)] {
            let snapshot = try await client.rsvpSnapshot(accessToken: "synthetic", target: target, authorization: proof)
            #expect(!snapshot.capability.isEligible)
            await #expect(throws: RSVPActionError.self) {
                try await client.submitRSVP(accessToken: "synthetic", intent: validIntent(.yes), authorization: proof)
            }
        }
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
        for extra in [#""type":"seriesMaster""#, #""type":null"#, #""isOrganizer":true"#,
                      #""isOrganizer":null"#, #""attendees":[]"#,
                      #""extensions":[{"extensionName":"com.calopod.managed"}]"#] {
            let transport = MicrosoftRSVPTransport(extra: extra)
            let client = MicrosoftGraphClient(transport: transport)
            #expect(try await !client.rsvpSnapshot(accessToken: "synthetic", target: target, authorization: authorization).capability.isEligible)
            await #expect(throws: RSVPActionError.self) {
                try await client.submitRSVP(accessToken: "synthetic", intent: validIntent(.no), authorization: authorization)
            }
            #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    @Test func rejectionUnknownAndDelayedReadbackStayExplicit() async throws {
        for (status, expected) in [(403, RSVPActionError.unavailable(.permission)), (400, .rejected), (500, .uncertain), (0, .uncertain)] {
            let transport = MicrosoftRSVPTransport(writeStatus: status)
            let client = MicrosoftGraphClient(transport: transport)
            await #expect(throws: expected) {
                try await client.submitRSVP(accessToken: "synthetic", intent: validIntent(.yes), authorization: authorization)
            }
            #expect(await transport.requests.filter { $0.httpMethod == "POST" }.count == 1)
        }
        let transport = MicrosoftRSVPTransport(delayed: true)
        let client = MicrosoftGraphClient(transport: transport)
        let intent = validIntent(.maybe)
        try await client.submitRSVP(accessToken: "synthetic", intent: intent, authorization: authorization)
        let record = RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .accepted))
        #expect(try await client.reconcileRSVP(accessToken: "synthetic", record: record, authorization: authorization).status == .unknown)
        await transport.finishResponse()
        #expect(try await client.reconcileRSVP(accessToken: "synthetic", record: record, authorization: authorization).confirmedResponse == .tentative)
        #expect(await transport.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func declineDisappearanceIsConfirmedOnlyAfterAcceptedRequest() async throws {
        let transport = MicrosoftRSVPTransport(disappear: true)
        let client = MicrosoftGraphClient(transport: transport)
        let intent = validIntent(.no)
        try await client.submitRSVP(accessToken: "synthetic", intent: intent, authorization: authorization)
        for received in [true, false] {
            let record = RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .unknown), submissionAccepted: received)
            let outcome = try await client.reconcileRSVP(accessToken: "synthetic", record: record, authorization: authorization)
            #expect(outcome.status == (received ? .confirmed : .unknown))
            #expect(outcome.disappearedAfterDecline == received)
        }
    }

    @Test func singleEventsDoNotEnableSeriesActions() async throws {
        let singleTarget = RSVPTarget(provider: target.provider, connectionID: target.connectionID,
            calendarBindingID: target.calendarBindingID, calendarID: target.calendarID, eventID: target.eventID)
        for (index, extra) in [#""type":"singleInstance""#, #""type":"seriesMaster""#].enumerated() {
            let client = MicrosoftGraphClient(transport: MicrosoftRSVPTransport(extra: #""seriesMasterId":null,"originalStart":null,"# + extra))
            let snapshot = try await client.rsvpSnapshot(accessToken: "synthetic", target: singleTarget, authorization: authorization)
            #expect(snapshot.capability.isEligible == (index == 0))
            #expect(!snapshot.capability.supportedScopes.contains(.series))
        }
    }

    private func validIntent(_ decision: RSVPDecision) -> RSVPActionIntent {
        RSVPActionIntent(target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: decision)
    }
}

private actor MicrosoftRSVPTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var event: [String: Any]
    let writeStatus: Int
    let disappear: Bool
    let delayed: Bool
    var pendingResponse: String?
    var didWrite = false

    init(extra: String = "", writeStatus: Int = 202, disappear: Bool = false, delayed: Bool = false) {
        let json = #"{"id":"occurrence","@odata.etag":"v1","type":"occurrence","seriesMasterId":"series","originalStart":"2026-11-05T14:00:00Z","start":{"dateTime":"2026-11-05T14:00:00","timeZone":"UTC"},"end":{"dateTime":"2026-11-05T15:00:00","timeZone":"UTC"},"subject":"Sample invitation","body":{"contentType":"text","content":"Sample notes"},"isOrganizer":false,"organizer":{"emailAddress":{"address":"organizer@example.com"}},"attendees":[{"emailAddress":{"address":"other@example.com"},"status":{"response":"accepted"}}],"responseStatus":{"response":"notResponded"}}"#
        var object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        if !extra.isEmpty {
            let overrides = try! JSONSerialization.jsonObject(with: Data(("{" + extra + "}").utf8)) as! [String: Any]
            object.merge(overrides) { _, new in new }
        }
        event = object
        self.writeStatus = writeStatus
        self.disappear = disappear
        self.delayed = delayed
    }

    func finishResponse() {
        if let pendingResponse {
            event["responseStatus"] = ["response": pendingResponse]
            event["@odata.etag"] = "v2"
        }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.httpMethod == "POST" {
            if writeStatus == 202 || writeStatus == 0 {
                switch request.url?.lastPathComponent {
                case "accept": pendingResponse = "accepted"
                case "decline": pendingResponse = "declined"
                default: pendingResponse = "tentativelyAccepted"
                }
                didWrite = true
                if !delayed { finishResponse() }
            }
            if writeStatus == 0 { throw URLError(.timedOut) }
            return HTTPResponse(statusCode: writeStatus, body: Data())
        }
        if disappear && didWrite { return HTTPResponse(statusCode: 404, body: Data()) }
        return HTTPResponse(statusCode: 200, body: try JSONSerialization.data(withJSONObject: event))
    }
}
