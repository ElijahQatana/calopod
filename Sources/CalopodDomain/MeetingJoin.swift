import Foundation

/// Opens one URL. The Mac app and the command line each supply their own, so tests can record the calls.
public protocol MeetingURLOpening: Sendable {
    /// Whether an app is known to handle the URL's scheme. Openers that cannot tell answer true and report failure from `open`.
    func hasHandler(for url: URL) -> Bool
    /// Opens the URL and says whether it worked.
    func open(_ url: URL) async -> Bool
}

public enum MeetingJoinResult: Equatable, Sendable {
    case openedApp
    case openedWeb
    case failed
}

public protocol MeetingJoining: Sendable {
    func join(_ link: MeetingLink) async -> MeetingJoinResult
}

/// Tries the meeting app first, then the web link. It opens nothing but the two URLs of the link it is given.
public struct MeetingJoiner: MeetingJoining {
    private let opener: any MeetingURLOpening

    public init(opener: any MeetingURLOpening) {
        self.opener = opener
    }

    public func join(_ link: MeetingLink) async -> MeetingJoinResult {
        if let app = link.appURL, opener.hasHandler(for: app), await opener.open(app) { return .openedApp }
        return await opener.open(link.webURL) ? .openedWeb : .failed
    }
}

public enum MeetingJoinText {
    public static let failed = "The meeting link could not be opened."
}
