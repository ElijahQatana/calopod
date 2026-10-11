import CalopodDomain
import CalopodGoogle
import CalopodProviders
import CalopodStore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite("Google OAuth")
struct GoogleOAuthTests {
    @Test("Authorization uses PKCE and calendar write scope")
    func authorizationRequest() async throws {
        let transport = RecordingTransport { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("code_verifier="))
            #expect(body.contains("grant_type=authorization_code"))
            return HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8)
            )
        }
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "client-id"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let browser = StubBrowserSession { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            #expect(values["client_id"] == "client-id")
            #expect(values["code_challenge_method"] == "S256")
            #expect(values["state"] == "fixed-state")
            #expect(values["scope"]?.contains("calendar.calendarlist.readonly") == true)
            #expect(values["scope"]?.contains("calendar.events") == true)
            #expect(values["scope"]?.contains("calendar.events.readonly") == false)
        }

        let tokens = try await client.authorize(using: browser)

        #expect(tokens.accessToken == "access")
        #expect(tokens.refreshToken == "refresh")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 3700))
    }

    @Test("Refresh preserves the original refresh token")
    func refresh() async throws {
        let transport = RecordingTransport { _ in
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"new-access","expires_in":1800,"token_type":"Bearer"}"#.utf8)
            )
        }
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "client-id"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let old = OAuthTokens(
            accessToken: "old-access",
            refreshToken: "keep-me",
            tokenType: "Bearer",
            scope: "scope",
            expiresAt: .distantPast
        )

        let refreshed = try await client.refresh(old)

        #expect(refreshed.accessToken == "new-access")
        #expect(refreshed.refreshToken == "keep-me")
        #expect(refreshed.expiresAt == Date(timeIntervalSince1970: 2_800))
    }

    @Test("Expired refresh credentials require reconnection")
    func expiredRefreshCredentials() async throws {
        let client = GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "client-id"),
            transport: RecordingTransport { _ in
                HTTPResponse(statusCode: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
        )
        let expired = OAuthTokens(
            accessToken: "expired-access",
            refreshToken: "expired-refresh",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: .distantPast
        )

        await #expect(throws: ProviderFailure.refreshRejected) {
            try await client.refresh(expired)
        }
    }
}

@Suite("Google Calendar API")
struct GoogleCalendarClientTests {
    @Test("Calendar listing follows pagination")
    func calendarPagination() async throws {
        let transport = RecordingTransport { request in
            if request.url?.query?.contains("pageToken=next") == true {
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"items":[{"id":"second","summary":"Shared","accessRole":"reader"}]}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: 200,
                body: Data(#"{"items":[{"id":"first","summary":"Main","accessRole":"owner","primary":true}],"nextPageToken":"next"}"#.utf8)
            )
        }
        let client = GoogleCalendarClient(transport: transport)

        let calendars = try await client.calendars(accessToken: "token")

        #expect(calendars.map(\.id) == ["first", "second"])
        #expect(calendars[0].primary)
        #expect(calendars[1].accessRole == "reader")
    }

    @Test("Event reads are bounded and normalize recurring and cancelled instances")
    func boundedEvents() async throws {
        let transport = RecordingTransport { request in
            let query = request.url?.query ?? ""
            #expect(query.contains("timeMin="))
            #expect(query.contains("timeMax="))
            #expect(query.contains("singleEvents=true"))
            #expect(query.contains("showDeleted=true"))
            #expect(query.contains("updatedMin="))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            return HTTPResponse(
                statusCode: 200,
                body: Data(
                    #"{"timeZone":"America/New_York","items":[{"id":"instance","recurringEventId":"series","originalStartTime":{"dateTime":"2026-03-08T09:00:00-04:00"},"start":{"dateTime":"2026-03-08T09:00:00-04:00"},"end":{"dateTime":"2026-03-08T10:00:00-04:00"},"status":"confirmed","visibility":"private","summary":"Synthetic meeting","description":"Synthetic agenda","location":"Synthetic room","hangoutLink":"https://meet.example.test/synthetic","organizer":{"email":"organizer@example.com","displayName":"Synthetic Organizer"},"attendees":[{"email":"guest@example.com","displayName":"Synthetic Guest","responseStatus":"accepted"}],"updated":"2026-03-01T12:00:00Z"},{"id":"all-day","start":{"date":"2026-03-09"},"end":{"date":"2026-03-10"},"transparency":"transparent"},{"id":"managed","start":{"dateTime":"2026-03-09T09:00:00-04:00"},"end":{"dateTime":"2026-03-09T10:00:00-04:00"},"extendedProperties":{"private":{"calopodSchema":"1"}}},{"id":"cancelled","recurringEventId":"series","originalStartTime":{"dateTime":"2026-03-10T09:00:00-04:00"},"status":"cancelled"}],"nextSyncToken":"stored-only"}"#.utf8
                )
            )
        }
        let client = GoogleCalendarClient(transport: transport)
        let start = Date(timeIntervalSince1970: 1_772_928_000)
        let end = start.addingTimeInterval(604_800)

