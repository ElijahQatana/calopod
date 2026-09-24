import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderFailure.invalidResponse
        }

        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else {
                return
            }
            result[key.lowercased()] = value
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

public enum ProviderFailure: Error, Equatable, Sendable {
    case authorizationRequired
    case configurationMissing(String)
    case consentDenied
    case cursorExpired
    case httpStatus(Int)
    case invalidResponse
    case refreshRejected
    case temporaryFailure(retryAfterSeconds: Int?)
}
