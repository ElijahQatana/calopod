import CalopodDomain
import CalopodProviders
import CalopodStore
import CryptoKit
import Foundation

/// Manages one Microsoft Calendar Connection end to end: authorization,
/// token refresh, calendar discovery, and event fetch/write — the Microsoft
/// Graph counterpart to `GoogleConnectionService`.
public struct MicrosoftConnectionService: Sendable {
    private static let provider = ProviderKind.microsoft.rawValue
    private static let deltaScope = "microsoft.events.delta-link.v1"

    private let oauth: MicrosoftOAuthClient
    private let graph: MicrosoftGraphClient
    private let tokenVault: OAuthTokenVault
    private let state: LocalStateRepository
    private let now: @Sendable () -> Date

    public init(
        oauth: MicrosoftOAuthClient,
        graph: MicrosoftGraphClient,
        tokenVault: OAuthTokenVault,
        state: LocalStateRepository,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.oauth = oauth
        self.graph = graph
        self.tokenVault = tokenVault
        self.state = state
        self.now = now
    }

    @discardableResult
    public func authorize(
        configurationID: String = "default",
        using browser: any BrowserAuthorizationSession
    ) async throws -> StoredConnection {
        let connection = StoredConnection(
            id: UUID().uuidString.lowercased(),
            configurationID: configurationID,
            provider: Self.provider,
            displayLabel: "Microsoft Calendar",
            isEnabled: true
        )
        let tokens = try await oauth.authorize(using: browser)
        try tokenVault.save(tokens, provider: Self.provider, connectionID: connection.id)
        // Same rollback as GoogleConnectionService.authorize: don't leave
        // Keychain tokens behind for a connection that never got persisted.
        do {
            try state.saveConnection(connection, now: now())
        } catch {
            try? tokenVault.remove(provider: Self.provider, connectionID: connection.id)
            throw error
        }
        return connection
    }

    public func refreshCalendars(connectionID: String) async throws -> [StoredCalendarBinding] {
        let tokens = try await validTokens(connectionID: connectionID)
        let calendars = try await graph.calendars(accessToken: tokens.accessToken)
        let bindings = calendars.map {
            StoredCalendarBinding(
                id: stableBindingID(connectionID: connectionID, calendarID: $0.id),
                connectionID: connectionID,
                providerCalendarID: $0.id,
                displayLabel: $0.name,
                isSelected: false,
                isReadOnly: !$0.canEdit,
                responseIdentityScope: $0.isDefault ? .authenticatedUser : .unverified
            )
        }
        try state.replaceCalendarBindings(connectionID: connectionID, bindings: bindings, now: now())
        return try state.calendarBindings(connectionID: connectionID)
    }

    public func events(
        connectionID: String,
        binding: StoredCalendarBinding,
        from start: Date,
        through end: Date,
        useIncrementalRefresh: Bool = true
    ) async throws -> ProviderEventPage {
        let tokens = try await validTokens(connectionID: connectionID)
        let scope = cursorScope(start: start, end: end)
        let deltaLink = useIncrementalRefresh
            ? try state.cursor(
                connectionID: connectionID,
                calendarBindingID: binding.id,
                scopeKey: scope
            )
            : nil

        let page: ProviderEventPage
        let refreshMode: ProviderRefreshMode
        do {
            page = try await graph.events(
                accessToken: tokens.accessToken,
                connectionID: connectionID,
                calendarID: binding.providerCalendarID,
                from: start,
                through: end,
                deltaLink: deltaLink,
                responseIdentityScope: binding.responseIdentityScope
            )
            refreshMode = deltaLink == nil ? .full : .incremental
        } catch ProviderFailure.cursorExpired {
            page = try await graph.events(
                accessToken: tokens.accessToken,
                connectionID: connectionID,
                calendarID: binding.providerCalendarID,
                from: start,
                through: end,
                responseIdentityScope: binding.responseIdentityScope
            )
            refreshMode = .full
        }

        // The delta feed used above doesn't request extensions data (unlike
        // `managedEvents`, which asks Graph to $expand it), so marker
        // information isn't present on these events directly. Managed
        // mirrors are instead identified with a second call that does
        // request extensions, and cross-referenced here by event ID.
        let managedEventIDs = Set(
            try await graph.managedEvents(
                accessToken: tokens.accessToken,
                calendarID: binding.providerCalendarID,
                from: start,
                through: end
            )
            .filter { $0.markerStatus != .absent }
            .map(\.providerEventID)
        )
        let events = page.events.map { event in
            managedEventIDs.contains(event.eventID)
                ? event.markingManagedMirror()
                : event
        }

        var cursorUpdates: [ProviderCursorUpdate] = []
        if let nextDeltaLink = page.nextSyncToken {
            cursorUpdates.append(
                ProviderCursorUpdate(
                    scopeKey: scope,
                    value: nextDeltaLink,
                    scopeStart: start,
                    scopeEnd: end
                )
            )
        }
        return ProviderEventPage(
            events: events,
            nextSyncToken: page.nextSyncToken,
            refreshMode: refreshMode,
            cursorUpdates: cursorUpdates,
            readIsComplete: page.readIsComplete != false
        )
    }

