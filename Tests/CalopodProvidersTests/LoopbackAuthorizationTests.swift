import Foundation
import Testing

@testable import CalopodProviders

#if os(macOS)
@Suite("Loopback authorization")
struct LoopbackAuthorizationTests {
    private func authorizeWhileSending(
        timeout: UInt64 = 20,
        _ requests: @escaping @Sendable (_ redirect: URL, _ state: String) async -> [String]
    ) async -> Result<BrowserAuthorizationResult, ProviderFailure> {
        let session = LoopbackBrowserAuthorizationSession(timeoutSeconds: timeout, openURL: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = URL(string: items.first { $0.name == "redirect_uri" }!.value!)!
            let state = items.first { $0.name == "state" }!.value!
            Task {
                for target in await requests(redirect, state) {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(redirect.port!)\(target)")!)
                    request.timeoutInterval = 5
                    _ = try? await URLSession.shared.data(for: request)
                }
            }
            return true
        })
        do {
            return .success(try await session.authorize { context in
                URL(string: "https://example.com/authorize?redirect_uri=\(context.redirectURI.absoluteString)&state=\(context.state)")!
            })
        } catch {
            return .failure(error as? ProviderFailure ?? .invalidResponse)
        }
    }

    @Test("Stray requests are ignored until the valid callback arrives")
    func ignoresStrayRequests() async throws {
        let result = await authorizeWhileSending { _, state in
            [
                "/oauth/callback?state=a&state=b&code=x",
                "/favicon.ico",
                "/oauth/callback?state=wrong&code=x",
                "/oauth/callback?%zz",
                "/oauth/callback?state=\(state)&state=other&code=good",
            ]
        }
        let value = try result.get()
        #expect(value.code == "good")
    }

    @Test("A denied consent still reports its failure")
    func consentDenied() async {
        let result = await authorizeWhileSending { _, state in
            ["/other", "/oauth/callback?state=\(state)&error=access_denied"]
        }
        #expect(result.failureValue == .consentDenied)
    }

    @Test("The timeout still reports authorization required")
    func timeout() async {
        let result = await authorizeWhileSending(timeout: 1) { _, _ in ["/favicon.ico"] }
        #expect(result.failureValue == .authorizationRequired)
    }

    @Test("Callback parsing", arguments: [
        ("GET /oauth/callback?state=s&code=c HTTP/1.1\r\n", true),
        ("GET /oauth/callback?state=t&code=c HTTP/1.1\r\n", false),
        ("GET /elsewhere?state=s HTTP/1.1\r\n", false),
        ("", false),
        ("GET", false),
    ])
    func parsing(request: String, accepted: Bool) {
        let values = LoopbackBrowserAuthorizationSession.callbackValues(
            in: Data(request.utf8), redirectHost: "127.0.0.1", callbackPath: "/oauth/callback", state: "s"
        )
        #expect((values != nil) == accepted)
    }
}

private extension Result where Failure == ProviderFailure {
    var failureValue: ProviderFailure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
#endif
