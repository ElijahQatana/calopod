import XCTest

@testable import CalopodCommands
@testable import CalopodMac

@MainActor
final class OverviewRefreshTests: XCTestCase {
    /// Each section shows a copy of what is on disk and only changes when its step runs.
    @MainActor private final class Page {
        var disk = 1
        var shown: [String: Int] = ["Inbox": 1, "Schedule": 1, "Sync": 1, "Access": 1]
        var order: [String] = []
        var failing: Set<String> = []
        var gate: CheckedContinuation<Void, Never>?

        func steps() -> [OverviewRefresh.Step] {
            ["Inbox", "Schedule", "Sync", "Access"].map { name in
                OverviewRefresh.Step(section: name) { [self] in
                    order.append(name)
                    if name == "Inbox" { await withCheckedContinuation { gate = $0 } }
                    if failing.contains(name) { return "\(name) failed." }
                    shown[name] = disk
                    return nil
                }
            }
        }
    }

    private func run(_ page: Page, _ refresh: OverviewRefresh) async {
        let task = Task { await refresh.run() }
        while page.gate == nil { await Task.yield() }
        page.gate!.resume()
        page.gate = nil
        await task.value
    }

    func testEverySectionReloadsTogetherInOrder() async {
        let page = Page(), refresh = OverviewRefresh(steps: page.steps())
        page.disk = 2
        await run(page, refresh)
        XCTAssertEqual(page.order, ["Inbox", "Schedule", "Sync", "Access"])
        XCTAssertEqual(Set(page.shown.values), [2])
        XCTAssertTrue(refresh.messages.isEmpty)
        XCTAssertEqual(refresh.refreshedText(now: refresh.refreshedAt!), "Last refreshed just now")
    }

    func testOneFailureLeavesTheOthersUpdatedAndShowsItsMessage() async {
        let page = Page(), refresh = OverviewRefresh(steps: page.steps())
        page.disk = 2
        page.failing = ["Schedule"]
        await run(page, refresh)
        XCTAssertEqual(page.shown, ["Inbox": 2, "Schedule": 1, "Sync": 2, "Access": 2])
        XCTAssertEqual(refresh.messages.map(\.text), ["Schedule failed."])
        XCTAssertNil(refresh.refreshedAt)

        refresh.dismiss("Schedule")
        XCTAssertTrue(refresh.messages.isEmpty)
    }

    func testBusyWhileRunningAndASecondPressIsIgnored() async {
        let page = Page(), refresh = OverviewRefresh(steps: page.steps())
        XCTAssertFalse(refresh.isBusy)
        let task = Task { await refresh.run() }
        while page.gate == nil { await Task.yield() }
        XCTAssertTrue(refresh.isBusy)
        await refresh.run()
        XCTAssertEqual(page.order, ["Inbox"])
        page.gate!.resume()
        await task.value
        XCTAssertFalse(refresh.isBusy)
    }

    func testAMessageIsClearedWhenTheNextRefreshStarts() async {
        let page = Page(), refresh = OverviewRefresh(steps: page.steps())
        page.failing = ["Sync"]
        await run(page, refresh)
        XCTAssertEqual(refresh.messages.count, 1)
        page.failing = []
        await run(page, refresh)
        XCTAssertTrue(refresh.messages.isEmpty)
        XCTAssertNotNil(refresh.refreshedAt)
    }

    func testScheduleAndMenuNameTheSameStaleCalendars() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func item(_ id: String, _ freshness: ScheduleFreshness, coverage: ClosedRange<Date>? = nil) -> ScheduleCalendar {
            ScheduleCalendar(id: id, name: id, account: "a", provider: "p", freshness: freshness, coverage: coverage, readAt: now)
        }
        let schedule = CalendarSchedule(
            calendars: [item("ok", .current), item("old", .stale(since: nil)), item("hidden", .unread),
                        item("partly", .current, coverage: now...now.addingTimeInterval(60))],
            events: [])
        XCTAssertEqual(UpNext.staleToday(in: schedule, now: now, ignored: { $0.id == "hidden" }, name: { $0.name }), ["old", "partly"])
        XCTAssertEqual(UpNext.staleToday(in: nil, now: now, name: { $0.name }), [])
    }
}
