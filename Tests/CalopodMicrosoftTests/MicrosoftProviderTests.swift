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
    @Test("Authorization supports personal and work accounts with read-only scopes")
    func authorization() async throws {
        let transport = ClosureTransport { request in
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            #expect(body.contains("code_verifier="))
            #expect(body.contains("offline_access"))
            #expect(body.contains("Calendars.Read"))
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
            #expect(values["scope"]?.contains("Calendars.Read") == true)
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

        _ = try await first.events(
            connectionID: connection.id,
            binding: binding,
            from: rangeStart,
            through: rangeEnd
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
        #expect(urls.count == 2)
        #expect(urls[0].contains("startDateTime="))
        #expect(urls[1].contains("$deltatoken=durable"))
        let cursors = try state.cursorValues(
            connectionID: connection.id,
            calendarBindingID: binding.id
        )
        #expect(cursors.values.contains { $0.contains("$deltatoken=durable") })

        try reopened.disconnect(connectionID: connection.id)
        #expect(try state.connections(provider: "microsoft").isEmpty)
        #expect(try vault.tokens(provider: "microsoft", connectionID: connection.id) == nil)
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
        let link = "https://graph.microsoft.com/v1.0/me/calendars/calendar/calendarView/delta?$deltatoken=durable"
        return HTTPResponse(
            statusCode: 200,
            body: Data("{\"value\":[],\"@odata.deltaLink\":\"\(link)\"}".utf8)
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
