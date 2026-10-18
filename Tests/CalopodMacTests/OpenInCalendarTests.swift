import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class OpenInCalendarTests: XCTestCase {
    private final class Opener: CalendarOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        let result: CalendarOpenResult
        init(_ result: CalendarOpenResult) { self.result = result }
        var opened: [String] { lock.withLock { ids } }
        func open(eventID: String, startsAt: Date) -> CalendarOpenResult {
            lock.withLock { ids.append(eventID) }
            return result
        }
    }

    private func detail(_ provider: String, _ opener: CalendarOpening = Opener(.opened)) async throws -> (InboxModel, InboxDetail) {
        let f = try MacFixture(count: 1, provider: provider)
        let model = InboxModel(service: f.inbox, calendar: opener)
        await model.reload()
        model.selection = "key0"
        for _ in 0..<50 where model.detail == nil { await Task.yield() }
        return (model, try XCTUnwrap(model.detail))
    }

    func testOnlyAppleCalendarInvitationsOfferTheButton() async throws {
        let (_, apple) = try await detail("eventkit")
        XCTAssertTrue(apple.canOpenInCalendar)
        for provider in ["google", "microsoft"] {
            let (_, other) = try await detail(provider)
            XCTAssertFalse(other.canOpenInCalendar, provider)
        }
    }

    func testOpeningDoesNotAnswerOrClearNeedsRSVP() async throws {
        let opener = Opener(.opened)
        let (model, before) = try await detail("eventkit", opener)
        model.openInCalendar()
        XCTAssertEqual(opener.opened, ["key0"])
        XCTAssertNil(model.notice)
        await model.reload()
        XCTAssertEqual(model.board?.entries.first?.reasons, before.entry.reasons)
        XCTAssertTrue(before.entry.reasons.contains(.needsResponse))
    }

    func testAMissingEventShowsAMessage() async throws {
        let (model, _) = try await detail("eventkit", Opener(.notFound))
        model.openInCalendar()
        XCTAssertEqual(model.notice, CalendarOpenText.notFound)
        model.dismissNotice()
        XCTAssertNil(model.notice)
    }

    func testTheReviewShowsTheMessageAndDoesNotMarkItOpened() async throws {
        let f = try MacFixture(count: 1, provider: "eventkit")
        let model = InboxReviewModel(service: f.review, calendar: Opener(.notFound))
        model.open(filter: .all)
        await model.begin()
        await model.perform(.openCalendar)
        XCTAssertEqual(model.notice, CalendarOpenText.notFound)
        XCTAssertNil(model.openedKey)
    }
}
