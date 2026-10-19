import CalopodDomain
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

final class NextJoinTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let teams = MeetingLink.first(in: "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0")

    private func event(start: Double, minutes: Double = 30, link: Bool = true, copy: Bool = false) -> ScheduleEvent {
        ScheduleEvent(
            id: "e", calendarID: "c", title: "Planning",
            startsAt: now.addingTimeInterval(start * 60), endsAt: now.addingTimeInterval((start + minutes) * 60),
            isCopy: copy, meeting: link ? teams : nil)
    }

    func testWhichEventsOfferJoin() {
        XCTAssertNotNil(JoinOffer.link(for: event(start: 5), now: now))
        XCTAssertNotNil(JoinOffer.link(for: event(start: -10), now: now))
        XCTAssertNotNil(JoinOffer.link(for: event(start: 600), now: now))
        XCTAssertNil(JoinOffer.link(for: event(start: 5, link: false), now: now))
        XCTAssertNil(JoinOffer.link(for: event(start: 5, copy: true), now: now))
        XCTAssertNil(JoinOffer.link(for: event(start: -60), now: now))
    }

    func testEmphasisWindow() {
        XCTAssertTrue(JoinOffer.isProminent(event(start: -10), now: now))
        XCTAssertTrue(JoinOffer.isProminent(event(start: 10), now: now))
        XCTAssertFalse(JoinOffer.isProminent(event(start: 11), now: now))
        XCTAssertFalse(JoinOffer.isProminent(event(start: 120), now: now))
        XCTAssertFalse(JoinOffer.isProminent(event(start: -60), now: now))
    }

    private final class Opener: MeetingURLOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        let works: Bool
        init(works: Bool) { self.works = works }
        var opened: [URL] { lock.withLock { urls } }
        func hasHandler(for url: URL) -> Bool { true }
        func open(_ url: URL) async -> Bool {
            lock.withLock { urls.append(url) }
            return works
        }
    }

    func testJoinOpensTheAppLinkThroughTheOpener() async throws {
        let link = try XCTUnwrap(JoinOffer.link(for: event(start: 5), now: now))
        let opener = Opener(works: true)
        let notice = await JoinOffer.join(link, using: MeetingJoiner(opener: opener))
        XCTAssertNil(notice)
        XCTAssertEqual(opener.opened, [try XCTUnwrap(link.appURL)])
    }

    func testAFailedOpenGivesTheBannerText() async throws {
        let link = try XCTUnwrap(JoinOffer.link(for: event(start: 5), now: now))
        let opener = Opener(works: false)
        let notice = await JoinOffer.join(link, using: MeetingJoiner(opener: opener))
        XCTAssertEqual(notice, MeetingJoinText.failed)
        XCTAssertEqual(opener.opened.last, link.webURL)
    }
}
