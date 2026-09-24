import Foundation

public struct BrowserAuthorizationContext: Sendable {
    public let redirectURI: URL
    public let state: String

    public init(redirectURI: URL, state: String) {
        self.redirectURI = redirectURI
        self.state = state
    }
}

public struct BrowserAuthorizationResult: Sendable {
    public let code: String
    public let redirectURI: URL

    public init(code: String, redirectURI: URL) {
        self.code = code
        self.redirectURI = redirectURI
    }
}

public protocol BrowserAuthorizationSession: Sendable {
    func authorize(
        makeURL: @escaping @Sendable (BrowserAuthorizationContext) throws -> URL
    ) async throws -> BrowserAuthorizationResult
}

#if os(macOS)
import AppKit
import Network

public final class LoopbackBrowserAuthorizationSession: BrowserAuthorizationSession, @unchecked Sendable {
    private let timeoutSeconds: UInt64
    private let redirectHost: String
    private let callbackPath: String

    public init(
        timeoutSeconds: UInt64 = 300,
        redirectHost: String = "127.0.0.1",
        callbackPath: String = "/oauth/callback"
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.redirectHost = redirectHost
        self.callbackPath = callbackPath.hasPrefix("/") ? callbackPath : "/\(callbackPath)"
    }

    public func authorize(
        makeURL: @escaping @Sendable (BrowserAuthorizationContext) throws -> URL
    ) async throws -> BrowserAuthorizationResult {
        let redirectHost = self.redirectHost
        let callbackPath = self.callbackPath
        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "com.calopod.oauth-loopback")
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

            do {
                let listener = try NWListener(using: parameters)
                let state = UUID().uuidString
                let coordinator = AuthorizationCoordinator(
                    listener: listener,
                    continuation: continuation
                )

                listener.stateUpdateHandler = { listenerState in
                    switch listenerState {
                    case .ready:
                        guard let port = listener.port,
                              let callback = URL(
                                string: "http://\(redirectHost):\(port.rawValue)\(callbackPath)"
                              ) else {
                            coordinator.finish(.failure(ProviderFailure.invalidResponse))
                            return
                        }
                        coordinator.redirectURI = callback
                        do {
                            let url = try makeURL(
                                BrowserAuthorizationContext(redirectURI: callback, state: state)
                            )
                            DispatchQueue.main.async {
                                if !NSWorkspace.shared.open(url) {
                                    coordinator.finish(.failure(ProviderFailure.authorizationRequired))
                                }
                            }
                        } catch {
                            coordinator.finish(.failure(error))
                        }

                    case let .failed(error):
                        coordinator.finish(.failure(error))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }

                listener.newConnectionHandler = { connection in
                    connection.start(queue: queue)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
                        data, _, _, error in
                        if let error {
                            coordinator.finish(.failure(error))
                            return
                        }
                        guard let data,
                              let request = String(data: data, encoding: .utf8),
                              let target = request.split(separator: " ").dropFirst().first,
                              let callback = URL(string: "http://\(redirectHost)\(target)"),
                              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
                              components.path == callbackPath,
                              let redirectURI = coordinator.redirectURI else {
                            coordinator.finish(.failure(ProviderFailure.invalidResponse))
                            return
                        }

                        let values = Dictionary(
                            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
                        )
                        let responseBody = "Authorization received. You can close this tab."
                        let response = """
                            HTTP/1.1 200 OK\r
                            Content-Type: text/plain; charset=utf-8\r
                            Content-Length: \(responseBody.utf8.count)\r
                            Connection: close\r
                            \r
                            \(responseBody)
                            """
                        connection.send(
                            content: Data(response.utf8),
                            completion: .contentProcessed { _ in connection.cancel() }
                        )

                        guard values["state"] == state else {
                            coordinator.finish(.failure(ProviderFailure.invalidResponse))
                            return
                        }
                        if values["error"] == "access_denied" {
                            coordinator.finish(.failure(ProviderFailure.consentDenied))
                            return
                        }
                        if values["error"] == "interaction_required"
                            || values["error"] == "login_required"
                            || values["error"] == "consent_required"
                        {
                            coordinator.finish(.failure(ProviderFailure.accountPolicyRequired))
                            return
                        }
                        guard let code = values["code"], !code.isEmpty else {
                            coordinator.finish(.failure(ProviderFailure.invalidResponse))
                            return
                        }
                        coordinator.finish(
                            .success(BrowserAuthorizationResult(code: code, redirectURI: redirectURI))
                        )
                    }
                }

                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) {
                    coordinator.finish(.failure(ProviderFailure.authorizationRequired))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class AuthorizationCoordinator: @unchecked Sendable {
    private let listener: NWListener
    private let continuation: CheckedContinuation<BrowserAuthorizationResult, any Error>
    private let lock = NSLock()
    private var completed = false
    private var storedRedirectURI: URL?

    init(
        listener: NWListener,
        continuation: CheckedContinuation<BrowserAuthorizationResult, any Error>
    ) {
        self.listener = listener
        self.continuation = continuation
    }

    var redirectURI: URL? {
        get { lock.withLock { storedRedirectURI } }
        set { lock.withLock { storedRedirectURI = newValue } }
    }

    func finish(_ result: Result<BrowserAuthorizationResult, any Error>) {
        let shouldFinish = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldFinish else { return }
        listener.cancel()
        continuation.resume(with: result)
    }
}
#endif
