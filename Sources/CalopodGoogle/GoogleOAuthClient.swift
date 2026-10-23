import CalopodProviders
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Endpoints and client identity for Google OAuth. Only `clientID` is needed; the defaults are
/// Google's. A Desktop app client also has a secret, which Google asks for at the token endpoint
/// even with PKCE.
public struct GoogleOAuthConfiguration: Sendable {
    public let clientID: String
    public let clientSecret: String?
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL

    public init(
        clientID: String,
        clientSecret: String? = nil,
        authorizationEndpoint: URL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret.flatMap { $0.isEmpty ? nil : $0 }
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
    }
}

/// Runs the Google authorization-code flow (PKCE, system browser) and refreshes tokens. Scopes are
/// limited to the calendar list and events.
public struct GoogleOAuthClient: Sendable {
    public static let scopes = [
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly",
        "https://www.googleapis.com/auth/calendar.events",
    ]

    private let configuration: GoogleOAuthConfiguration
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date

    public init(
        configuration: GoogleOAuthConfiguration,
        transport: any HTTPTransport = URLSessionTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    public func authorize(using browser: any BrowserAuthorizationSession) async throws -> OAuthTokens {
        guard !configuration.clientID.isEmpty else {
            throw ProviderFailure.configurationMissing("Google OAuth client ID")
        }

        // `access_type=offline` with `prompt=consent` makes Google return a refresh token even on
        // repeat consent.
        let pkce = PKCEPair.generate()
        let result = try await browser.authorize { context in
            var components = URLComponents(
                url: configuration.authorizationEndpoint,
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "redirect_uri", value: context.redirectURI.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "code_challenge", value: pkce.challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: context.state),
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

    /// Exchanges a refresh token for an access token. A 400/401 means it was revoked or expired,
    /// surfaced as `.refreshRejected`.
    public func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        let response = try await tokenRequest([
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ])

        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(TokenResponse.self, from: response.body),
              let expiresIn = payload.expiresIn else {
            if response.statusCode == 400 || response.statusCode == 401 {
                throw ProviderFailure.refreshRejected
            }
            throw mapFailure(response)
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
        ])

        guard (200..<300).contains(response.statusCode),
              let payload = try? JSONDecoder().decode(TokenResponse.self, from: response.body),
              let refreshToken = payload.refreshToken,
              let expiresIn = payload.expiresIn else {
            throw mapFailure(response)
        }

        return OAuthTokens(
            accessToken: payload.accessToken,
            refreshToken: refreshToken,
            tokenType: payload.tokenType ?? "Bearer",
            scope: payload.scope,
            expiresAt: now().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> HTTPResponse {
        var fields = fields
        if let secret = configuration.clientSecret { fields["client_secret"] = secret }
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(fields)
        return try await transport.send(request)
    }

    /// Classifies an OAuth failure: 429 and 5xx are retryable, 400/401 mean bad credentials,
    /// anything else passes through.
    private func mapFailure(_ response: HTTPResponse) -> ProviderFailure {
        if response.statusCode == 429 || response.statusCode >= 500 {
            return .temporaryFailure(retryAfterSeconds: retryAfter(response.headers))
        }
        if response.statusCode == 400 || response.statusCode == 401 {
            return .authorizationRequired
        }
        return .httpStatus(response.statusCode)
    }
}

private struct TokenResponse: Decodable {
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

private func retryAfter(_ headers: [String: String]) -> Int? {
    headers["retry-after"].flatMap(Int.init)
}
