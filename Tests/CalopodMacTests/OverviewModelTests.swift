import XCTest

@testable import CalopodCommands
@testable import CalopodMac

final class OverviewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let day = Date(timeIntervalSince1970: 1_000_000 - 3600)..<Date(timeIntervalSince1970: 1_000_000 + 80_000)

    private func calendar(_ freshness: ScheduleFreshness, readAgo: Double? = nil, coverage: ClosedRange<Date>? = nil) -> ScheduleCalendar {
        ScheduleCalendar(
            id: "c", name: "Work", account: "a", provider: "p", freshness: freshness, coverage: coverage,
            readAt: readAgo.map { now.addingTimeInterval(-$0) })
    }

    func testLayoutSwitchesAtNineHundredPointsOfWindow() {
        // Content width plus margins, the sidebar and the gaps is the window width.
        let open = Theme.pagePadding * 2 + Sidebar.width + Sidebar.inset * 3
        let rail = Theme.pagePadding * 2 + Sidebar.railWidth + Sidebar.inset * 3
        XCTAssertTrue(OverviewLayout.isWide(contentWidth: 900 - open, sidebarCollapsed: false))
        XCTAssertFalse(OverviewLayout.isWide(contentWidth: 899 - open, sidebarCollapsed: false))
        XCTAssertTrue(OverviewLayout.isWide(contentWidth: 900 - rail, sidebarCollapsed: true))
        XCTAssertFalse(OverviewLayout.isWide(contentWidth: 899 - rail, sidebarCollapsed: true))
    }

    func testSideColumnStaysWithinLimits() {
        XCTAssertEqual(OverviewLayout.sideWidth(contentWidth: 500), 270)
        XCTAssertEqual(OverviewLayout.sideWidth(contentWidth: 800), 304)
        XCTAssertEqual(OverviewLayout.sideWidth(contentWidth: 1400), 440)
    }

    func testFreshnessLabels() {
        let cases: [(ScheduleCalendar, String, Bool)] = [
            (calendar(.current, readAgo: 240), "Updated 4 min ago", false),
            (calendar(.current, readAgo: 5), "Updated just now", false),
            (calendar(.current), "Up to date", false),
            (calendar(.stale(since: nil)), "Out of date", true),
            (calendar(.unread), "Not read yet", true),
            // Read, but not across the whole day.
            (calendar(.current, readAgo: 60, coverage: now...now.addingTimeInterval(3600)), "Partly read", true),
        ]
        for (item, text, behind) in cases {
            let label = CalendarFreshnessLabel.make(item, range: day, now: now)
            XCTAssertEqual(label, CalendarFreshnessLabel(text: text, isBehind: behind), text)
        }
    }

    func testStaleCalendarsAgreeWithTheLabels() {
        let schedule = CalendarSchedule(
            calendars: [calendar(.current, readAgo: 60), calendar(.stale(since: nil))], events: [])
        XCTAssertEqual(UpNext.staleCalendars(in: schedule, range: day, now: now), ["Work"])
        let partly = CalendarSchedule(calendars: [calendar(.current, coverage: now...now.addingTimeInterval(60))], events: [])
        XCTAssertEqual(UpNext.staleCalendars(in: partly, range: day, now: now), ["Work"])
        XCTAssertEqual(UpNext.staleCalendars(in: partly), [])
    }

    func testUpNextTags() {
        func event(_ minutes: Double, overlaps: [String] = []) -> ScheduleEvent {
            ScheduleEvent(
                id: "e", calendarID: "c", title: "Standup", startsAt: now.addingTimeInterval(minutes * 60),
                endsAt: now.addingTimeInterval((minutes + 15) * 60), overlaps: overlaps)
        }
        XCTAssertEqual(UpNextTag.tags(for: event(40), isNext: true, now: now), [.soon(minutes: 40)])
        XCTAssertEqual(UpNextTag.tags(for: event(40), isNext: false, now: now), [])
        XCTAssertEqual(UpNextTag.tags(for: event(180), isNext: true, now: now), [])
        XCTAssertEqual(UpNextTag.tags(for: event(-10, overlaps: ["Lunch"]), isNext: true, now: now), [.overlaps])
        XCTAssertEqual(UpNextTag.tags(for: event(30, overlaps: ["Lunch"]), isNext: true, now: now), [.soon(minutes: 30), .overlaps])
    }

    func testDurationText() {
        XCTAssertEqual(
            [900.0, 3600, 5400, 2700, 10].map(EventDuration.text), ["15 min", "1 hr", "1 hr 30 min", "45 min", "1 min"])
    }
}
