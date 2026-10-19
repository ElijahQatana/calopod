import CalopodDomain
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class JoinMeetingTests: XCTestCase {
    private final class Joiner: MeetingJoining, @unchecked Sendable {
        private let lock = NSLock()
        private var links: [MeetingLink] = []
        let result: MeetingJoinResult
        init(_ result: MeetingJoinResult) { self.result = result }
        var joined: [MeetingProvider] { lock.withLock { links.map(\.provider) } }
        func join(_ link: MeetingLink) async -> MeetingJoinResult {
            lock.withLock { links.append(link) }
            return result
        }
    }

    private func loaded(url: String?, joiner: Joiner) async throws -> InboxModel {
        let f = try MacFixture(count: 1, url: url)
        let model = InboxModel(service: f.inbox, joiner: joiner)
        await model.reload()
        model.selection = "key0"
        let deadline = ContinuousClock.now + .seconds(10)
        while model.detail == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return model
    }

    func testTheEntryCarriesTheLinkAndJoiningOpensIt() async throws {
        let joiner = Joiner(.openedApp)
        let model = try await loaded(url: "https://zoom.us/j/123456789", joiner: joiner)
        XCTAssertEqual(model.detail?.entry.meeting?.buttonTitle, "Join Zoom")
        await model.joinMeeting()
        XCTAssertEqual(joiner.joined, [.zoom])
        XCTAssertNil(model.notice)
    }

    func testAFailedOpenShowsADismissableNotice() async throws {
        let model = try await loaded(url: "https://meet.google.com/abc-defg-hij", joiner: Joiner(.failed))
        await model.joinMeeting()
        XCTAssertEqual(model.notice, MeetingJoinText.failed)
        XCTAssertFalse(model.noticeIsHint)
        model.dismissNotice()
        XCTAssertNil(model.notice)
    }

    func testAnEventWithoutALinkHasNoJoin() async throws {
        let joiner = Joiner(.openedWeb)
        let model = try await loaded(url: nil, joiner: joiner)
        XCTAssertNil(model.detail?.entry.meeting)
        await model.joinMeeting()
        XCTAssertTrue(joiner.joined.isEmpty)
    }

    func testTheReviewSheetReportsAFailedOpen() async throws {
        let model = InboxReviewModel(joiner: Joiner(.failed))
        let link = try XCTUnwrap(MeetingLink.first(in: "https://example.webex.com/meet/someroom"))
        await model.joinMeeting(link)
        XCTAssertEqual(model.notice, MeetingJoinText.failed)
        model.dismissNotice()
        XCTAssertNil(model.notice)
    }
}
