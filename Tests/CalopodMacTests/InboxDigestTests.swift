import CalopodStore
import CalopodSync
import Foundation
import XCTest

@testable import CalopodCommands
@testable import CalopodMac

final class InboxDigestTests: XCTestCase {
    private func entry(_ id: String, _ reasons: [InboxAttentionReason]) -> InboxEntry {
        InboxEntry(
            id: id, revisionID: "\(id):1", title: "synthetic-title-\(id)", startsAt: .now, endsAt: .now, isAllDay: false,
            calendarID: "cal", calendarName: "Calendar", organizer: nil, location: nil, response: .needsResponse,
            reasons: reasons, changeIsUncertain: false, overlapCount: 0)
    }

    private func board(_ groups: [(InboxAttentionReason, Int)]) -> InboxBoard {
        let entries = groups.flatMap { reason, count in (0..<count).map { entry("\(reason.rawValue)\($0)", [reason]) } }
        return InboxBoard(entries: entries, incompleteCalendars: [], isComplete: true, lastChecked: nil)
    }

    func testTheTextCountsEachReason() {
        let table: [([(InboxAttentionReason, Int)], String?)] = [
            ([], nil),
            ([(.needsResponse, 1)], "1 needs a reply"),
            ([(.needsResponse, 3)], "3 need a reply"),
            ([(.conflict, 1)], "1 conflict"),
            ([(.conflict, 2)], "2 conflicts"),
            ([(.needsResponse, 3), (.conflict, 1)], "3 need a reply, 1 conflict"),
            ([(.needsResponse, 1), (.maybe, 2), (.changedAfterResponse, 1), (.conflict, 2)], "1 needs a reply, 2 maybe, 1 changed, 2 conflicts"),
        ]
        for (groups, expected) in table {
            XCTAssertEqual(InboxDigest.text(board(groups)), expected)
        }
    }

    func testAnEventWithTwoReasonsIsCountedUnderBoth() {
        let both = InboxBoard(entries: [entry("a", [.needsResponse, .conflict])], incompleteCalendars: [], isComplete: true, lastChecked: nil)
        XCTAssertEqual(InboxDigest.text(both), "1 needs a reply, 1 conflict")
    }

    func testTheTextHoldsNoTitles() {
        let text = InboxDigest.text(board([(.needsResponse, 2), (.conflict, 1)])) ?? ""
        XCTAssertFalse(text.contains("synthetic"))
        XCTAssertFalse(text.contains("Calendar"))
    }

    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let morning = Date(timeIntervalSince1970: 1_800_000_000)

    private func plan(_ board: InboxBoard?, _ settings: InboxDigestSettings, hours: WorkingHours = .standard, now: Date? = nil) -> PlannedDigest? {
        InboxDigest.plan(board: board, settings: settings, workingHours: hours, now: now ?? morning, calendar: utc)
    }

    func testNothingIsPlannedWhenOffOrEmpty() throws {
        let waiting = board([(.needsResponse, 1)])
        XCTAssertNil(plan(waiting, .standard))
        XCTAssertNil(plan(board([]), try InboxDigestSettings(enabled: true)))
        XCTAssertNil(plan(nil, try InboxDigestSettings(enabled: true)))
        XCTAssertNotNil(plan(waiting, try InboxDigestSettings(enabled: true)))
    }

    func testTheDigestFiresAtTheNextChosenTime() throws {
        let waiting = board([(.conflict, 1)])
        let start = utc.startOfDay(for: morning)
        let settings = try InboxDigestSettings(enabled: true, minute: 8 * 60 + 30)
        let nextDay = utc.date(byAdding: .day, value: 1, to: start)!
        let before = start.addingTimeInterval(7 * 3600)
        XCTAssertEqual(plan(waiting, settings, now: before)?.fireDate, start.addingTimeInterval(8.5 * 3600))
        XCTAssertEqual(plan(waiting, settings, now: start.addingTimeInterval(9 * 3600))?.fireDate, nextDay.addingTimeInterval(8.5 * 3600))
    }

    func testWithoutAChosenTimeItStartsWithTheWorkingDay() throws {
        let waiting = board([(.conflict, 1)])
        let start = utc.startOfDay(for: morning)
        let on = try InboxDigestSettings(enabled: true)
        let early = try WorkingHours(days: [1: .init(startMinute: 450, endMinute: 1020)])
        XCTAssertEqual(plan(waiting, on, now: start)?.fireDate, start.addingTimeInterval(9 * 3600))
        XCTAssertEqual(plan(waiting, on, hours: early, now: start)?.fireDate, start.addingTimeInterval(7.5 * 3600))
    }