        let page = try await client.events(
            accessToken: "token",
            connectionID: "connection",
            calendarID: "calendar/id",
            from: start,
            through: end,
            updatedSince: start.addingTimeInterval(-3600)
        )

        #expect(page.events.count == 4)
        #expect(page.events[0].seriesID == "series")
        #expect(page.events[0].originalStart == "2026-03-08T09:00:00-04:00")
        #expect(page.events[0].isPrivate)
        #expect(page.events[0].location == "Synthetic room")
        #expect(page.events[0].notes == "Synthetic agenda")
        #expect(page.events[0].url == "https://meet.example.test/synthetic")
        #expect(page.events[0].organizer?.emailAddress == "organizer@example.com")
        #expect(page.events[0].attendees.first?.status == "accepted")
        #expect(page.events[1].isAllDay)
        #expect(page.events[1].availability == .free)
        #expect(page.events[2].isManagedMirror)
        #expect(page.events[3].isCancelled)
        #expect(page.events[3].start == nil)
        #expect(page.nextSyncToken == "stored-only")
    }

    @Test("Expired cursors are actionable")
    func expiredCursor() async throws {
        let client = GoogleCalendarClient(
            transport: RecordingTransport { _ in HTTPResponse(statusCode: 410, body: Data()) }
        )

        await #expect(throws: ProviderFailure.cursorExpired) {
            try await client.events(
                accessToken: "token",
                connectionID: "connection",
                calendarID: "calendar",
                from: Date(timeIntervalSince1970: 0),
                through: Date(timeIntervalSince1970: 100)
            )
        }
    }

    @Test("Throttling preserves the provider retry delay")
    func throttling() async throws {
        let client = GoogleCalendarClient(
            transport: RecordingTransport { _ in
                HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: Data())
            }
        )

        await #expect(throws: ProviderFailure.temporaryFailure(retryAfterSeconds: 120)) {
            try await client.calendars(accessToken: "token")
        }
    }
}

@Suite("Google connection state")
struct GoogleConnectionServiceTests {
    @Test("A saved watermark is reused after reopening local state")
    func incrementalRefreshAfterRestart() async throws {
        let database = try CalopodDatabase.inMemory()
        let state = LocalStateRepository(database: database)
        let connection = StoredConnection(
            id: "connection",
            configurationID: "default",
            provider: "google",
            displayLabel: "Google Calendar",
            isEnabled: true
        )
        let binding = StoredCalendarBinding(
            id: "binding",
            connectionID: connection.id,
            providerCalendarID: "calendar",
            displayLabel: "Synthetic calendar",
            isSelected: true,
            isReadOnly: false
        )
        try state.saveConnection(connection)
        try state.replaceCalendarBindings(connectionID: connection.id, bindings: [binding])

        let secrets = MemorySecretStore()
        let vault = OAuthTokenVault(secretStore: secrets)
        try vault.save(
            OAuthTokens(
                accessToken: "access",
                refreshToken: "refresh",
                tokenType: "Bearer",
                scope: nil,
                expiresAt: .distantFuture
            ),
            provider: "google",
            connectionID: connection.id
        )
        let transport = EventRecordingTransport()
        let firstService = service(
            state: state,
            vault: vault,
            transport: transport,
            now: Date(timeIntervalSince1970: 10_000)
        )
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(86_400)

        let firstPage = try await firstService.events(
            connectionID: connection.id,
            binding: binding,
            from: start,
            through: end
        )
        try saveCursorUpdates(
            firstPage,
            repository: state,
            connectionID: connection.id,
            calendarBindingID: binding.id
        )
        let reopenedService = service(
            state: LocalStateRepository(database: database),
            vault: vault,
            transport: transport,
            now: Date(timeIntervalSince1970: 20_000)
        )
        _ = try await reopenedService.events(
            connectionID: connection.id,
            binding: binding,
            from: start,
            through: end
        )

        let queries = await transport.queries
        #expect(queries.count == 2)
        #expect(!queries[0].contains("updatedMin="))
        #expect(queries[1].contains("updatedMin="))
    }

