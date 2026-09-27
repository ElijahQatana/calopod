import CalopodProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Endpoints and client identity for one Microsoft Entra (Azure AD) app
/// registration. `tenant` selects which directory can sign in — `"common"`
/// (the default) allows both personal Microsoft accounts and any work/school
/// account.
public struct MicrosoftOAuthConfiguration: Sendable {
    public let clientID: String
    public let tenant: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    public init(
        clientID: String,
        tenant: String = "common",
        authorityBaseURL: URL = URL(string: "https://login.microsoftonline.com")!
    ) {
        self.clientID = clientID
        self.tenant = tenant
        authorizationEndpoint = authorityBaseURL
            .appendingPathComponent(tenant, isDirectory: true)
            .appendingPathComponent("oauth2/v2.0/authorize")
        tokenEndpoint = authorityBaseURL
            .appendingPathComponent(tenant, isDirectory: true)
            .appendingPathComponent("oauth2/v2.0/token")
    }
}

/// Runs the Microsoft identity platform's OAuth authorization-code flow (via
/// PKCE) and refreshes access tokens. `offline_access` is requested
/// explicitly — unlike Google, Microsoft only issues a refresh token when a
/// scope asks for one.
public struct MicrosoftOAuthClient: Sendable {
    public static let scopes = [
        "offline_access",
        "https://graph.microsoft.com/Calendars.ReadWrite",
    ]

    private let configuration: MicrosoftOAuthConfiguration
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        configuration: MicrosoftOAuthConfiguration,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    public func authorize(using browser: any BrowserAuthorizationSession) async throws -> OAuthTokens {
        try validateConfiguration()
        let pkce = PKCEPair.generate()
        let result = try await browser.authorize { context in
            var components = URLComponents(
                url: configuration.authorizationEndpoint,
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "redirect_uri", value: context.redirectURI.absoluteString),
                URLQueryItem(name: "response_mode", value: "query"),
                URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: context.state),
                URLQueryItem(name: "prompt", value: "select_account"),
            ]
            guard let url = components?.url else {
                throw ProviderFailure.invalidResponse
            }
            return url
        }

        return try await exchangeCode(
            result.code,
            redirectURI: result.redirectURI,
            verifier: pkce.verifier
        )
    }

    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        try validateConfiguration()
        let response = try await tokenRequest([
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "scope": Self.scopes.joined(separator: " "),
        ])
        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(MicrosoftTokenResponse.self, from: response.body),
              let expiresIn = payload.expiresIn else {
            throw tokenFailure(response, refreshing: true)
        }

        // Microsoft may rotate the refresh token on any refresh call; when it
        // does, the new one must replace the stored one or the next refresh
        // will fail with an already-invalidated token.
        if let replacementRefreshToken = payload.refreshToken {
            return OAuthTokens(
                accessToken: payload.accessToken,
                refreshToken: replacementRefreshToken,
                tokenType: payload.tokenType ?? tokens.tokenType,
                scope: payload.scope ?? tokens.scope,
                expiresAt: now().addingTimeInterval(TimeInterval(expiresIn))
            )
        }
        return tokens.replacingAccessToken(
            payload.accessToken,
            tokenType: payload.tokenType ?? tokens.tokenType,
            scope: payload.scope,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    private func exchangeCode(
        _ code: String,
        redirectURI: URL,
        verifier: String
    ) async throws -> OAuthTokens {
        let response = try await tokenRequest([
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI.absoluteString,
            "scope": Self.scopes.joined(separator: " "),
        ])
        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(MicrosoftTokenResponse.self, from: response.body),
              let refreshToken = payload.refreshToken,
              let expiresIn = payload.expiresIn else {
            throw tokenFailure(response, refreshing: false)
        }
        return OAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: refreshToken,
            tokenType: payload.tokenType ?? "Bearer",
            scope: payload.scope,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    // The tenant value is interpolated directly into the authorize and token
    // endpoint URLs, so it's restricted to a safe character set here rather
    // than trusted as opaque configuration.
    private func validateConfiguration() throws {
        guard !configuration.clientID.isEmpty else {
            throw ProviderFailure.configurationMissing("Microsoft OAuth client ID")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !configuration.tenant.isEmpty,
              configuration.tenant.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ProviderFailure.configurationMissing("Microsoft tenant")
        }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(fields)
        return try await transport.send(request)
    }

    // Distinguishes "the organization's Conditional Access policy requires
    // more from the user" (MFA, device compliance, re-consent) from an
    // ordinary auth failure, since the former needs a specific "go do this
    // in your account" message rather than a generic re-authorize prompt.
    private func tokenFailure(_ response: HTTPResponse, refreshing: Bool) -> ProviderFailure {
        let payload = try? JSONDecoder().decode(MicrosoftOAuthError.self, from: response.body)
        if payload?.error == "interaction_required"
            || payload?.error == "consent_required"
            || payload?.suberror == "basic_action"
            || payload?.suberror == "additional_action"
            || payload?.suberror == "consent_required"
        {
            return .accountPolicyRequired
        }
        if response.statusCode == 429 || response.statusCode >= 500 {
            return .temporaryFailure(
                retryAfterSeconds: response.headers["retry-after"].flatMap(Int.init)
            )
        }
        if refreshing, payload?.error == "invalid_grant" {
            return .refreshRejected
        }
        if response.statusCode == 400 || response.statusCode == 401 {
            return .authorizationRequired
        }
        return .httpStatus(response.statusCode)
    }
}

private struct MicrosoftTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let tokenType: String?
    let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case scope
    }
}

private struct MicrosoftOAuthError: Decodable {
    let error: String?
    let suberror: String?
}