    func testSnoozedAndCancelledEventsAreNotCounted() async throws {
        let fixture = try MacFixture(count: 3)
        let service = fixture.inbox
        XCTAssertEqual(InboxDigest.text(try service.board()), "3 need a reply")

        let first = try XCTUnwrap(service.board().entries.first)
        try service.snooze(revisionID: first.revisionID, until: .tomorrow)
        XCTAssertEqual(InboxDigest.text(try service.board()), "2 need a reply")

        let cancelled = try XCTUnwrap(service.board().entries.first)
        try fixture.state.applyEventRefresh(
            connectionID: "c", calendarBindingID: "cal", windowStart: fixture.window.start, windowEnd: fixture.window.end,
            instances: [], cancelledSourceKeyHashes: [cancelled.id], isFullRefresh: false, cursorUpdates: [])
        XCTAssertEqual(InboxDigest.text(try service.board()), "1 needs a reply")
    }

    func testTheCountAgreesWithTheInboxFilters() async throws {
        let fixture = try MacFixture(count: 3, overlapping: true)
        let board = try fixture.inbox.board()
        let expected = [InboxFilter.needsRSVP: "need a reply", .conflicts: "conflicts"]
        for (filter, word) in expected {
            XCTAssertTrue(InboxDigest.text(board)?.contains("\(board.count(filter)) \(word)") == true)
        }
    }

    @MainActor
    private func scheduler(
        _ center: FakeReminderCenter, board: @escaping @MainActor () -> InboxBoard?, settings: Box<InboxDigestSettings>
    ) -> ReminderScheduler {
        let now = morning, calendar = utc
        return ReminderScheduler(
            center: center, settings: { .standard }, schedule: { CalendarSchedule(calendars: [], events: []) },
            ignored: { _ in false }, shownName: { $0.name },
            digest: { InboxDigest.plan(board: board(), settings: settings.value, workingHours: .standard, now: now, calendar: calendar) },
            now: { now })
    }

    @MainActor
    func testTheDigestIsPendingOnlyWhileSomethingIsWaitingAndAllowed() async throws {
        let center = FakeReminderCenter()
        let waiting = Box<InboxBoard?>(board([(.needsResponse, 2)]))
        let settings = Box(try InboxDigestSettings(enabled: true))
        let runner = scheduler(center, board: { waiting.value }, settings: settings)

        await runner.reconcile()
        XCTAssertEqual(center.digest?.body, "2 need a reply")
        center.clearLog()
        await runner.reconcile()
        XCTAssertEqual(center.added, [])

        waiting.value = board([(.needsResponse, 2), (.conflict, 1)])
        await runner.reconcile()
        XCTAssertEqual(center.digest?.body, "2 need a reply, 1 conflict")

        waiting.value = board([])
        await runner.reconcile()
        XCTAssertNil(center.digest)

        waiting.value = board([(.conflict, 1)])
        await runner.reconcile()
        center.permissionState = .denied
        await runner.reconcile()
        XCTAssertNil(center.digest)

        center.permissionState = .allowed
        settings.value = .standard
        await runner.reconcile()
        XCTAssertNil(center.digest)
    }

    @MainActor
    func testAClickOnTheDigestOpensTheInbox() {
        let info = [InboxDigest.infoKey: "1"]
        XCTAssertEqual(ReminderResponse.parse(actionIdentifier: "com.apple.UNNotificationDefaultActionIdentifier", info: info), .openInbox)
        XCTAssertEqual(ReminderResponse.parse(actionIdentifier: ReminderActionID.open, info: info), .openInbox)
        XCTAssertNil(ReminderResponse.parse(actionIdentifier: "com.apple.UNNotificationDismissActionIdentifier", info: info))

        let router = ReminderRouter()
        router.receive(.openInbox)
        var opened = 0
        router.attach(open: { _ in }, openInbox: { opened += 1 })
        XCTAssertEqual(opened, 1)
        router.receive(.openInbox)
        XCTAssertEqual(opened, 2)

        let navigation = AppNavigation(environment: [:])
        var shown = 0
        ReminderNavigation.openInbox(navigation: navigation, show: { shown += 1 })
        XCTAssertEqual(navigation.selection, .inbox)
        XCTAssertEqual(shown, 1)
    }
}

@MainActor
final class DigestSettingsModelTests: XCTestCase {
    func testChangesAreSavedAndTellTheScheduler() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = NotificationSettingsModel(state: state)
        var changes = 0
        model.onChange = { changes += 1 }
        XCTAssertFalse(model.digest.enabled)
        model.applyDigest(enabled: true)
        model.applyDigest(minute: 495)
        XCTAssertEqual(try state.inboxDigestSettings(), try InboxDigestSettings(enabled: true, minute: 495))
        XCTAssertEqual(changes, 2)
        model.applyDigest(minute: 495)
        XCTAssertEqual(changes, 2)
        model.applyDigest(minute: 2000)
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(model.digest.minute, 495)
    }

    func testAChangeMadeByTheCommandLineIsPickedUp() throws {
        let state = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let model = NotificationSettingsModel(state: state)
        try state.saveInboxDigestSettings(try InboxDigestSettings(enabled: true, minute: 600))
        XCTAssertEqual(model.currentDigest().minute, 600)
    }
}
