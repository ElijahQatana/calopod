import CalopodDomain
import CalopodProviders
import CalopodStore
import CryptoKit
import Foundation

/// Manages one Google Connection: authorization, token refresh, calendar discovery and event
/// fetch/write.
public struct GoogleConnectionService: RSVPActionProvider {
    private static let provider = ProviderKind.google.rawValue
    // Two cursors per window: an update watermark for bounded reads, and Google's sync token. They
    // are separate so an expired token can fall back to a full read without losing the watermark.
    private static let boundedWatermarkScope = "google.events.updated-min.v1"
    private static let returnedSyncTokenScope = "google.events.sync-token.v1"

    private let oauth: GoogleOAuthClient
    private let calendarClient: GoogleCalendarClient
    private let tokenVault: OAuthTokenVault
    private let state: LocalStateRepository
    private let now: @Sendable () -> Date

    public init(
        oauth: GoogleOAuthClient,
        calendarClient: GoogleCalendarClient,
        tokenVault: OAuthTokenVault,
        state: LocalStateRepository,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.oauth = oauth
        self.calendarClient = calendarClient
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
            displayLabel: "Google Calendar",
            isEnabled: true
        )
        let tokens = try await oauth.authorize(using: browser)
        try tokenVault.save(tokens, provider: Self.provider, connectionID: connection.id)
        // Tokens are saved before the connection row; if the database write fails they are removed
        // again.
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
        let calendars = try await calendarClient.calendars(accessToken: tokens.accessToken)
        let bindings = calendars.map {
            StoredCalendarBinding(
                id: stableBindingID(connectionID: connectionID, calendarID: $0.id),
                connectionID: connectionID,
                providerCalendarID: $0.id,
                displayLabel: $0.summary,
                isSelected: false,
                isReadOnly: $0.accessRole == "reader" || $0.accessRole == "freeBusyReader",
                responseIdentityScope: $0.primary ? .authenticatedUser : .unverified,
                providerColor: $0.backgroundColor
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
        let requestStartedAt = now()
        let tokens = try await validTokens(connectionID: connectionID)
        let watermarkScope = cursorScope(
            prefix: Self.boundedWatermarkScope,
            start: start,
            end: end
        )
        let syncTokenScope = cursorScope(
            prefix: Self.returnedSyncTokenScope,
            start: start,
            end: end
        )
        let watermark: Date?
        if useIncrementalRefresh {
            watermark = try state.cursor(
                connectionID: connectionID,
                calendarBindingID: binding.id,
                scopeKey: watermarkScope
            ).flatMap(StoredDate.date(from:))
        } else {
            watermark = nil
        }

        let page: ProviderEventPage
        let refreshMode: ProviderRefreshMode
        do {
            page = try await calendarClient.events(
                accessToken: tokens.accessToken,
                connectionID: connectionID,
                calendarID: binding.providerCalendarID,
                from: start,
                through: end,
                updatedSince: watermark,
                responseIdentityScope: binding.responseIdentityScope
            )
            refreshMode = watermark == nil ? .full : .incremental
        } catch ProviderFailure.cursorExpired {
            // A rejected sync token is recovered by a full refresh, which the cache can reconcile.
            page = try await calendarClient.events(
                accessToken: tokens.accessToken,
                connectionID: connectionID,
                calendarID: binding.providerCalendarID,
                from: start,
                through: end,
                responseIdentityScope: binding.responseIdentityScope
            )
            refreshMode = .full
        }

        var cursorUpdates = [
            ProviderCursorUpdate(
                scopeKey: watermarkScope,
                value: StoredDate.string(from: requestStartedAt),
                scopeStart: start,
                scopeEnd: end
            ),
        ]
        if let nextSyncToken = page.nextSyncToken {
            cursorUpdates.append(
                ProviderCursorUpdate(
                    scopeKey: syncTokenScope,
                    value: nextSyncToken,
                    scopeStart: start,
                    scopeEnd: end
                )
            )
        }
        return ProviderEventPage(
            events: page.events,
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
        return try await calendarClient.createManagedEvent(
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
        return try await calendarClient.managedEvents(
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
        return try await calendarClient.updateManagedEvent(
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
        try await calendarClient.deleteManagedEvent(
            accessToken: tokens.accessToken,
            calendarID: binding.providerCalendarID,
            providerEventID: providerEventID,
            expectedVersion: expectedVersion
        )
    }

    public func rsvpSnapshot(target: RSVPTarget) async throws -> RSVPEventSnapshot {
        let (tokens, authorization) = try await rsvpAuthorization(target: target)
        return try await calendarClient.rsvpSnapshot(accessToken: tokens.accessToken, target: target, authorization: authorization)
    }

    public func submitRSVP(_ intent: RSVPActionIntent) async throws {
        let tokens: OAuthTokens
        let authorization: RSVPAuthorization
        do { (tokens, authorization) = try await rsvpAuthorization(target: intent.target) }
        catch { throw RSVPActionError.preflightFailure(error) }
        do {
            try await calendarClient.submitRSVP(accessToken: tokens.accessToken, intent: intent, authorization: authorization)
        } catch {
            if let actionError = error as? RSVPActionError { throw actionError }
            throw RSVPActionError.preflightFailure(error)
        }
    }

    public func reconcileRSVP(_ record: RSVPActionRecord) async throws -> RSVPActionOutcome {
        let (tokens, authorization) = try await rsvpAuthorization(target: record.intent.target)
        return try await calendarClient.reconcileRSVP(accessToken: tokens.accessToken, record: record, authorization: authorization)
    }

    private func rsvpAuthorization(target: RSVPTarget) async throws -> (OAuthTokens, RSVPAuthorization) {
        _ = try state.rsvpBinding(target: target, provider: Self.provider)
        let tokens = try await validTokens(connectionID: target.connectionID)
        let scopes = Set((tokens.scope ?? "").split(separator: " ").map(String.init))
        guard scopes.contains("https://www.googleapis.com/auth/calendar.events") || scopes.contains("https://www.googleapis.com/auth/calendar") else { throw RSVPActionError.unavailable(.permission) }
        let calendars = try await calendarClient.calendars(accessToken: tokens.accessToken)
        guard let calendar = calendars.first(where: { $0.id == target.calendarID }),
              calendar.primary && ["owner", "writer"].contains(calendar.accessRole) else { throw RSVPActionError.unavailable(.permission) }
        return (tokens, RSVPAuthorization(identityScope: .authenticatedUser, canRespond: true))
    }

    public func disconnect(connectionID: String) throws {
        try tokenVault.remove(provider: Self.provider, connectionID: connectionID)
        try state.removeConnection(id: connectionID)
    }

    /// Returns a usable access token, refreshing 60 seconds early rather than waiting for a 401.
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
        let input = Data("google-binding-v1|\(connectionID)|\(calendarID)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    // Cursors are scoped to their window so another date range never reuses them.
    private func cursorScope(prefix: String, start: Date, end: Date) -> String {
        let window = "\(start.timeIntervalSinceReferenceDate.bitPattern)|\(end.timeIntervalSinceReferenceDate.bitPattern)"
        let digest = SHA256.hash(data: Data(window.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(prefix).\(digest)"
    }
}

private enum StoredDate {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(from value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
