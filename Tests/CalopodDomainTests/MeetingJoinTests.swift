import CalopodDomain
import Foundation
import Testing

private final class RecordingOpener: MeetingURLOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    let handler: Bool
    let succeeds: (URL) -> Bool

    init(handler: Bool = true, succeeds: @escaping (URL) -> Bool = { _ in true }) {
        self.handler = handler
        self.succeeds = succeeds
    }

    var opened: [String] { lock.withLock { urls.map(\.absoluteString) } }
    func hasHandler(for url: URL) -> Bool { handler }
    func open(_ url: URL) async -> Bool {
        lock.withLock { urls.append(url) }
        return succeeds(url)
    }
}

@Suite("Joining a meeting")
struct MeetingJoinTests {
    private let zoom = MeetingLink.first(in: "https://zoom.us/j/123456789?pwd=abc")!
    private let meet = MeetingLink.first(in: "https://meet.google.com/abc-defg-hij")!

    @Test("The app is tried first and nothing else is opened")
    func appFirst() async {
        let opener = RecordingOpener()
        let result = await MeetingJoiner(opener: opener).join(zoom)
        #expect(result == .openedApp)
        #expect(opener.opened == ["zoommtg://zoom.us/join?confno=123456789&pwd=abc"])
    }

    @Test("Without an app the web link opens")
    func noHandler() async {
        let opener = RecordingOpener(handler: false)
        let result = await MeetingJoiner(opener: opener).join(zoom)
        #expect(result == .openedWeb)
        #expect(opener.opened == ["https://zoom.us/j/123456789?pwd=abc"])
    }

    @Test("When the app does not open, the web link does")
    func appFails() async {
        let opener = RecordingOpener { $0.scheme != "zoommtg" }
        let result = await MeetingJoiner(opener: opener).join(zoom)
        #expect(result == .openedWeb)
        #expect(opener.opened == ["zoommtg://zoom.us/join?confno=123456789&pwd=abc", "https://zoom.us/j/123456789?pwd=abc"])
    }

    @Test("A link without an app goes straight to the browser")
    func webOnly() async {
        let opener = RecordingOpener()
        let result = await MeetingJoiner(opener: opener).join(meet)
        #expect(result == .openedWeb)
        #expect(opener.opened == ["https://meet.google.com/abc-defg-hij"])
    }

    @Test("A failed web open is reported")
    func bothFail() async {
        let opener = RecordingOpener { _ in false }
        #expect(await MeetingJoiner(opener: opener).join(zoom) == .failed)
        #expect(opener.opened.count == 2)
    }
}
