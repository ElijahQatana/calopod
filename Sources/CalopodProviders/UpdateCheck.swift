import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A release number such as 1.0.2 or 1.1.0-rc1. A suffix sorts below the same number without one.
public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    private let numbers: [Int]
    private let suffix: String?
    public let description: String

    public init?(_ text: String) {
        var text = Substring(text.trimmingCharacters(in: .whitespaces))
        if text.hasPrefix("v") { text = text.dropFirst() }
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = halves.first else { return nil }
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), !parts.contains(nil), halves.count < 2 || !halves[1].isEmpty else { return nil }
        numbers = parts.compactMap { $0 } + Array(repeating: 0, count: 3 - parts.count)
        suffix = halves.count == 2 ? String(halves[1]) : nil
        description = String(text)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        switch (lhs.suffix, rhs.suffix) {
        case let (left?, right?): return left < right
        case (_?, nil): return true
        default: return false
        }
    }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        lhs.numbers == rhs.numbers && lhs.suffix == rhs.suffix
    }
}

public enum UpdateResult: Equatable, Sendable {
    case upToDate
    case available(version: String, page: URL)
    case failed(String)
}

/// Asks GitHub for the newest Calopod release. It only reads, and never downloads or installs anything.
public struct UpdateCheck: Sendable {
    static let releasesURL = URL(string: "https://api.github.com/repos/ElijahQatana/calopod/releases?per_page=10")!
    static let pagePrefix = "https://github.com/ElijahQatana/calopod/releases/"

    private struct Release: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
    }

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    public func check(current: String) async -> UpdateResult {
        guard let running = ReleaseVersion(current) else { return .failed("This copy of Calopod has no version number to compare.") }
        var request = URLRequest(url: Self.releasesURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Calopod/\(running)", forHTTPHeaderField: "User-Agent")
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            return .failed("Calopod couldn't reach GitHub.")
        }
        switch response.statusCode {
        case 200..<300: break
        case 403, 429: return .failed("GitHub is limiting requests right now. Try again later.")
        default: return .failed("GitHub answered with an error (\(response.statusCode)). Try again later.")
        }
        guard let releases = try? JSONDecoder().decode([Release].self, from: response.body) else {
            return .failed("GitHub's answer wasn't what Calopod expected.")
        }
        // Only links to this project's own release pages are offered.
        let newest = releases
            .compactMap { release -> (ReleaseVersion, URL)? in
                guard !release.draft, let version = ReleaseVersion(release.tag_name),
                      release.html_url.hasPrefix(Self.pagePrefix), let page = URL(string: release.html_url)
                else { return nil }
                return (version, page)
            }
            .max { $0.0 < $1.0 }
        guard let newest, newest.0 > running else { return .upToDate }
        return .available(version: newest.0.description, page: newest.1)
    }
}
