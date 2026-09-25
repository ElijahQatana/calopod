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
}

@Suite("Microsoft Graph")
struct MicrosoftGraphClientTests {
    @Test("Calendar listing follows Graph pagination")
    func calendarPagination() async throws {
        let transport = ClosureTransport { request in
            if request.url?.query == "page=2" {
                return HTTPResponse(
                    statusCode: 200,
                    body: Data(#"{"value":[{"id":"second","name":"Shared","canEdit":false}]}"#.utf8)
                )
            }
            return HTTPResponse(
                statusCode: 200,
                body: Data(#"{"value":[{"id":"first","name":"Main","isDefaultCalendar":true,"canEdit":true}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendars?page=2"}"#.utf8)
            )
        }
        let client = MicrosoftGraphClient(transport: transport)

        let calendars = try await client.calendars(accessToken: "token")

        #expect(calendars.map(\.id) == ["first", "second"])
        #expect(calendars[0].isDefault)
        #expect(!calendars[1].canEdit)
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
                    #"{"value":[{"id":"instance","seriesMasterId":"series","originalStart":"2026-09-24T13:00:00Z","start":{"dateTime":"2026-09-24T13:00:00.0000000","timeZone":"UTC"},"end":{"dateTime":"2026-09-24T14:00:00.0000000","timeZone":"UTC"},"isAllDay":false,"showAs":"tentative","sensitivity":"private","subject":"Synthetic meeting","lastModifiedDateTime":"2026-09-20T10:00:00Z"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/me/calendars/calendar/calendarView/delta?page=2"}"#.utf8
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
        #expect(!page.events[0].isManagedMirror)
        #expect(page.events[0].start != nil)
        #expect(page.events[1].isCancelled)
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
        #expect(createObject["transactionId"] as? String == managed.provenance.mirrorKey)
        let extensions = try #require(createObject["extensions"] as? [[String: Any]])
        #expect(extensions.first?["mirrorKey"] as? String == managed.provenance.mirrorKey)
        #expect(created.providerVersion == "version-one")
        #expect(updated.providerVersion == "version-two")
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
