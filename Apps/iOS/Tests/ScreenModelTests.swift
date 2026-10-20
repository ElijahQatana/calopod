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
    }

    @Test func theScheduleKeepsTimeOutsideWorkingHours() {
        let record = AvailabilityDay(
            day: "2027-01-01", timeZoneIdentifier: utc, busy: [BusyInterval(start: date(1, 10), end: date(1, 11))],
            working: BusyInterval(start: date(1, 9), end: date(1, 17)), free: [], overlaps: 0, status: .tight,
            outside: [OutsideBlock(start: date(1, 19), end: date(1, 20), side: .after)])
        #expect(DaySchedule.schedules(from: [record])[0].busy.count == 2)
    }

    @Test func busyTimeAcrossMidnightSplitsBetweenDays() {
        // Only the first day's record holds the whole stretch.
        let days = DaySchedule.schedules(from: [record(1, [(date(1, 22), date(2, 1))]), record(2, [])])
        #expect(days[0].busy[0].interval.duration == 2 * 3600)
        #expect(days[0].busy[0].continuesTomorrow)
        #expect(days[1].busy[0].interval.duration == 3600)
        #expect(days[1].busy[0].continuesFromYesterday)
        #expect(!days[1].busy[0].continuesTomorrow)
    }

    @Test func emptyDayHasNoBusyBlocks() {
        let day = DaySchedule.schedules(from: [record(3, [])])[0]
        #expect(day.busy.isEmpty)
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

struct StatusHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendars = [CalendarEntry(id: "a", name: "Work", colorIndex: 0)]

    @Test func countsFailedRunsAndReadsUpdateTimes() {
        let status = SyncStatus(
            lastSyncAt: now, runs: [SyncRunMark(at: now, failed: false), SyncRunMark(at: now, failed: true)],
            calendarUpdates: [CalendarUpdate(calendarID: "a", at: now)])
        let report = StatusReport(status: status, calendars: calendars)
        #expect(report.failedRuns == 1 && report.rows[0].updatedAt == now)
    }

    @Test func drawsAtMostTheLatest24Runs() {
        let runs = (0..<30).map { SyncRunMark(at: now.addingTimeInterval(Double($0)), failed: $0 < 6) }
        let report = StatusReport(status: SyncStatus(lastSyncAt: now, runs: runs), calendars: calendars)
        #expect(report.runs?.count == 24 && report.runs?.first?.at == runs[6].at && report.failedRuns == 0)
    }

    @Test func anOlderMacHasNoHistory() {
        let report = StatusReport(status: SyncStatus(lastSyncAt: now), calendars: calendars)
        #expect(report.runs == nil && report.failedRuns == 0 && report.rows[0].updatedAt == nil)
    }
}

