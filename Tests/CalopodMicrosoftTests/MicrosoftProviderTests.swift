import CalopodDomain
import CalopodMicrosoft
import CalopodProviders
import CalopodStore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

@Suite("Microsoft OAuth")
struct MicrosoftOAuthTests {
    @Test("Authorization supports personal and work accounts with calendar write scope")
    func authorization() async throws {
        let transport = ClosureTransport { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("code_verifier="))
            #expect(body.contains("offline_access"))
            #expect(body.contains("Calendars.ReadWrite"))
            return HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"token_type":"Bearer"}"#.utf8)
            )
        }
        let client = MicrosoftOAuthClient(
            configuration: MicrosoftOAuthConfiguration(clientID: "client-id"),
            transport: transport,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let browser = StubBrowserSession { url in
            #expect(url.path.contains("/common/oauth2/v2.0/authorize"))
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            #expect(values["client_id"] == "client-id")
            #expect(values["response_mode"] == "query")
            #expect(values["code_challenge_method"] == "S256")
            #expect(values["state"] == "fixed-state")
            #expect(values["scope"]?.contains("Calendars.ReadWrite") == true)
        }

        let tokens = try await client.authorize(using: browser)

        #expect(tokens.refreshToken == "refresh")
        #expect(tokens.expiresAt == Date(timeIntervalSince1970: 3_700))
    }

    @Test("Refresh accepts a rotated refresh token")
    func refreshRotation() async throws {
        let client = MicrosoftOAuthClient(
            configuration: MicrosoftOAuthConfiguration(clientID: "client-id"),
            transport: ClosureTransport { _ in
                HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":1800}"#.utf8)
                )
            },
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let old = OAuthTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: .distantPast
        )

        let refreshed = try await client.refresh(old)

        #expect(refreshed.accessToken == "new-access")
        #expect(refreshed.refreshToken == "new-refresh")
    }

    @Test("Conditional access responses have a distinct failure")
    func conditionalAccess() async throws {
        let client = MicrosoftOAuthClient(
            configuration: MicrosoftOAuthConfiguration(clientID: "client-id"),
            transport: ClosureTransport { _ in
                HTTPResponse(
                    statusCode: 400,
                    body: Data(#"{"error":"invalid_grant","suberror":"basic_action"}"#.utf8)
                )
            }
        )
        let old = OAuthTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            tokenType: "Bearer",
            scope: nil,
            expiresAt: .distantPast
        )

        await #expect(throws: ProviderFailure.accountPolicyRequired) {
            try await client.refresh(old)
        }
    }

    @Test("Expired refresh credentials require reconnection")
    func expiredRefreshCredentials() async throws {
        let client = MicrosoftOAuthClient(
            configuration: MicrosoftOAuthConfiguration(clientID: "client-id"),
            transport: ClosureTransport { _ in
                HTTPResponse(
                    statusCode: 400,
                    body: Data(#"{"error":"invalid_grant"}"#.utf8)
                )
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

@Suite("Microsoft Graph")
struct MicrosoftGraphClientTests {
    @Test("Calendar listing follows Graph pagination")
    func calendarPagination() async throws {
        let transport = ClosureTransport { request in
            if request.url?.query == "page=2" {
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"value":[{"id":"second","name":"Shared","canEdit":false,"color":"auto","hexColor":""}]}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: 200,
                body: Data(##"{"value":[{"id":"first","name":"Main","isDefaultCalendar":true,"canEdit":true,"color":"lightBlue","hexColor":"#1A8CFF"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendars?page=2"}"##.utf8)
            )
        }
        let client = MicrosoftGraphClient(transport: transport)

        let calendars = try await client.calendars(accessToken: "token")

        #expect(calendars.map(\.id) == ["first", "second"])
        #expect(calendars[0].isDefault)
        #expect(!calendars[1].canEdit)
        #expect(calendars.map(\.hexColor) == ["#1a8cff", nil])
    }

    @Test("Calendar delta follows next links and normalizes removals")
    func calendarDelta() async throws {
        let transport = ClosureTransport { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
            #expect(request.value(forHTTPHeaderField: "Prefer")?.contains("UTC") == true)
            if request.url?.query == "page=2" {
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"value":[{"id":"removed","@removed":{"reason":"deleted"}}],"@odata.deltaLink":"https://graph.microsoft.com/v1.0/me/calendars/calendar/calendarView/delta?$deltatoken=opaque"}"#.utf8)
                )
            }
            #expect(request.url?.path.contains("/me/calendars/calendar/calendarView/delta") == true)
            #expect(request.url?.query?.contains("startDateTime=") == true)
            #expect(request.url?.query?.contains("endDateTime=") == true)
            let queryItems = request.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
            } ?? []
            #expect(!queryItems.contains { $0.name == "$expand" })
            return HTTPResponse(
                statusCode: 200,
                body: Data(
                    #"{"value":[{"id":"instance","seriesMasterId":"series","originalStart":"2026-09-24T13:00:00Z","start":{"dateTime":"2026-09-24T13:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-24T14:00:00.0000000","timeZone":"UTC"},"isAllDay":false,"showAs":"tentative","sensitivity":"private","subject":"Synthetic meeting","bodyPreview":"Synthetic agenda","location":{"displayName":"Synthetic room"},"onlineMeeting":{"joinUrl":"https://meet.example.test/synthetic"},"organizer":{"emailAddress":{"name":"Synthetic Organizer","address":"organizer@example.com"}},"attendees":[{"emailAddress":{"name":"Synthetic Guest","address":"guest@example.com"},"status":{"response":"accepted"}}],"lastModifiedDateTime":"2026-09-20T10:00:00Z"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendars/calendar/calendarView/delta?page=2"}"#.utf8
                )
            )
        }
        let client = MicrosoftGraphClient(transport: transport)

        let page = try await client.events(
            accessToken: "token",
            connectionID: "connection",
            calendarID: "calendar",
            from: Date(timeIntervalSince1970: 1_790_252_000),
            through: Date(timeIntervalSince1970: 1_790_338_400)
        )

        #expect(page.events.count == 2)
        #expect(page.events[0].seriesID == "series")
        #expect(page.events[0].availability == .tentative)
        #expect(page.events[0].isPrivate)
        #expect(page.events[0].location == "Synthetic room")
        #expect(page.events[0].notes == "Synthetic agenda")
        #expect(page.events[0].url == "https://meet.example.test/synthetic")
        #expect(page.events[0].organizer?.emailAddress == "organizer@example.com")
        #expect(page.events[0].attendees.first?.status == "accepted")
        #expect(!page.events[0].isManagedMirror)
        #expect(page.events[0].start != nil)
        #expect(page.events[1].isCancelled)
        #expect(page.events[1].tombstoneEvidence == .unconfirmed)
        #expect(page.events[1].start == nil)
        #expect(page.nextSyncToken?.contains("$deltatoken=opaque") == true)
    }

    @Test("Graph links cannot redirect credentials to another origin")
    func rejectsForeignLinks() async throws {
        let client = MicrosoftGraphClient(
            transport: ClosureTransport { _ in
                HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"value":[],"@odata.nextLink":"https://example.invalid/collect"}"#.utf8)
                )
            }
        )

        await #expect(throws: ProviderFailure.invalidResponse) {
            try await client.calendars(accessToken: "token")
        }
    }

    @Test("Throttling preserves the provider retry delay")
    func throttling() async throws {
        let client = MicrosoftGraphClient(
            transport: ClosureTransport { _ in
                HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: Data())
            }
        )

        await #expect(throws: ProviderFailure.temporaryFailure(retryAfterSeconds: 120)) {
            try await client.calendars(accessToken: "token")
        }
    }
}

