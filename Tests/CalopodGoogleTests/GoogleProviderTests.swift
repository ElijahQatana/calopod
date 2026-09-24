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
    @Test("Authorization uses PKCE and read-only scopes")
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
            #expect(values["scope"]?.contains("calendar.events.readonly") == true)
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
                    #"{"timeZone":"America/New_York","items":[{"id":"instance","recurringEventId":"series","originalStartTime":{"dateTime":"2026-03-08T09:00:00-04:00"},"start":{"dateTime":"2026-03-08T09:00:00-04:00"},"end":{"dateTime":"2026-03-08T10:00:00-04:00"},"status":"confirmed","visibility":"private","summary":"Synthetic meeting","updated":"2026-03-01T12:00:00Z"},{"id":"all-day","start":{"date":"2026-03-09"},"end":{"date":"2026-03-10"},"transparency":"transparent"},{"id":"cancelled","recurringEventId":"series","originalStartTime":{"dateTime":"2026-03-10T09:00:00-04:00"},"status":"cancelled"}],"nextSyncToken":"stored-only"}"#.utf8
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

        #expect(page.events.count == 3)
        #expect(page.events[0].seriesID == "series")
        #expect(page.events[0].originalStart == "2026-03-08T09:00:00-04:00")
        #expect(page.events[0].isPrivate)
        #expect(page.events[1].isAllDay)
        #expect(page.events[1].availability == .free)
        #expect(page.events[2].isCancelled)
        #expect(page.events[2].start == nil)
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

        _ = try await firstService.events(
            connectionID: connection.id,
            binding: binding,
            from: start,
            through: end
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
        _ = try await service.events(
            connectionID: connection.id,
            binding: bindings[0],
            from: fixedNow,
            through: fixedNow.addingTimeInterval(86_400)
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