    public func createManagedEvent(
        connectionID: String,
        binding: StoredCalendarBinding,
        request: ManagedEventWriteRequest
    ) async throws -> ManagedEventWriteResult {
        let tokens = try await validTokens(connectionID: connectionID)
        return try await graph.createManagedEvent(
            accessToken: tokens.accessToken,
            calendarID: binding.providerCalendarID,
            request: request
        )
    }

    public func managedEvents(
        connectionID: String,
        binding: StoredCalendarBinding,
        from start: Date,
        through end: Date
    ) async throws -> [ManagedEventSnapshot] {
        let tokens = try await validTokens(connectionID: connectionID)
        return try await graph.managedEvents(
            accessToken: tokens.accessToken,
            calendarID: binding.providerCalendarID,
            from: start,
            through: end
        )
    }

    public func updateManagedEvent(
        connectionID: String,
        binding: StoredCalendarBinding,
        providerEventID: String,
        expectedVersion: String?,
        request: ManagedEventWriteRequest
    ) async throws -> ManagedEventWriteResult {
        let tokens = try await validTokens(connectionID: connectionID)
        return try await graph.updateManagedEvent(
            accessToken: tokens.accessToken,
            calendarID: binding.providerCalendarID,
            providerEventID: providerEventID,
            expectedVersion: expectedVersion,
            request: request
        )
    }

    public func deleteManagedEvent(
        connectionID: String,
        binding: StoredCalendarBinding,
        providerEventID: String,
        expectedVersion: String?
    ) async throws {
        let tokens = try await validTokens(connectionID: connectionID)
        try await graph.deleteManagedEvent(
            accessToken: tokens.accessToken,
            calendarID: binding.providerCalendarID,
            providerEventID: providerEventID,
            expectedVersion: expectedVersion
        )
    }

    public func disconnect(connectionID: String) throws {
        try tokenVault.remove(provider: Self.provider, connectionID: connectionID)
        try state.removeConnection(id: connectionID)
    }

    private func validTokens(connectionID: String) async throws -> OAuthTokens {
        guard var tokens = try tokenVault.tokens(provider: Self.provider, connectionID: connectionID) else {
            throw ProviderFailure.authorizationRequired
        }
        if tokens.expiresAt <= now().addingTimeInterval(60) {
            tokens = try await oauth.refresh(tokens)
            try tokenVault.save(tokens, provider: Self.provider, connectionID: connectionID)
        }
        return tokens
    }

    private func stableBindingID(connectionID: String, calendarID: String) -> String {
        let input = Data("microsoft-binding-v1|\(connectionID)|\(calendarID)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private func cursorScope(start: Date, end: Date) -> String {
        let window = "\(start.timeIntervalSinceReferenceDate.bitPattern)|\(end.timeIntervalSinceReferenceDate.bitPattern)"
        let digest = SHA256.hash(data: Data(window.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(Self.deltaScope).\(digest)"
    }
}
