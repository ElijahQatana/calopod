import CalopodStore
import Foundation

/// An OAuth token pair for one connection. Kept in the Keychain via `OAuthTokenVault`, never
/// SQLite.
public struct OAuthTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    public let scope: String?
    public let expiresAt: Date

    public init(
        accessToken: String,
        refreshToken: String,
        tokenType: String,
        scope: String?,
        expiresAt: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
    }

    public func replacingAccessToken(
        _ accessToken: String,
        tokenType: String,
        scope: String?,
        expiresAt: Date
    ) -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            scope: scope ?? self.scope,
            expiresAt: expiresAt
        )
    }
}

/// Keychain storage for OAuth tokens, keyed by provider and connection.
public struct OAuthTokenVault: Sendable {
    private let secretStore: any SecretStore

    public init(secretStore: any SecretStore) {
        self.secretStore = secretStore
    }

    public func save(_ tokens: OAuthTokens, provider: String, connectionID: String) throws {
        let encoded = try JSONEncoder().encode(tokens)
        try secretStore.save(encoded, for: reference(provider: provider, connectionID: connectionID))
    }

    public func tokens(provider: String, connectionID: String) throws -> OAuthTokens? {
        guard let encoded = try secretStore.value(
            for: reference(provider: provider, connectionID: connectionID)
        ) else {
            return nil
        }
        return try JSONDecoder().decode(OAuthTokens.self, from: encoded)
    }

    public func remove(provider: String, connectionID: String) throws {
        try secretStore.removeValue(for: reference(provider: provider, connectionID: connectionID))
    }

    private func reference(provider: String, connectionID: String) -> SecretReference {
        SecretReference(account: "oauth.\(provider).\(connectionID)")
    }
}