struct DayEventsTests {
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Date(timeIntervalSince1970: 1_798_761_600 + Double((day - 1) * 86400 + hour * 3600 + minute * 60))
    }
    private func event(
        _ id: String, _ start: Date, _ end: Date, calendar: String = "work", allDay: Bool = false, title: String? = "x"
    ) -> CalendarEvent {
        CalendarEvent(id: id, calendarID: calendar, title: title, startsAt: start, endsAt: end, isAllDay: allDay, response: .accepted)
    }
    private func layout(_ events: [CalendarEvent], hidden: Set<String> = [], day: Int = 1) -> DayEvents {
        let key = String(format: "2027-01-%02d", day)
        let schedule = DaySchedule.schedules(from: [AvailabilityDay(day: key, timeZoneIdentifier: "UTC", busy: [])])[0]
        return DayEvents.make(from: CalendarDay(day: key, timeZoneIdentifier: "UTC", events: events), hidden: hidden, in: schedule)
    }

    @Test func overlapsShareTheWidth() {
        let blocks = layout([
            event("a", date(1, 9), date(1, 11)), event("b", date(1, 10), date(1, 12)),
            event("c", date(1, 10, 30), date(1, 11, 30)), event("d", date(1, 14), date(1, 15)),
        ]).blocks
        #expect(blocks.map(\.id) == ["a", "b", "c", "d"])
        #expect(blocks.map(\.column) == [0, 1, 2, 0])
        #expect(blocks.map(\.columns) == [3, 3, 3, 1])
    }

    @Test func aFreedColumnIsReused() {
        let blocks = layout([
            event("a", date(1, 9), date(1, 10)), event("b", date(1, 9), date(1, 12)), event("c", date(1, 10), date(1, 11)),
        ]).blocks
        // The longer event starts first and keeps column 0; the short ones take turns in column 1.
        #expect(blocks.map(\.id) == ["b", "a", "c"])
        #expect(blocks.map(\.column) == [0, 1, 1])
        #expect(blocks.map(\.columns) == [2, 2, 2])
    }

    @Test func midnightCrossingIsCutToEachDay() {
        let late = event("late", date(1, 22), date(2, 1))
        let first = layout([late], day: 1).blocks[0]
        #expect(first.interval == DateInterval(start: date(1, 22), end: date(2, 0)))
        #expect(first.continuesTomorrow && !first.continuesFromYesterday)
        let second = layout([late], day: 2).blocks[0]
        #expect(second.interval == DateInterval(start: date(2, 0), end: date(2, 1)))
        #expect(second.continuesFromYesterday && !second.continuesTomorrow)
    }

    @Test func allDayEventsGoToTheStrip() {
        let result = layout([event("trip", date(1, 0), date(3, 0), allDay: true), event("a", date(1, 9), date(1, 10))])
        #expect(result.allDay.map(\.id) == ["trip"])
        #expect(result.blocks.map(\.id) == ["a"])
    }

    @Test func hiddenCalendarsAndUntitledEvents() {
        let result = layout([event("a", date(1, 9), date(1, 10)), event("b", date(1, 9), date(1, 10), calendar: "home", title: nil)], hidden: ["work"])
        #expect(result.blocks.map(\.id) == ["b"])
        #expect(result.blocks[0].columns == 1)
        #expect(result.blocks[0].event.displayTitle == "Busy")
    }

    @Test func zeroLengthEventKeepsAShortBlock() {
        #expect(layout([event("a", date(1, 9), date(1, 9))]).blocks[0].interval.duration == DayEvents.shortest)
    }

    @Test func detailCarriesOnlyPublishedFields() {
        let item = InboxItem(CalendarEvent(
            id: "a", calendarID: "work", title: nil, startsAt: date(1, 9), endsAt: date(1, 10), location: nil, response: .tentative))
        let detail = EventDetail(item: item, untitled: "Busy")
        #expect(detail.title == "Busy")
        #expect(detail.response == "Maybe")
        #expect(detail.notes == nil && detail.link == nil && detail.guests == nil && detail.organizer == nil)
    }
}

struct CalendarFilterTests {
    private func defaults() -> UserDefaults {
        let name = "filter-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func everythingIsShownAtFirst() {
        #expect(CalendarFilter(defaults: defaults()).isShown("work"))
    }

    @Test func choiceIsRemembered() {
        let store = defaults()
        let filter = CalendarFilter(defaults: store)
        filter.setShown(false, for: "work")
        filter.setShown(false, for: "home")
        filter.setShown(true, for: "home")
        let later = CalendarFilter(defaults: store)
        #expect(!later.isShown("work"))
        #expect(later.isShown("home"))
    }

    @Test func listsCalendarsThatHaveEvents() {
        var snapshot = FixtureReader.snapshot(publishedAt: .now, now: .now)
        #expect(CalendarFilter.listed(in: snapshot).map(\.id) == ["work", "personal", "family", "client"])
        snapshot.days = []
        #expect(CalendarFilter.listed(in: snapshot).isEmpty)
    }

    private func manyCalendars(roles: Bool) -> Snapshot { FixtureReader.manyCalendars(publishedAt: .now, now: .now, roles: roles) }

    @Test func scopeSplitsSourcesAndDestinations() {
        let snapshot = manyCalendars(roles: true)
        let filter = CalendarFilter(defaults: defaults())
        #expect(filter.hiding(in: snapshot).isEmpty)
        filter.setScope(.destinations)
        #expect(filter.hiding(in: snapshot) == ["work", "personal", "family", "client", "studio", "travel"])
        #expect(filter.count(in: snapshot) == (2, 2))
        filter.setScope(.sources)
        filter.setShown(false, for: "work")
        #expect(filter.hiding(in: snapshot) == ["main", "busy", "work"])
        #expect(filter.count(in: snapshot) == (5, 6))
    }

    @Test func olderMacSendsNoRolesSoEverythingStaysAndTheHideListWorks() {
        let snapshot = manyCalendars(roles: false)
        let store = defaults()
        let filter = CalendarFilter(defaults: store)
        filter.setScope(.destinations)
        filter.setShown(false, for: "busy")
        #expect(!CalendarFilter.knowsRoles(in: snapshot))
        #expect(filter.scope(in: snapshot) == .all)
        #expect(filter.hiding(in: snapshot) == ["busy"])
        filter.reset()
        #expect(CalendarFilter(defaults: store).hidden.isEmpty)
        #expect(CalendarFilter(defaults: store).scope == .destinations)
    }
}