    @Test("Calendar state, watermarks, tokens, and disconnect survive repository boundaries")
    func lifecycle() async throws {
        let database = try CalopodDatabase.inMemory()
        let state = LocalStateRepository(database: database)
        let secrets = MemorySecretStore()
        let vault = OAuthTokenVault(secretStore: secrets)
        let fixedNow = Date(timeIntervalSince1970: 2_000)
        let tokenTransport = RecordingTransport { _ in
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#.utf8)
            )
        }
        let apiTransport = RecordingTransport { request in
            if request.url?.path.hasSuffix("calendarList") == true {
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"items":[{"id":"calendar","summary":"Work","accessRole":"owner","primary":true}]}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: 200,
                body: Data(#"{"items":[],"nextSyncToken":"durable-token"}"#.utf8)
            )
        }
        let service = GoogleConnectionService(
            oauth: GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "client-id"),
                transport: tokenTransport,
                now: { fixedNow }
            ),
            calendarClient: GoogleCalendarClient(transport: apiTransport),
            tokenVault: vault,
            state: state,
            now: { fixedNow }
        )

        let connection = try await service.authorize(using: StubBrowserSession { _ in })
        let bindings = try await service.refreshCalendars(connectionID: connection.id)
        #expect(bindings.first?.responseIdentityScope == .authenticatedUser)
        let page = try await service.events(
            connectionID: connection.id,
            binding: bindings[0],
            from: fixedNow,
            through: fixedNow.addingTimeInterval(86_400)
        )
        try saveCursorUpdates(
            page,
            repository: state,
            connectionID: connection.id,
            calendarBindingID: bindings[0].id
        )

        let reopenedState = LocalStateRepository(database: database)
        #expect(try reopenedState.connections(provider: "google") == [connection])
        #expect(try reopenedState.calendarBindings(connectionID: connection.id) == bindings)
        let cursorValues = try reopenedState.cursorValues(
            connectionID: connection.id,
            calendarBindingID: bindings[0].id
        )
        #expect(cursorValues.values.contains("durable-token"))
        #expect(try vault.tokens(provider: "google", connectionID: connection.id) != nil)

        try service.disconnect(connectionID: connection.id)

        #expect(try reopenedState.connections(provider: "google").isEmpty)
        #expect(try vault.tokens(provider: "google", connectionID: connection.id) == nil)
    }

    private func service(
        state: LocalStateRepository,
        vault: OAuthTokenVault,
        transport: any HTTPTransport,
        now: Date
    ) -> GoogleConnectionService {
        GoogleConnectionService(
            oauth: GoogleOAuthClient(
                configuration: GoogleOAuthConfiguration(clientID: "client-id"),
                transport: transport,
                now: { now }
            ),
            calendarClient: GoogleCalendarClient(transport: transport),
            tokenVault: vault,
            state: state,
            now: { now }
        )
    }
}

