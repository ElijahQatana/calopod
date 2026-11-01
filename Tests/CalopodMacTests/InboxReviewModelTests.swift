import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class InboxReviewModelTests: XCTestCase {
    private final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var days = 0
        var count: Int { lock.withLock { days } }
        func add() { lock.withLock { days += 1 } }
    }

    private struct StubOpener: CalendarOpening {
        let opened: Opened
        func open(eventID: String, startsAt: Date) -> CalendarOpenResult { opened.add(); return .opened }
    }

    private func started(_ f: MacFixture, filter: InboxFilter = .all, opened: Opened = Opened()) async -> InboxReviewModel {
        let model = InboxReviewModel(service: f.review, calendar: StubOpener(opened: opened))
        model.open(filter: filter)
        await model.begin()
        return model
    }

    private func card(_ model: InboxReviewModel, file: StaticString = #filePath, line: UInt = #line) throws -> InboxReviewCardInfo {
        guard case .card(let card) = model.phase else { throw XCTSkip("Not on a card: \(model.phase)") }
        return card
    }

    func testAReplyIsConfirmedBeforeItIsSentThenTheNextCardShows() async throws {
        let f = try MacFixture(count: 2)
        let model = await started(f)
        XCTAssertEqual(try card(model).entry.id, "key0")
        XCTAssertEqual(model.keyboardMode, .card)

        await model.perform(.reply(.yes))
        guard case .confirm(_, .yes) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(model.keyboardMode, .confirm)
        await model.perform(.cancel)
        XCTAssertEqual(try card(model).entry.id, "key0")
        let unsent = await f.remote.writes
        XCTAssertEqual(unsent, 0)

        await model.perform(.reply(.yes))
        await model.perform(.send)
        XCTAssertEqual(try card(model).entry.id, "key1")
        XCTAssertEqual(model.notice, "Reply recorded: Yes.")
        let sent = await f.remote.writes
        XCTAssertEqual(sent, 1)

        await model.perform(.hold)
        guard case .summary = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertNil(model.notice)
        XCTAssertEqual(model.progress?.isFinished, true)
        XCTAssertEqual(model.progress?.totals.yes, 1)
    }

    func testSnoozeAsksForATimeThenMovesOnWithoutSending() async throws {
        let f = try MacFixture(count: 2)
        let model = await started(f)
        await model.perform(.snooze)
        XCTAssertEqual(model.keyboardMode, .snooze)
        await model.perform(.cancel)
        XCTAssertEqual(try card(model).entry.id, "key0")

        await model.perform(.snooze)
        await model.perform(.snoozeUntil(.tomorrow))
        XCTAssertEqual(try card(model).entry.id, "key1")
        XCTAssertEqual(model.notice?.hasPrefix("Snoozed until"), true)
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 0)

        await model.perform(.hold)
        XCTAssertEqual(model.progress?.totals.lines.first { $0.label == "Snoozed" }?.value, 1)
        XCTAssertEqual(model.progress?.totals.held, 1)
    }

    func testOnlyRepliesTheEventOffersCanBeChosen() async throws {
        let f = try MacFixture(count: 1, provider: "eventkit")
        let model = await started(f)
        XCTAssertTrue(try card(model).replies.isEmpty)
        await model.perform(.reply(.yes))
        XCTAssertEqual(try card(model).entry.id, "key0")
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 0)
    }

    func testHoldSendsNothingAndStaysHeldAfterResume() async throws {
        let f = try MacFixture(count: 2)
        let model = await started(f)
        await model.perform(.hold)
        XCTAssertEqual(model.notice, "Held for this session. Nothing was sent.")
        XCTAssertEqual(try card(model).entry.id, "key1")
        model.stop()
        XCTAssertTrue(model.paused)

        model.open(filter: .all)
        XCTAssertNotNil(model.saved)
        await model.resume()
        XCTAssertEqual(try card(model).entry.id, "key1")
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 0)
    }

    func testMaybeDoesNotComeBackInTheSameSession() async throws {
        let f = try MacFixture(count: 2)
        let model = await started(f)
        await model.perform(.reply(.maybe))
        await model.perform(.send)
        model.stop()
        model.open(filter: .all)
        await model.resume()
        XCTAssertEqual(try card(model).entry.id, "key1")
        XCTAssertEqual(model.progress?.totals.maybe, 1)
    }

    func testJumpingToAnOverlapAndBack() async throws {
        let f = try MacFixture(count: 2, overlapping: true)
        let model = await started(f, filter: .conflicts)
        XCTAssertTrue(model.overlapsOnly)
        XCTAssertEqual(try card(model).neighbors.map(\.id), ["key1"])

        await model.perform(.goTo(5))
        XCTAssertEqual(try card(model).entry.id, "key0")
        XCTAssertFalse(model.isJumped)

        await model.perform(.goTo(1))
        XCTAssertEqual(try card(model).entry.id, "key1")
        XCTAssertTrue(model.isJumped)
        await model.perform(.back)
        XCTAssertEqual(try card(model).entry.id, "key0")
        XCTAssertFalse(model.isJumped)
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 0)
    }

    func testAnEventChangedAfterTheCardWasShownIsNotAnswered() async throws {
        let f = try MacFixture(count: 1)
        let model = await started(f)
        try f.apply(keys: ["key0"], title: "Moved to Friday")
        await model.perform(.reply(.yes))
        await model.perform(.send)
        XCTAssertEqual(model.notice, "The event changed first. Nothing was sent. Choose again.")
        XCTAssertEqual(try card(model).entry.title, "Moved to Friday")
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 0)
    }

    func testAnUnclearReplyPausesAndIsNeverSentAgain() async throws {
        let f = try MacFixture(count: 2)
        await f.remote.setMode(.unknown)
        let model = await started(f)
        await model.perform(.reply(.yes))
        await model.perform(.send)
        guard case .summary = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertTrue(model.paused)
        // The summary explains an unclear reply itself.
        XCTAssertEqual(model.progress?.hasUnclear, true)
        XCTAssertEqual(model.progress?.totals.recorded, 0)

        model.open(filter: .all)
        XCTAssertEqual(model.saved?.hasUnclear, true)
        await model.resume()
        await model.perform(.reply(.yes))
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 1)
    }

    func testAMacCalendarEventIsOpenedThenHeldWithoutBeingCountedAnswered() async throws {
        let f = try MacFixture(count: 1, provider: "eventkit")
        let opened = Opened()
        let model = await started(f, opened: opened)
        await model.perform(.openCalendar)
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(model.openedKey, "key0")
        await model.perform(.doneInCalendar)
        XCTAssertEqual(model.calendarSkips, 1)
        XCTAssertEqual(model.progress?.totals.recorded, 0)
        let writes = await f.remote.writes
        XCTAssertEqual(writes, 0)
    }

    func testAProblemOffersHoldWithoutSending() async {
        struct Down: Error {}
        let service = InboxReviewService(
            makeRepository: { throw Down() }, makeLockURL: { throw Down() },
            makeRefresh: { _ in { throw Down() } }, provider: { _ in throw Down() })
        let model = InboxReviewModel(service: service)
        model.open(filter: .all)
        await model.begin()
        guard case .problem(_, key: nil) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(model.keyboardMode, .problem)
        await model.perform(.hold)
        guard case .summary = model.phase else { return XCTFail("\(model.phase)") }
    }
}
