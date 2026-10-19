import Foundation

public enum MeetingProvider: String, Codable, CaseIterable, Sendable {
    case teams, zoom, meet, webex

    public var displayName: String {
        switch self {
        case .teams: "Teams"
        case .zoom: "Zoom"
        case .meet: "Meet"
        case .webex: "Webex"
        }
    }
}

/// A video meeting link found in an event. Only https links on a known meeting host are accepted.
public struct MeetingLink: Equatable, Sendable {
    public let provider: MeetingProvider
    public let webURL: URL
    /// The meeting app's own link, when the app has one and it can be built with certainty.
    public let appURL: URL?

    public var buttonTitle: String { "Join \(provider.displayName)" }

    public init(provider: MeetingProvider, webURL: URL, appURL: URL? = nil) {
        self.provider = provider
        self.webURL = webURL
        self.appURL = appURL
    }

    /// The best link for an event: the URL field first, then the location, then the first one in the notes.
    public static func find(url: String?, location: String?, notes: String?) -> MeetingLink? {
        for text in [url, location, notes] {
            if let text, let link = first(in: text) { return link }
        }
        return nil
    }

    /// The first meeting link in free text.
    public static func first(in text: String) -> MeetingLink? {
        // Notes can be long; a link that far down is not worth the scan.
        let limited = text.count > 200_000 ? String(text.prefix(200_000)) : text
        for candidate in candidates(in: limited) {
            if let link = parse(candidate) { return link }
        }
        return nil
    }

    /// Whether Join should stand out: the event is running, started within the past hour, or starts within 12 hours.
    public static func isNear(startsAt: Date, endsAt: Date, now: Date = Date()) -> Bool {
        startsAt <= now.addingTimeInterval(12 * 3600) && (endsAt > now || startsAt >= now.addingTimeInterval(-3600))
    }

    // MARK: Finding links

    private static let separators: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        set.insert(charactersIn: "<>\"'()[]{}|\\")
        return set
    }()

    private static let trailing = CharacterSet(charactersIn: ".,;:!?*")

    /// Link-shaped pieces of the text, in order. Angle brackets, quotes and trailing punctuation are left off,
    /// and a link whose scheme is percent encoded is decoded once.
    static func candidates(in text: String) -> [String] {
        var found: [String] = []
        for token in text.components(separatedBy: separators) where !token.isEmpty {
            guard let start = token.range(of: "https://", options: .caseInsensitive)
                ?? token.range(of: "https%3A", options: .caseInsensitive) else { continue }
            var piece = String(token[start.lowerBound...]).replacingOccurrences(of: "&amp;", with: "&")
            if piece.lowercased().hasPrefix("https%3a") { piece = piece.removingPercentEncoding ?? "" }
            while let last = piece.unicodeScalars.last, trailing.contains(last) { piece.unicodeScalars.removeLast() }
            if !piece.isEmpty { found.append(piece) }
        }
        return found
    }

    // MARK: Checking links

    static func parse(_ candidate: String) -> MeetingLink? {
        guard var parts = URLComponents(string: candidate), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        parts.scheme = "https"
        parts.host = host
        parts.port = nil
        parts.fragment = nil
        let path = parts.path
        let segments = path.split(separator: "/").map(String.init)

        let provider: MeetingProvider
        var appURL: URL?
        if isHost(host, "teams.microsoft.com") && (path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/"))
            || isHost(host, "teams.live.com") && path.hasPrefix("/meet/") {
            provider = .teams
            var app = parts
            app.scheme = "msteams"
            appURL = app.url
        } else if isHost(host, "zoom.us") && ["j", "my", "w"].contains(segments.first ?? "") && segments.count >= 2 {
            provider = .zoom
            if segments[0] == "j", segments[1].allSatisfy(\.isASCIIDigit) {
                var app = URLComponents()
                app.scheme = "zoommtg"
                app.host = host
                app.path = "/join"
                app.queryItems = [URLQueryItem(name: "confno", value: segments[1])]
                    + (parts.queryItems?.first { $0.name == "pwd" }?.value.map { [URLQueryItem(name: "pwd", value: $0)] } ?? [])
                appURL = app.url
            }
        } else if host == "meet.google.com", segments.count == 1, isMeetCode(segments[0]) {
            provider = .meet
        } else if isHost(host, "webex.com"), webexPath(segments) {
            // Webex has an app scheme, but its format is not documented well enough to build one.
            provider = .webex
        } else {
            return nil
        }
        guard let web = parts.url else { return nil }
        return MeetingLink(provider: provider, webURL: web, appURL: appURL)
    }

    /// The host itself or a subdomain of it, never a name that merely contains it.
    private static func isHost(_ host: String, _ known: String) -> Bool {
        host == known || host.hasSuffix("." + known)
    }

    private static func isMeetCode(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.count) == [3, 4, 3] && value.allSatisfy { $0.isASCII && $0.isLowercase || $0 == "-" }
    }

    private static func webexPath(_ segments: [String]) -> Bool {
        guard let first = segments.first else { return false }
        return (["meet", "join", "wbxmjs", "webappng"].contains(first) && segments.count >= 2) || segments.last == "j.php"
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