@Suite("Google managed writes")
struct GoogleManagedWriteTests {
    @Test("Create uses deterministic identity, redacted fields, and private provenance")
    func create() async throws {
        let managed = googleManagedRequest()
        let client = GoogleCalendarClient(
            transport: RecordingTransport { request in
                #expect(request.httpMethod == "POST")
                #expect(request.url?.path.contains("/calendars/target/events") == true)
                let object = try #require(
                    JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                )
                let identifier = try #require(object["id"] as? String)
                #expect(identifier.count == 52)
                #expect(identifier.allSatisfy { $0.isNumber || ("a" ... "v").contains(String($0)) })
                #expect(object["summary"] as? String == "Busy")
                #expect(object["description"] == nil)
                #expect(object["location"] == nil)
                #expect(object["attendees"] == nil)
                let reminders = try #require(object["reminders"] as? [String: Bool])
                #expect(reminders["useDefault"] == false)
                let properties = try #require(object["extendedProperties"] as? [String: Any])
                let marker = try #require(properties["private"] as? [String: String])
                #expect(marker["mirrorKey"] == managed.provenance.mirrorKey)
                #expect(marker["desiredFingerprint"] == managed.desiredFingerprint)
                let body = try JSONSerialization.data(
                    withJSONObject: ["id": identifier, "etag": "synthetic-etag"]
                )
                return HTTPResponse(statusCode: 200, body: body)
            }
        )

        let result = try await client.createManagedEvent(
            accessToken: "token",
            calendarID: "target",
            request: managed
        )

        #expect(result.providerVersion == "synthetic-etag")
    }

    @Test("Full details writes location and notes without creating invitees")
    func fullDetails() async throws {
        let client = GoogleCalendarClient(
            transport: RecordingTransport { request in
                let object = try #require(
                    JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                )
                #expect(object["summary"] as? String == "Synthetic planning session")
                #expect(object["location"] as? String == "Synthetic room")
                #expect(object["description"] as? String == "Synthetic agenda and participant context")
                #expect(object["attendees"] == nil)
                #expect(object["conferenceData"] == nil)
                let reminders = try #require(object["reminders"] as? [String: Bool])
                #expect(reminders["useDefault"] == false)
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"id":"provider-event","etag":"synthetic-etag"}"#.utf8)
                )
            }
        )

        _ = try await client.createManagedEvent(
            accessToken: "token",
            calendarID: "target",
            request: googleFullDetailsRequest()
        )
    }

    @Test("Update and delete carry provider version preconditions")
    func updateAndDelete() async throws {
        let client = GoogleCalendarClient(
            transport: RecordingTransport { request in
                #expect(request.value(forHTTPHeaderField: "If-Match") == "synthetic-etag")
                if request.httpMethod == "DELETE" {
                    return HTTPResponse(statusCode: 204, body: Data())
                }
                #expect(request.httpMethod == "PUT")
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"id":"provider-event","etag":"next-etag"}"#.utf8)
                )
            }
        )

        let updated = try await client.updateManagedEvent(
            accessToken: "token",
            calendarID: "target",
            providerEventID: "provider-event",
            expectedVersion: "synthetic-etag",
            request: googleManagedRequest()
        )
        try await client.deleteManagedEvent(
            accessToken: "token",
            calendarID: "target",
            providerEventID: "provider-event",
            expectedVersion: "synthetic-etag"
        )

        #expect(updated.providerVersion == "next-etag")
    }

    @Test("A concurrent deterministic create adopts the existing owned event")
    func concurrentCreate() async throws {
        let managed = googleManagedRequest()
        let client = GoogleCalendarClient(
            transport: RecordingTransport { request in
                if request.httpMethod == "POST" {
                    return HTTPResponse(statusCode: 409, body: Data())
                }
                let eventID = try #require(request.url?.lastPathComponent)
                let object: [String: Any] = [
                    "id": eventID,
                    "etag": "existing-etag",
                    "extendedProperties": [
                        "private": [
                            "calopodSchema": "1",
                            "configurationID": managed.provenance.configurationID,
                            "armID": managed.provenance.armID,
                            "mirrorKey": managed.provenance.mirrorKey,
                            "sourceKeyHash": managed.provenance.sourceKeyHash,
                            "ruleMode": managed.provenance.ruleMode.rawValue,
                            "ownershipKeyID": managed.provenance.ownershipKeyID,
                            "authenticationTag": managed.provenance.authenticationTag,
                        ],
                    ],
                ]
                return HTTPResponse(
                    statusCode: 200,
                    body: try JSONSerialization.data(withJSONObject: object)
                )
            }
        )

        let result = try await client.createManagedEvent(
            accessToken: "token",
            calendarID: "target",
            request: managed
        )

        #expect(result.providerEventID.count == 52)
        #expect(result.providerVersion == "existing-etag")
    }

    @Test("Managed target reads return actual payload, version, and provenance")
    func managedRead() async throws {
        let client = GoogleCalendarClient(
            transport: RecordingTransport { request in
                let query = request.url?.query ?? ""
                #expect(query.contains("timeMin="))
                #expect(query.contains("timeMax="))
                #expect(query.contains("singleEvents=true"))
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(
                        #"{"timeZone":"UTC","items":[{"id":"provider-event","etag":"v2","start":{"dateTime":"2026-09-25T12:30:00Z"},"end":{"dateTime":"2026-09-25T13:00:00Z"},"summary":"Busy","transparency":"opaque","extendedProperties":{"private":{"calopodSchema":"1","configurationID":"synthetic-configuration","armID":"synthetic-arm","mirrorKey":"synthetic-mirror","sourceKeyHash":"synthetic-source","ruleMode":"busy","ownershipKeyID":"synthetic-key","authenticationTag":"synthetic-tag"}}}]}"#.utf8
                    )
                )
            }
        )

        let snapshots = try await client.managedEvents(
            accessToken: "token",
            calendarID: "target",
            from: Date(timeIntervalSince1970: 1_000),
            through: Date(timeIntervalSince1970: 5_000)
        )
        let snapshot = try #require(snapshots.first)

        #expect(snapshot.providerEventID == "provider-event")
        #expect(snapshot.providerVersion == "v2")
        #expect(snapshot.payload?.title == "Busy")
        #expect(snapshot.payload?.isPrivate == nil)
        #expect(snapshot.markerStatus == .parsed)
        #expect(snapshot.provenance?.mirrorKey == "synthetic-mirror")
    }
}

