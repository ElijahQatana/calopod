import CalopodDomain
import CalopodSnapshot
import Foundation
import Testing

@testable import Calopod

struct InboxFilterTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, _ reasons: [InboxReason], hours: Double = 0) -> InboxItem {
        InboxItem(
            id: id, reasons: reasons, title: id, startsAt: start.addingTimeInterval(hours * 3600),
            endsAt: start.addingTimeInterval(hours * 3600 + 1800), calendarID: "work", response: .needsResponse)
    }

    @Test func filtersByReason() {
        let items = [item("a", [.needsRSVP, .conflict]), item("b", [.maybe]), item("c", [.unreadChange]), item("d", [.conflict])]
        let ids: [InboxFilter: [String]] = [
            .all: ["a", "b", "c", "d"], .needsRSVP: ["a"], .maybe: ["b"], .changes: ["c"], .conflicts: ["a", "d"],
        ]
        for (filter, expected) in ids { #expect(filter.apply(to: items).map(\.id) == expected) }
    }

    @Test func groupsByDayInTimeOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let groups = groupedByDay([item("late", [.maybe], hours: 30), item("b", [.maybe], hours: 5), item("a", [.maybe], hours: 1)], calendar: calendar)
        #expect(groups.map { $0.items.map(\.id) } == [["a", "b"], ["late"]])
    }
}

struct DayScheduleTests {
    private let utc = "UTC"
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // 2027-01-01 00:00 UTC is 1_798_761_600.
        Date(timeIntervalSince1970: 1_798_761_600 + Double((day - 1) * 86400 + hour * 3600 + minute * 60))
    }
    private func record(_ day: Int, _ busy: [(Date, Date)]) -> AvailabilityDay {
        AvailabilityDay(day: String(format: "2027-01-%02d", day), timeZoneIdentifier: utc, busy: busy.map { BusyInterval(start: $0, end: $1) })
    }

    @Test func overlappingAndTouchingTimeCountsOnce() {
        let day = DaySchedule.schedules(from: [
            record(1, [(date(1, 9), date(1, 11)), (date(1, 10), date(1, 12)), (date(1, 12), date(1, 13))])
        ])[0]
        #expect(day.busy.map(\.interval) == [DateInterval(start: date(1, 9), end: date(1, 13))])
        #expect(day.busyTime == 4 * 3600)
        #expect(day.freeTime == 20 * 3600)
    }

    @Test func busyTimeAcrossMidnightSplitsBetweenDays() {
        // Only the first day's record holds the whole stretch.
        let days = DaySchedule.schedules(from: [record(1, [(date(1, 22), date(2, 1))]), record(2, [])])
        #expect(days[0].busyTime == 2 * 3600)
        #expect(days[0].busy[0].continuesTomorrow)
        #expect(days[1].busyTime == 3600)
        #expect(days[1].busy[0].continuesFromYesterday)
        #expect(!days[1].busy[0].continuesTomorrow)
    }

    @Test func emptyDayIsAllFree() {
        let day = DaySchedule.schedules(from: [record(3, [])])[0]
        #expect(day.busy.isEmpty)
        #expect(day.freeTime == 86400)
    }

    @Test func formatsDurations() {
        #expect(DurationText.text(45 * 60) == "45 min")
        #expect(DurationText.text(3 * 3600) == "3 hr")
        #expect(DurationText.text(5.5 * 3600) == "5 hr 30 min")
        #expect(DurationText.short(5400) == "1h 30m")
    }
}

struct EventDetailTests {
    private func detail(
        response: EventResponseState = .needsResponse, attendees: AttendeeSummary = AttendeeSummary(total: 0),
        location: String? = nil, url: String? = nil
    ) -> EventDetail {
        EventDetail(item: InboxItem(
            id: "x", reasons: [.needsRSVP], title: nil, startsAt: .now, endsAt: .now, calendarID: "work",
            response: response, attendees: attendees, location: location, url: url))
    }

    @Test func summarisesReplies() {
        #expect(detail(attendees: AttendeeSummary(total: 9, accepted: 5, tentative: 1, declined: 0)).guests == "9 invited · 5 yes · 1 maybe")
        #expect(detail().guests == nil)
        #expect(detail().title == "Untitled")
        #expect(detail(response: .tentative).response == "Maybe")
    }

    @Test func offersOnlyWebLinks() {
        #expect(detail(url: "https://example.com/room").link?.host == "example.com")
        for bad in ["javascript:alert(1)", "tel:5550100", "file:///etc/hosts", "", "not a url"] {
            #expect(detail(url: bad).link == nil)
        }
    }

    @Test func blankFieldsAreLeftOut() {
        #expect(detail(location: "  \n").location == nil)
        #expect(detail(location: " Room 4B ").location == "Room 4B")
    }
}

struct StatusReportTests {
    @Test func tiesIssuesToCalendars() {
        let calendars = [CalendarEntry(id: "a", name: "Work", colorIndex: 0), CalendarEntry(id: "b", name: "Family", colorIndex: 1)]
        let stale = SyncIssue(kind: .stale, calendarID: "b")
        let report = StatusReport(status: SyncStatus(lastSyncAt: nil, issues: [stale]), calendars: calendars)
        #expect(report.rows.map { $0.issue } == [nil, stale])
        #expect(report.message(for: stale) == "Family hasn't refreshed in a while.")
        #expect(!report.hasFailure)
        let failed = StatusReport(status: SyncStatus(lastSyncAt: nil, issues: [SyncIssue(kind: .failed)]), calendars: calendars)
        #expect(failed.hasFailure)
        #expect(failed.message(for: failed.issues[0]) == "The last sync failed.")
    }
}
