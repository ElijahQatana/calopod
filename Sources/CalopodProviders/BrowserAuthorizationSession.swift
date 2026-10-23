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

/// Runs an OAuth flow in the system browser so the user signs in where they already are. `makeURL`
/// builds the authorize URL once the redirect URI is known.
public protocol BrowserAuthorizationSession: Sendable {
    func authorize(
        makeURL: @escaping @Sendable (BrowserAuthorizationContext) throws -> URL
    ) async throws -> BrowserAuthorizationResult
}

#if os(macOS)
import AppKit
import Network

/// Opens the browser and receives the redirect on a one-shot listener on an ephemeral loopback
/// port.
public final class LoopbackBrowserAuthorizationSession: BrowserAuthorizationSession, @unchecked Sendable {
    private let timeoutSeconds: UInt64
    private let redirectHost: String
    private let callbackPath: String
    private let openURL: @Sendable (URL) -> Bool

    public init(
        timeoutSeconds: UInt64 = 300,
        redirectHost: String = "127.0.0.1",
        callbackPath: String = "/oauth/callback",
        openURL: @escaping @Sendable (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.openURL = openURL
        self.timeoutSeconds = timeoutSeconds
        self.redirectHost = redirectHost
        self.callbackPath = callbackPath.hasPrefix("/") ? callbackPath : "/\(callbackPath)"
    }

    public func authorize(
        makeURL: @escaping @Sendable (BrowserAuthorizationContext) throws -> URL
    ) async throws -> BrowserAuthorizationResult {
        let cancellation = CancellationLink()
        return try await withTaskCancellationHandler {
            try await listen(makeURL: makeURL, cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func listen(
        makeURL: @escaping @Sendable (BrowserAuthorizationContext) throws -> URL,
        cancellation: CancellationLink
    ) async throws -> BrowserAuthorizationResult {
        let redirectHost = self.redirectHost
        let callbackPath = self.callbackPath
        let openURL = self.openURL
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
                cancellation.attach(coordinator)

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
                                if !openURL(url) {
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
                        // Anything that is not the real callback is answered and
                        // dropped, so a stray local connection cannot end the flow.
                        guard error == nil,
                              let data,
                              let values = Self.callbackValues(
                                  in: data,
                                  redirectHost: redirectHost,
                                  callbackPath: callbackPath,
                                  state: state
                              ),
                              let redirectURI = coordinator.redirectURI else {
                            Self.reply("404 Not Found", body: "Not found.", on: connection)
                            return
                        }

                        Self.reply(
                            "200 OK",
                            body: "Authorization received. You can close this tab.",
                            on: connection
                        )

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
    /// Returns the query values of a callback request whose `state` matches, or nil. Requiring
    /// `state` stops unrelated requests being taken as the result. Repeated keys keep the first
    /// value.
    static func callbackValues(
        in request: Data,
        redirectHost: String,
        callbackPath: String,
        state: String
    ) -> [String: String]? {
        guard let text = String(data: request, encoding: .utf8),
              let target = text.split(separator: " ").dropFirst().first,
              let url = URL(string: "http://\(redirectHost)\(target)"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == callbackPath else {
            return nil
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        return values["state"] == state ? values : nil
    }

    private static func reply(_ status: String, body: String, on connection: NWConnection) {
        let response = """
            HTTP/1.1 \(status)\r
            Content-Type: text/plain; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }
}

/// Lets a cancelled task end the flow even though the listener lives on its own queue. The task can
/// be cancelled before the coordinator exists, so a cancel that comes first is applied on attach.
private final class CancellationLink: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinator: AuthorizationCoordinator?
    private var cancelled = false

    func attach(_ coordinator: AuthorizationCoordinator) {
        let alreadyCancelled = lock.withLock {
            self.coordinator = coordinator
            return cancelled
        }
        if alreadyCancelled { coordinator.finish(.failure(CancellationError())) }
    }

    func cancel() {
        let coordinator = lock.withLock {
            cancelled = true
            return self.coordinator
        }
        coordinator?.finish(.failure(CancellationError()))
    }
}

/// Guards the single continuation. The callback, a listener failure and the timeout can race; only
/// the first counts.
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