private func googleManagedRequest() -> ManagedEventWriteRequest {
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
            mirrorKey: String(repeating: "a", count: 52),
            sourceKeyHash: "synthetic-source",
            ruleMode: .busy,
            ownershipKeyID: "synthetic-key",
            authenticationTag: "synthetic-tag"
        )
    )
}

private func googleFullDetailsRequest() -> ManagedEventWriteRequest {
    ManagedEventWriteRequest(
        desiredFingerprint: "synthetic-full-fingerprint",
        payload: DesiredEventPayload(
            startsAt: Date(timeIntervalSince1970: 2_000),
            endsAt: Date(timeIntervalSince1970: 3_000),
            isAllDay: false,
            availability: "busy",
            title: "Synthetic planning session",
            isPrivate: false,
            location: "Synthetic room",
            notes: "Synthetic agenda and participant context"
        ),
        provenance: ManagedEventProvenance(
            configurationID: "synthetic-configuration",
            armID: "synthetic-arm",
            mirrorKey: String(repeating: "b", count: 52),
            sourceKeyHash: "synthetic-source",
            ruleMode: .fullDetails,
            ownershipKeyID: "synthetic-key",
            authenticationTag: "synthetic-tag"
        )
    )
}

private func saveCursorUpdates(
    _ page: ProviderEventPage,
    repository: LocalStateRepository,
    connectionID: String,
    calendarBindingID: String
) throws {
    for cursor in page.cursorUpdates {
        try repository.saveCursor(
            connectionID: connectionID,
            calendarBindingID: calendarBindingID,
            scopeKey: cursor.scopeKey,
            value: cursor.value,
            scopeStart: cursor.scopeStart,
            scopeEnd: cursor.scopeEnd
        )
    }
}

private struct StubBrowserSession: BrowserAuthorizationSession {
    let inspectURL: @Sendable (URL) -> Void

    init(inspectURL: @escaping @Sendable (URL) -> Void) {
        self.inspectURL = inspectURL
    }

    func authorize(
        makeURL: @escaping @Sendable (BrowserAuthorizationContext) throws -> URL
    ) async throws -> BrowserAuthorizationResult {
        let redirect = URL(string: "http://127.0.0.1:49152/oauth/callback")!
        let url = try makeURL(BrowserAuthorizationContext(redirectURI: redirect, state: "fixed-state"))
        inspectURL(url)
        return BrowserAuthorizationResult(code: "authorization-code", redirectURI: redirect)
    }
}