@Suite("Microsoft connection state")
struct MicrosoftConnectionServiceTests {
    @Test("Delta links survive restart and disconnect removes all local state")
    func lifecycle() async throws {
        let database = try CalopodDatabase.inMemory()
        let state = LocalStateRepository(database: database)
        let connection = StoredConnection(
            id: "connection",
            configurationID: "default",
            provider: "microsoft",
            displayLabel: "Microsoft Calendar",
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
            provider: "microsoft",
            connectionID: connection.id
        )
        let transport = DeltaRecordingTransport()
        let rangeStart = Date(timeIntervalSince1970: 1_000)
        let rangeEnd = rangeStart.addingTimeInterval(86_400)
        let first = service(state: state, vault: vault, transport: transport)

        let firstPage = try await first.events(
            connectionID: connection.id,
            binding: binding,
            from: rangeStart,
            through: rangeEnd
        )
        try saveCursorUpdates(
            firstPage,
            repository: state,
            connectionID: connection.id,
            calendarBindingID: binding.id
        )
        let reopened = service(
            state: LocalStateRepository(database: database),
            vault: vault,
            transport: transport
        )
        _ = try await reopened.events(
            connectionID: connection.id,
            binding: binding,
            from: rangeStart,
            through: rangeEnd
        )

        let urls = await transport.urls
        #expect(urls.count == 4)
        #expect(urls[0].contains("startDateTime="))
        #expect(urls[1].contains("$expand=extensions"))
        #expect(urls[2].contains("$deltatoken=durable"))
        #expect(urls[3].contains("$expand=extensions"))
        let cursors = try state.cursorValues(
            connectionID: connection.id,
            calendarBindingID: binding.id
        )
        #expect(cursors.values.contains { $0.contains("$deltatoken=durable") })

        try reopened.disconnect(connectionID: connection.id)
        #expect(try state.connections(provider: "microsoft").isEmpty)
        #expect(try vault.tokens(provider: "microsoft", connectionID: connection.id) == nil)
    }

