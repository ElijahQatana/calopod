import CalopodStore
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
        // Loading the detail runs off the main actor, so under load it can take a while.
        let deadline = ContinuousClock.now + .seconds(10)
        while model.detail == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
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
        XCTAssertTrue(model.noticeIsHint)
        XCTAssertTrue(try XCTUnwrap(model.notice).hasPrefix("Calendar is open. Look for “"))
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

    func testTheHintNamesTheEventAndItsDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        calendar.locale = Locale(identifier: "en_US")
        let day = Date(timeIntervalSinceReferenceDate: 86_400 * 3 + 43_200)
        XCTAssertEqual(
            CalendarOpenText.hint(title: "Planning", startsAt: day, calendar: calendar),
            "Calendar is open. Look for “Planning” on Thursday, January 4.")
    }

    func testCalendarThatCannotStartShowsAProblemNotAHint() async throws {
        let (model, _) = try await detail("eventkit", Opener(.unavailable))
        model.openInCalendar()
        XCTAssertEqual(model.notice, CalendarOpenText.unavailable)
        XCTAssertFalse(model.noticeIsHint)
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

    func testTheReviewMarksItOpenedAndShowsTheHint() async throws {
        let f = try MacFixture(count: 1, provider: "eventkit")
        let model = InboxReviewModel(service: f.review, calendar: Opener(.opened))
        model.open(filter: .all)
        await model.begin()
        await model.perform(.openCalendar)
        XCTAssertNotNil(model.openedKey)
        XCTAssertTrue(try XCTUnwrap(model.notice).hasPrefix("Calendar is open."))
    }

    func testOpeningUsesTheSourceEventNotItsManagedCopy() async throws {
        let f = try MacFixture(count: 1, provider: "eventkit")
        try f.state.replaceCalendarBindings(connectionID: "c", bindings: [
            StoredCalendarBinding(id: "cal", connectionID: "c", providerCalendarID: "primary", displayLabel: "Calendar",
                                  isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser),
            StoredCalendarBinding(id: "full", connectionID: "c", providerCalendarID: "fullcal", displayLabel: "fullcal",
                                  isSelected: true, isReadOnly: false, responseIdentityScope: .authenticatedUser),
        ])
        // A Busy copy with the same title and time sits on another calendar, with its own id.
        var copy = event("copy0", start: 10_000, title: "Example key0", response: .accepted)
        copy = StoredNormalizedInstance(
            sourceKeyHash: "copy0", connectionID: "c", calendarBindingID: "full", providerEventID: "copy-id",
            recurrenceID: nil, startsAt: copy.startsAt, endsAt: copy.endsAt, isAllDay: false, availability: "busy",
            isCancelled: false, isPrivate: false, title: copy.title, contentFingerprint: "copy", providerUpdatedAt: nil,
            organizer: nil, currentUserResponse: copy.currentUserResponse)
        try f.state.applyEventRefresh(connectionID: "c", calendarBindingID: "full", windowStart: f.window.start,
                                      windowEnd: f.window.end, instances: [copy], cancelledSourceKeyHashes: [],
                                      isFullRefresh: true, cursorUpdates: [])
        let opener = Opener(.opened)
        let model = InboxModel(service: f.inbox, calendar: opener)
        await model.reload()
        model.selection = "key0"
        let deadline = ContinuousClock.now + .seconds(10)
        while model.detail == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        model.openInCalendar()
        XCTAssertEqual(opener.opened, ["key0"])
    }

    func testTheLinkNamesOnlyTheEventID() {
        XCTAssertEqual(
            CalendarEventLink.url(eventID: "AB/12:x")?.absoluteString,
            "ical://ekevent/AB%2F12:x?method=show&options=more")
        XCTAssertNil(CalendarEventLink.url(eventID: ""))
    }
}