private actor RecordingTransport: HTTPTransport {
    private let response: @Sendable (URLRequest) async throws -> HTTPResponse

    init(response: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await response(request)
    }
}

private actor EventRecordingTransport: HTTPTransport {
    private(set) var queries: [String] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        queries.append(request.url?.query ?? "")
        return HTTPResponse(statusCode: 200, body: Data(#"{"items":[]}"#.utf8))
    }
}

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretReference: Data] = [:]

    func save(_ value: Data, for reference: SecretReference) throws {
        lock.withLock { values[reference] = value }
    }

    func value(for reference: SecretReference) throws -> Data? {
        lock.withLock { values[reference] }
    }

    func removeValue(for reference: SecretReference) throws {
        lock.withLock { _ = values.removeValue(forKey: reference) }
    }
}


@Suite("Google current user response")
struct GoogleResponseTests {
    @Test(arguments: ["needsAction", "accepted", "tentative", "declined", "unexpected", ""])
    func responseStates(_ status: String) async throws {
        let metadata = "\"attendees\":[{\"self\":false,\"responseStatus\":\"declined\"},{\"self\":true,\"responseStatus\":\"\(status)\"}]"
        let event = try await read(metadata, scope: .authenticatedUser)
        let expected: [String: EventResponseState] = [
            "needsAction": .needsResponse, "accepted": .accepted,
            "tentative": .tentative, "declined": .declined,
        ]
        #expect(event.currentUserResponse.state == (expected[status] ?? .unknown))
        #expect(event.currentUserResponse.respondedAt == nil)
        #expect(event.currentUserResponse.evidence == .googleSelf)
        #expect(!event.currentUserResponse.actionCapability.isEligible)
        #expect(event.currentUserResponse.actionCapability.supportedScopes.isEmpty)
    }

    @Test
    func absentAndAmbiguousIdentity() async throws {
        for metadata in ["\"attendees\":[]", "\"attendees\":[{\"responseStatus\":\"needsAction\"}]",
                         "\"attendees\":[{\"self\":true},{\"self\":true}]"] {
            let event = try await read(metadata, scope: .authenticatedUser)
            #expect(event.currentUserResponse.state == .unknown)
        }
        let missing = try await read("\"attendeesOmitted\":true", scope: .authenticatedUser)
        #expect(missing.currentUserResponse.state == .unknown)
        let organizer = try await read("\"organizer\":{\"self\":true}", scope: .authenticatedUser)
        #expect(organizer.currentUserResponse.state == .organizer)
        let attendeeOrganizer = try await read("\"attendees\":[{\"self\":true,\"organizer\":true}]", scope: .authenticatedUser)
        #expect(attendeeOrganizer.currentUserResponse.state == .organizer)
        let omitted = try await read("\"attendeesOmitted\":true,\"attendees\":[{\"self\":true,\"responseStatus\":\"accepted\"}]", scope: .authenticatedUser)
        #expect(omitted.currentUserResponse.state == .accepted)
        #expect(omitted.currentUserResponse.limits.contains(.incompleteParticipants))
    }

    @Test
    func sharedAndDelegatedCopiesDoNotRepresentOperator() async throws {
        for metadata in ["\"organizer\":{\"self\":true}",
                         "\"attendees\":[{\"self\":true,\"responseStatus\":\"needsAction\"}]"] {
            let event = try await read(metadata, scope: .unverified)
            #expect(event.currentUserResponse.state == .unknown)
            #expect(event.currentUserResponse.limits.contains(.identityUnverified))
        }
    }

    private func read(_ metadata: String, scope: ResponseIdentityScope) async throws -> ProviderEvent {
        let json = "{\"items\":[{\"id\":\"synthetic\",\"start\":{\"dateTime\":\"2026-11-05T14:00:00Z\"},\"end\":{\"dateTime\":\"2026-11-05T15:00:00Z\"},\(metadata)}]}"
        let client = GoogleCalendarClient(transport: RecordingTransport { request in
            #expect(request.httpMethod == "GET")
            return HTTPResponse(statusCode: 200, body: Data(json.utf8))
        })
        let page = try await client.events(accessToken: "synthetic", connectionID: "google-test",
                                           calendarID: "synthetic-calendar", from: Date(), through: Date(),
                                           responseIdentityScope: scope)
        return try #require(page.events.first)
    }
}