    @Test("Bounded marker lookup identifies managed mirrors without delta expansion")
    func managedMirrorLookup() async throws {
        let database = try CalopodDatabase.inMemory()
        let state = LocalStateRepository(database: database)
        let connection = StoredConnection(
            id: "connection",
            configurationID: "default",
            provider: "microsoft",
            displayLabel: "Microsoft Calendar",
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
        let vault = OAuthTokenVault(secretStore: MemorySecretStore())
        try vault.save(
            OAuthTokens(
                accessToken: "access",
                refreshToken: "refresh",
                tokenType: "Bearer",
                scope: nil,
                expiresAt: .distantFuture
            ),
            provider: "microsoft",
            connectionID: connection.id
        )
        let provider = service(
            state: state,
            vault: vault,
            transport: MicrosoftMirrorLookupTransport()
        )

        let page = try await provider.events(
            connectionID: connection.id,
            binding: binding,
            from: Date(timeIntervalSince1970: 1_000),
            through: Date(timeIntervalSince1970: 5_000)
        )

        #expect(page.events.map(\.eventID) == ["managed", "source"])
        #expect(page.events.map(\.isManagedMirror) == [true, false])
    }

    private func service(
        state: LocalStateRepository,
        vault: OAuthTokenVault,
        transport: any HTTPTransport
    ) -> MicrosoftConnectionService {
        MicrosoftConnectionService(
            oauth: MicrosoftOAuthClient(
                configuration: MicrosoftOAuthConfiguration(clientID: "client-id"),
                transport: transport
            ),
            graph: MicrosoftGraphClient(transport: transport),
            tokenVault: vault,
            state: state
        )
    }
}

@Suite("Microsoft managed writes")
struct MicrosoftManagedWriteTests {
    @Test("Create, update, and delete preserve provenance and version state")
    func lifecycle() async throws {
        let transport = MicrosoftManagedWriteTransport()
        let client = MicrosoftGraphClient(transport: transport)
        let managed = microsoftManagedRequest()

        let created = try await client.createManagedEvent(
            accessToken: "token",
            calendarID: "target",
            request: managed
        )
        let updated = try await client.updateManagedEvent(
            accessToken: "token",
            calendarID: "target",
            providerEventID: created.providerEventID,
            expectedVersion: created.providerVersion,
            request: managed
        )
        try await client.deleteManagedEvent(
            accessToken: "token",
            calendarID: "target",
            providerEventID: updated.providerEventID,
            expectedVersion: updated.providerVersion
        )

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["POST", "PATCH", "PATCH", "DELETE"])
        #expect(requests[1].ifMatch == "version-one")
        #expect(requests[2].path.hasSuffix("/extensions/com.calopod.managed"))
        #expect(requests[3].ifMatch == "version-two")
        let createObject = try #require(
            JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any]
        )
        #expect(createObject["subject"] as? String == "Busy")
        #expect(createObject["body"] == nil)
        #expect(createObject["location"] == nil)
        #expect(createObject["attendees"] == nil)
        #expect(createObject["isReminderOn"] as? Bool == false)
        #expect(createObject["isOnlineMeeting"] as? Bool == false)
        #expect(createObject["responseRequested"] as? Bool == false)
        #expect(createObject["transactionId"] as? String == managed.provenance.mirrorKey)
        let extensions = try #require(createObject["extensions"] as? [[String: Any]])
        #expect(extensions.first?["mirrorKey"] as? String == managed.provenance.mirrorKey)
        #expect(created.providerVersion == "version-one")
        #expect(updated.providerVersion == "version-two")
    }

    @Test("Full details writes location and notes without creating invitees")
    func fullDetails() async throws {
        let transport = MicrosoftManagedWriteTransport()
        let client = MicrosoftGraphClient(transport: transport)

        _ = try await client.createManagedEvent(
            accessToken: "token",
            calendarID: "target",
            request: microsoftFullDetailsRequest()
        )

        let request = try #require(await transport.requests.first)
        let object = try #require(
            JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        )
        let location = try #require(object["location"] as? [String: String])
        let body = try #require(object["body"] as? [String: String])
        #expect(location["displayName"] == "Synthetic room")
        #expect(body["contentType"] == "text")
        #expect(body["content"] == "Synthetic agenda and participant context")
        #expect(object["attendees"] == nil)
        #expect(object["isReminderOn"] as? Bool == false)
        #expect(object["isOnlineMeeting"] as? Bool == false)
        #expect(object["responseRequested"] as? Bool == false)
    }

    @Test("Managed target reads expand ownership markers and provider versions")
    func managedRead() async throws {
        let client = MicrosoftGraphClient(
            transport: ClosureTransport { request in
                let queryItems = URLComponents(
                    url: try #require(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
                #expect(queryItems.contains { $0.name == "$expand" && $0.value == "extensions" })
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(
                        #"{"value":[{"id":"provider-event","changeKey":"v2","start":{"dateTime":"2026-09-25T12:30:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-25T13:00:00.0000000","timeZone":"UTC"},"isAllDay":false,"showAs":"busy","subject":"Busy","extensions":[{"extensionName":"com.calopod.managed","schemaVersion":"1","configurationID":"synthetic-configuration","armID":"synthetic-arm","mirrorKey":"synthetic-mirror","sourceKeyHash":"synthetic-source","ruleMode":"busy","ownershipKeyID":"synthetic-key","authenticationTag":"synthetic-tag"}]}]}"#.utf8
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

    @Test("Near-simultaneous creates share one transaction identity")
    func concurrentCreates() async throws {
        let transport = MicrosoftIdempotentCreateTransport()
        let first = MicrosoftGraphClient(transport: transport)
        let second = MicrosoftGraphClient(transport: transport)
        let managed = microsoftManagedRequest()

        async let firstResult = first.createManagedEvent(
            accessToken: "token-one",
            calendarID: "target",
            request: managed
        )
        async let secondResult = second.createManagedEvent(
            accessToken: "token-two",
            calendarID: "target",
            request: managed
        )
        let results = try await [firstResult, secondResult]

        #expect(results.map(\.providerEventID) == ["provider-event", "provider-event"])
        #expect(await transport.transactionIDs == [
            managed.provenance.mirrorKey,
            managed.provenance.mirrorKey,
        ])
    }
}

private func microsoftManagedRequest() -> ManagedEventWriteRequest {
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

private func microsoftFullDetailsRequest() -> ManagedEventWriteRequest {
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
            mirrorKey: "synthetic-full-mirror",
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

private actor ClosureTransport: HTTPTransport {
    private let response: @Sendable (URLRequest) async throws -> HTTPResponse

    init(response: @escaping @Sendable (URLRequest) async throws -> HTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try await response(request)
    }
}

private actor DeltaRecordingTransport: HTTPTransport {
    private(set) var urls: [String] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let url = request.url?.absoluteString ?? ""
        urls.append(url)
        if request.url?.path.hasSuffix("/calendarView") == true {
            return HTTPResponse(statusCode: 200, body: Data(#"{"value":[]}"#.utf8))
        }
        let link = "https://graph.microsoft.com/v1.0/me/calendars/calendar/calendarView/delta?$deltatoken=durable"
        return HTTPResponse(
            statusCode: 200,
            body: Data("{\"value\":[],\"@odata.deltaLink\":\"\(link)\"}".utf8)
        )
    }
}

private actor MicrosoftMirrorLookupTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path.hasSuffix("/calendarView") == true {
            return HTTPResponse(
                statusCode: 200,
                body: Data(
                    #"{"value":[{"id":"managed","start":{"dateTime":"2026-09-25T12:30:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-25T13:00:00.0000000","timeZone":"UTC"},"extensions":[{"extensionName":"com.calopod.managed"}]}]}"#.utf8
                )
            )
        }
        return HTTPResponse(
            statusCode: 200,
            body: Data(
                #"{"value":[{"id":"managed","start":{"dateTime":"2026-09-25T12:30:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-25T13:00:00.0000000","timeZone":"UTC"}},{"id":"source","start":{"dateTime":"2026-09-25T14:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-25T15:00:00.0000000","timeZone":"UTC"}}]}"#.utf8
            )
        )
    }
}

private struct MicrosoftRecordedRequest: Sendable {
    let method: String
    let path: String
    let ifMatch: String?
    let body: Data
}

private actor MicrosoftManagedWriteTransport: HTTPTransport {
    private(set) var requests: [MicrosoftRecordedRequest] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        requests.append(
            MicrosoftRecordedRequest(
                method: method,
                path: path,
                ifMatch: request.value(forHTTPHeaderField: "If-Match"),
                body: request.httpBody ?? Data()
            )
        )
        if method == "DELETE" {
            return HTTPResponse(statusCode: 204, body: Data())
        }
        if path.contains("/extensions/") {
            return HTTPResponse(statusCode: 200, body: Data(#"{"id":"com.calopod.managed"}"#.utf8))
        }
        let version = method == "POST" ? "version-one" : "version-two"
        return HTTPResponse(
            statusCode: 200,
            body: Data("{\"id\":\"provider-event\",\"changeKey\":\"\(version)\"}".utf8)
        )
    }
}

private actor MicrosoftIdempotentCreateTransport: HTTPTransport {
    private(set) var transactionIDs: [String] = []

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let object = try JSONSerialization.jsonObject(
            with: request.httpBody ?? Data()
        ) as? [String: Any]
        transactionIDs.append(object?["transactionId"] as? String ?? "")
        return HTTPResponse(
            statusCode: 200,
            body: Data(#"{"id":"provider-event","changeKey":"shared-version"}"#.utf8)
        )
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


@Suite("Microsoft current user response")
struct MicrosoftResponseTests {
    @Test(arguments: ["notResponded", "accepted", "tentativelyAccepted", "declined", "organizer", "none", "unexpected"])
    func responseStates(_ status: String) async throws {
        let event = try await read("\"responseStatus\":{\"response\":\"\(status)\",\"time\":\"2026-11-01T12:00:00Z\"},\"showAs\":\"tentative\",\"attendees\":[{\"status\":{\"response\":\"declined\"}}]", scope: .authenticatedUser)
        let expected: [String: EventResponseState] = [
            "notResponded": .needsResponse, "accepted": .accepted,
            "tentativelyAccepted": .tentative, "declined": .declined, "organizer": .organizer,
        ]
        #expect(event.currentUserResponse.state == (expected[status] ?? .unknown))
        #expect(event.currentUserResponse.respondedAt == ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z"))
        #expect(event.availability == .tentative)
        #expect(!event.currentUserResponse.actionCapability.isEligible)
        #expect(event.currentUserResponse.actionCapability.supportedScopes.isEmpty)
    }

    @Test
    func organizerAndMissingResponse() async throws {
        let organizer = try await read("\"isOrganizer\":true", scope: .authenticatedUser)
        #expect(organizer.currentUserResponse.state == .organizer)
        let missing = try await read("\"attendees\":[{\"status\":{\"response\":\"notResponded\"}}]", scope: .authenticatedUser)
        #expect(missing.currentUserResponse.state == .unknown)
        for time in ["0001-01-01T00:00:00Z", "invalid"] {
            let event = try await read("\"responseStatus\":{\"response\":\"accepted\",\"time\":\"\(time)\"}", scope: .authenticatedUser)
            #expect(event.currentUserResponse.state == .accepted)
            #expect(event.currentUserResponse.respondedAt == nil)
        }
    }

    @Test
    func sharedAndDelegatedOwnerResponseIsUnknown() async throws {
        let event = try await read("\"isOrganizer\":true,\"responseStatus\":{\"response\":\"accepted\",\"time\":\"2026-11-01T12:00:00Z\"}", scope: .unverified)
        #expect(event.currentUserResponse.state == .unknown)
        #expect(event.currentUserResponse.respondedAt == nil)
        #expect(event.currentUserResponse.limits.contains(.identityUnverified))
    }

    private func read(_ metadata: String, scope: ResponseIdentityScope) async throws -> ProviderEvent {
        let json = "{\"value\":[{\"id\":\"synthetic\",\"start\":{\"dateTime\":\"2026-11-05T14:00:00Z\"},\"end\":{\"dateTime\":\"2026-11-05T15:00:00Z\"},\(metadata)}]}"
        let client = MicrosoftGraphClient(transport: ClosureTransport { request in
            #expect(request.httpMethod == "GET")
            return HTTPResponse(statusCode: 200, body: Data(json.utf8))
        })
        let page = try await client.events(accessToken: "synthetic", connectionID: "microsoft-test",
                                           calendarID: "synthetic-calendar", from: Date(), through: Date(),
                                           responseIdentityScope: scope)
        return try #require(page.events.first)
    }
}


@Test
func microsoftResponseScopeDiscoverySurvivesRepositoryReads() async throws {
    let database = try CalopodDatabase.inMemory()
    let state = LocalStateRepository(database: database)
    let connection = StoredConnection(id: "response-connection", configurationID: "default",
                                      provider: "microsoft", displayLabel: "Synthetic", isEnabled: true)
    try state.saveConnection(connection)
    let vault = OAuthTokenVault(secretStore: MemorySecretStore())
    try vault.save(OAuthTokens(accessToken: "synthetic", refreshToken: "synthetic",
                               tokenType: "Bearer", scope: nil, expiresAt: .distantFuture),
                   provider: "microsoft", connectionID: connection.id)
    let transport = ClosureTransport { request in
        #expect(request.httpMethod == "GET")
        let path = request.url?.path ?? ""
        if path.hasSuffix("calendars") {
            return HTTPResponse(statusCode: 200, body: Data(#"{"value":[{"id":"primary-copy","isDefaultCalendar":true,"canEdit":true},{"id":"shared-copy","canEdit":true},{"id":"secondary-copy","canEdit":true}]}"#.utf8))
        }
        if request.url?.query?.contains("expand") == true {
            return HTTPResponse(statusCode: 200, body: Data(#"{"value":[]}"#.utf8))
        }
        return HTTPResponse(statusCode: 200, body: Data(#"{"value":[{"id":"event","responseStatus":{"response":"notResponded"}}]}"#.utf8))
    }
    let service = MicrosoftConnectionService(
        oauth: MicrosoftOAuthClient(configuration: MicrosoftOAuthConfiguration(clientID: "synthetic")),
        graph: MicrosoftGraphClient(transport: transport), tokenVault: vault, state: state)
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
func microsoftRSVPRequiresCurrentPermissionAndOperatorScope() async throws {
    for scenario in 0..<6 {
        let state = LocalStateRepository(database: try .inMemory())
        try state.saveConnection(StoredConnection(id: "connection", configurationID: "default",
            provider: "microsoft", displayLabel: "Synthetic", isEnabled: true))
        try state.replaceCalendarBindings(connectionID: "connection", bindings: [StoredCalendarBinding(
            id: "binding", connectionID: "connection", providerCalendarID: "primary-copy", displayLabel: "Synthetic",
            isSelected: true, isReadOnly: false,
            responseIdentityScope: scenario == 1 ? .unverified : .authenticatedUser)])
        let vault = OAuthTokenVault(secretStore: MemorySecretStore())
        try vault.save(OAuthTokens(accessToken: "synthetic", refreshToken: "synthetic", tokenType: "Bearer",
            scope: scenario == 0 ? nil : "https://graph.microsoft.com/Calendars.ReadWrite", expiresAt: .distantFuture),
            provider: "microsoft", connectionID: "connection")
        let transport = ClosureTransport { request in
            if request.httpMethod == "POST" {
                #expect(try state.rsvpAction(id: "decision")?.outcome.status == .pending)
                return HTTPResponse(statusCode: 202, body: Data())
            }
            #expect(request.httpMethod == "GET")
            if request.url?.lastPathComponent != "calendars" {
                let accepted = try state.rsvpAction(id: "decision")?.submissionAccepted == true
                let event = #"{"id":"invitation","@odata.etag":"v1","type":"singleInstance","isOrganizer":false,"attendees":[{"emailAddress":{"address":"invitee@example.com"}}],"responseStatus":{"response":"notResponded"}}"#.replacingOccurrences(of: "notResponded", with: accepted ? "accepted" : "notResponded")
                return HTTPResponse(statusCode: 200, body: Data(event.utf8))
            }
            let json = scenario == 2 ? #"{"value":[{"id":"primary-copy","isDefaultCalendar":false,"canEdit":false}]}"# : #"{"value":[{"id":"primary-copy","isDefaultCalendar":true,"canEdit":true}]}"#
            return HTTPResponse(statusCode: 200, body: Data(json.utf8))
        }
        let service = MicrosoftConnectionService(oauth: MicrosoftOAuthClient(
            configuration: MicrosoftOAuthConfiguration(clientID: "synthetic")), graph: MicrosoftGraphClient(transport: transport), tokenVault: vault, state: state)
        let target = RSVPTarget(provider: scenario == 3 ? "eventkit" : "microsoft", connectionID: "connection",
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

@Test("All-day mirrors run midnight to midnight on the source's calendar day", arguments: [
    "Asia/Tokyo", "Europe/Paris", "America/Los_Angeles",
])
func allDayWrite(zone: String) async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5))!
    let end = calendar.date(byAdding: .day, value: 1, to: start)!
    let transport = MicrosoftManagedWriteTransport()
    let base = microsoftManagedRequest()
    let request = ManagedEventWriteRequest(
        desiredFingerprint: base.desiredFingerprint,
        payload: DesiredEventPayload(
            startsAt: start, endsAt: end, isAllDay: true, availability: "busy", title: "Busy",
            isPrivate: nil, timeZoneIdentifier: zone
        ),
        provenance: base.provenance
    )

    _ = try await MicrosoftGraphClient(transport: transport)
        .createManagedEvent(accessToken: "token", calendarID: "target", request: request)

    let sent = try #require(await transport.requests.first)
    let object = try #require(JSONSerialization.jsonObject(with: sent.body) as? [String: Any])
    #expect((object["start"] as? [String: String]) == ["dateTime": "2026-10-05T00:00:00.0000000", "timeZone": "UTC"])
    #expect((object["end"] as? [String: String]) == ["dateTime": "2026-10-06T00:00:00.0000000", "timeZone": "UTC"])
    #expect(object["isAllDay"] as? Bool == true)
}

@Suite("Microsoft event flags")
struct MicrosoftFlagTests {
    @Test(arguments: [
        (#""showAs":"free""#, ProviderAvailability.free, false, EventKind?.none),
        (#""showAs":"busy""#, .busy, false, nil),
        (#""showAs":"oof""#, .unavailable, false, nil),
        (#""showAs":"workingElsewhere""#, .tentative, false, .workingLocation),
        (#""sensitivity":"private""#, .busy, true, nil),
        (#""sensitivity":"confidential""#, .busy, true, nil),
        (#""sensitivity":"normal""#, .busy, false, nil),
    ])
    func flags(fields: String, availability: ProviderAvailability, isPrivate: Bool, kind: EventKind?) async throws {
        let json = #"{"value":[{"id":"synthetic","start":{"dateTime":"2026-11-05T14:00:00Z"},"end":{"dateTime":"2026-11-05T15:00:00Z"},\#(fields)}]}"#
        let client = MicrosoftGraphClient(transport: ClosureTransport { _ in
            HTTPResponse(statusCode: 200, body: Data(json.utf8))
        })
        let page = try await client.events(accessToken: "synthetic", connectionID: "microsoft-test",
                                           calendarID: "synthetic-calendar", from: Date(), through: Date())
        let event = try #require(page.events.first)
        #expect(event.availability == availability)
        #expect(event.isPrivate == isPrivate)
        #expect(event.kind == kind)
    }
}