@Test
func googleResponseScopeDiscoverySurvivesRepositoryReads() async throws {
    let database = try CalopodDatabase.inMemory()
    let state = LocalStateRepository(database: database)
    let connection = StoredConnection(id: "response-connection", configurationID: "default",
                                      provider: "google", displayLabel: "Synthetic", isEnabled: true)
    try state.saveConnection(connection)
    let vault = OAuthTokenVault(secretStore: MemorySecretStore())
    try vault.save(OAuthTokens(accessToken: "synthetic", refreshToken: "synthetic",
                               tokenType: "Bearer", scope: nil, expiresAt: .distantFuture),
                   provider: "google", connectionID: connection.id)
    let transport = RecordingTransport { request in
        #expect(request.httpMethod == "GET")
        let path = request.url?.path ?? ""
        if path.hasSuffix("calendarList") {
            return HTTPResponse(statusCode: 200, body: Data(#"{"items":[{"id":"primary-copy","primary":true,"accessRole":"owner"},{"id":"shared-copy","accessRole":"owner"},{"id":"secondary-copy","accessRole":"writer"}]}"#.utf8))
        }
        return HTTPResponse(statusCode: 200, body: Data(#"{"items":[{"id":"event","attendees":[{"self":true,"responseStatus":"needsAction"}]}]}"#.utf8))
    }
    let service = GoogleConnectionService(
        oauth: GoogleOAuthClient(configuration: GoogleOAuthConfiguration(clientID: "synthetic")),
        calendarClient: GoogleCalendarClient(transport: transport), tokenVault: vault, state: state)
    _ = try await service.refreshCalendars(connectionID: connection.id)
    let reopened = LocalStateRepository(database: database)
    let bindings = try reopened.calendarBindings(connectionID: connection.id)
    #expect(bindings.count == 3)
    for binding in bindings {
        let isOperator = binding.providerCalendarID == "primary-copy"
        #expect(binding.responseIdentityScope == (isOperator ? .authenticatedUser : .unverified))
        #expect(try reopened.calendarBinding(id: binding.id)?.responseIdentityScope == binding.responseIdentityScope)
        let page = try await service.events(connectionID: connection.id, binding: binding,
                                            from: Date(timeIntervalSince1970: 1_000),
                                            through: Date(timeIntervalSince1970: 5_000))
        #expect(page.events.first?.currentUserResponse.state == (isOperator ? .needsResponse : .unknown))
    }
}

@Test
func googleRSVPRequiresCurrentPermissionAndOperatorScope() async throws {
    for scenario in 0..<6 {
        let state = LocalStateRepository(database: try .inMemory())
        try state.saveConnection(StoredConnection(id: "connection", configurationID: "default",
            provider: "google", displayLabel: "Synthetic", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "connection", bindings: [StoredCalendarBinding(
            id: "binding", connectionID: "connection", providerCalendarID: "primary-copy", displayLabel: "Synthetic",
            isSelected: true, isReadOnly: false,
            responseIdentityScope: scenario == 1 ? .unverified : .authenticatedUser)])
        let vault = OAuthTokenVault(secretStore: MemorySecretStore())
        try vault.save(OAuthTokens(accessToken: "synthetic", refreshToken: "synthetic", tokenType: "Bearer",
            scope: scenario == 0 ? nil : "https://www.googleapis.com/auth/calendar.events", expiresAt: .distantFuture),
            provider: "google", connectionID: "connection")
        let transport = RecordingTransport { request in
            if request.httpMethod == "PATCH" {
                #expect(try state.rsvpAction(id: "decision")?.outcome.status == .pending)
                return HTTPResponse(statusCode: 200, body: Data())
            }
            #expect(request.httpMethod == "GET")
            if request.url?.lastPathComponent != "calendarList" {
                let accepted = try state.rsvpAction(id: "decision")?.submissionAccepted == true
                let event = #"{"id":"invitation","etag":"v1","organizer":{"email":"organizer@example.com"},"attendees":[{"self":true,"email":"invitee@example.com","responseStatus":"needsAction"}]}"#.replacingOccurrences(of: "needsAction", with: accepted ? "accepted" : "needsAction")
                return HTTPResponse(statusCode: 200, body: Data(event.utf8))
            }
            let json = scenario == 2 ? #"{"items":[{"id":"primary-copy","primary":false,"accessRole":"reader"}]}"# : #"{"items":[{"id":"primary-copy","primary":true,"accessRole":"owner"}]}"#
            return HTTPResponse(statusCode: 200, body: Data(json.utf8))
        }
        let service = GoogleConnectionService(oauth: GoogleOAuthClient(
            configuration: GoogleOAuthConfiguration(clientID: "synthetic")), calendarClient: GoogleCalendarClient(transport: transport), tokenVault: vault, state: state)
        let target = RSVPTarget(provider: scenario == 3 ? "eventkit" : "google", connectionID: "connection",
            calendarBindingID: "binding", calendarID: scenario == 4 ? "different-copy" : "primary-copy", eventID: "invitation")
        let intent = RSVPActionIntent(id: "decision", target: target, expectedVersion: "v1", previousResponse: .needsResponse, decision: .yes)
        if scenario == 5 {
            let result = try await RSVPActionExecutor(state: state).perform(intent, using: service)
            #expect(result.outcome.confirmedResponse == .accepted)
            #expect(result.submissionAccepted)
        } else {
            await #expect(throws: RSVPActionError.self) { try await service.submitRSVP(intent) }
        }
    }
}

@Test("All-day mirrors are written on the source's calendar day", arguments: [
    "Asia/Tokyo", "Europe/Paris", "America/Los_Angeles", "Europe/Paris-dst",
])
func allDayWrite(zone: String) async throws {
    let (identifier, day) = zone == "Europe/Paris-dst" ? ("Europe/Paris", 25) : (zone, 5)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: day))!
    let end = calendar.date(byAdding: .day, value: 1, to: start)!
    let transport = RecordingTransport { request in
        let object = try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        #expect((object["start"] as? [String: String]) == ["date": "2026-10-\(String(format: "%02d", day))"])
        #expect((object["end"] as? [String: String]) == ["date": "2026-10-\(String(format: "%02d", day + 1))"])
        return HTTPResponse(statusCode: 200, body: Data(#"{"id":"provider-event","etag":"e"}"#.utf8))
    }
    var request = googleManagedRequest()
    request = ManagedEventWriteRequest(
        desiredFingerprint: request.desiredFingerprint,
        payload: DesiredEventPayload(
            startsAt: start, endsAt: end, isAllDay: true, availability: "busy", title: "Busy",
            isPrivate: nil, timeZoneIdentifier: identifier
        ),
        provenance: request.provenance
    )
    _ = try await GoogleCalendarClient(transport: transport)
        .createManagedEvent(accessToken: "token", calendarID: "target", request: request)
}

@Test("An all-day source keeps the zone its dates were read in")
func allDayRead() async throws {
    let json = #"{"timeZone":"Europe/Paris","items":[{"id":"a","start":{"date":"2026-10-05"},"end":{"date":"2026-10-06"}},{"id":"b","start":{"date":"2026-10-05","timeZone":"Asia/Tokyo"},"end":{"date":"2026-10-06"}},{"id":"c","start":{"dateTime":"2026-10-05T10:00:00Z"},"end":{"dateTime":"2026-10-05T11:00:00Z"}}]}"#
    let client = GoogleCalendarClient(transport: RecordingTransport { _ in
        HTTPResponse(statusCode: 200, body: Data(json.utf8))
    })
    let page = try await client.events(
        accessToken: "synthetic", connectionID: "google-test", calendarID: "synthetic-calendar",
        from: Date(), through: Date(), responseIdentityScope: .unverified
    )
    #expect(page.events.map(\.timeZoneIdentifier) == ["Europe/Paris", "Asia/Tokyo", nil])
}
