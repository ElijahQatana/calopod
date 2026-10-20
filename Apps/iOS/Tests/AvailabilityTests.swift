import CalopodSnapshot
import Foundation
import SwiftUI
import Testing

@testable import Calopod

@MainActor
struct AvailabilityTests {
    private let hr = 3600.0
    private let uk = Locale(identifier: "en_GB")

    /// 2027-01-04 is a Monday; 00:00 UTC that day is 1_799_020_800.
    private func hour(_ hours: Double) -> Date { Date(timeIntervalSince1970: 1_799_020_800 + hours * 3600) }
    private func span(_ from: Double, _ to: Double) -> BusyInterval { BusyInterval(start: hour(from), end: hour(to)) }

    private func figures(
        busy: [BusyInterval] = [], working: BusyInterval? = nil, free: [BusyInterval]? = nil, overlaps: Int? = nil,
        status: AvailabilityStatus? = nil, outside: [OutsideBlock]? = nil
    ) -> AvailabilityFigures {
        AvailabilityFigures(
            AvailabilityDay(
                day: "2027-01-04", timeZoneIdentifier: "UTC", busy: busy, working: working, free: free, overlaps: overlaps,
                status: status, outside: outside))!
    }

    @Test func totalsAreTheSumsOfThePublishedLists() {
        // The free list is not the complement of busy on purpose: the phone must not work it out.
        let day = figures(busy: [span(10, 11), span(13, 14.5)], working: span(9, 17), free: [span(9, 10), span(11, 12)], overlaps: 1, status: .tight)
        #expect(day.busyTime == 2.5 * 3600)
        #expect(day.freeTime == 2 * hr)
        #expect(day.overlapsLine == "1 overlap")
        #expect(day.hoursLine(locale: uk) == "Working hours 09:00 to 17:00.")
        #expect(day.summary(locale: uk) == "Monday is tight.")
    }

    @Test func theMondayWithMeetingsBeforeAndAfterShowsWhatTheMacPublished() {
        let day = figures(
            busy: [span(13, 14.5), span(15.5, 16.5)], working: span(9, 17), free: [span(9, 13), span(14.5, 15.5), span(16.5, 17)],
            overlaps: 0, status: .mostlyFree,
            outside: [
                OutsideBlock(start: hour(7), end: hour(8), side: .before),
                OutsideBlock(start: hour(19.5), end: hour(20), side: .after),
            ])
        #expect((day.freeTime, day.busyTime, day.outsideTime) == (5.5 * hr, 2.5 * hr, 1.5 * hr))
        #expect(day.outside?.map(\.side) == [.before, .after])
        #expect(day.timeRange(day.outside![0].range, locale: uk) == "07:00 to 08:00")
    }

    @Test func statusColorsFollowTheMac() {
        let colors: [AvailabilityStatus: Color?] = [.mostlyFree: Theme.good, .tight: Theme.caution, .overbooked: Theme.bad, .dayOff: nil]
        for (status, color) in colors { #expect(status.color == color) }
    }

    @Test func aDayOffHasNoFreeTimeAndSaysSo() {
        let day = figures(
            busy: [], free: [], overlaps: 0, status: .dayOff, outside: [OutsideBlock(start: hour(10), end: hour(11), side: .dayOff)])
        #expect(day.freeTime == 0 && day.busyTime == 0 && day.outsideTime == 3600)
        #expect(day.hoursLine(locale: uk) == "Day off. Anything you book is outside working hours.")
        #expect(day.summary(locale: uk) == "Monday is a day off.")
    }

    @Test func anOlderMacShowsBusyTimeOnly() {
        let day = figures(busy: [span(10, 11), span(14, 15)])
        #expect(day.busyTime == 2 * 3600)
        #expect(day.freeTime == nil && day.worked == nil && day.outside == nil && day.outsideTime == 0)
        #expect(day.hoursLine() == "Working hours need an updated Mac.")
        #expect(day.summary() == nil && day.overlapsLine == nil)
    }

    @Test func fixtureScenarios() async throws {
        func week(_ scenario: FixtureReader.Scenario) async throws -> [AvailabilityFigures] {
            guard case .snapshot(let snapshot) = try await FixtureReader(scenario: scenario).read() else { return [] }
            return AvailabilityFigures.week(from: snapshot.availability)
        }
        let normal = try await week(.fresh)
        #expect(normal.map { $0.worked?.status } == [.overbooked, .tight, .mostlyFree, .dayOff, .mostlyFree, .mostlyFree, .dayOff])
        #expect((normal[0].freeTime, normal[0].busyTime, normal[0].worked?.overlaps) == (2.5 * hr, 5.5 * hr, 1))
        // Meetings before and after the day, one split at the start of it, and a day off with a meeting.
        #expect(normal[0].outside?.map(\.side) == [.before, .after] && normal[0].outsideTime == 2.5 * hr)
        #expect(normal[2].outside?.map(\.side) == [.before] && normal[2].busyTime == 1.5 * hr)
        #expect(normal[6].outside?.map(\.side) == [.dayOff] && normal[6].busyTime == 0 && normal[6].outsideTime == hr)

        let old = try await week(.oldMac)
        #expect(old.count == 7 && old.allSatisfy { $0.freeTime == nil } && old[0].busyTime == 8 * hr && old[0].outside == nil)

        // The clocks go forward at 01:00, so 00:00 to 09:00 is 8 real hours.
        let change = try await week(.clockChange)[1]
        #expect(change.worked?.working?.duration == 8 * hr)
        #expect((change.freeTime, change.busyTime) == (7 * hr, hr))
        #expect(change.hoursLine(locale: uk) == "Working hours 00:00 to 09:00.")
    }

    @Test func homeShowsTodayAndAvailabilityOpensToday() {
        let record = AvailabilityDay(day: "2027-01-04", timeZoneIdentifier: "UTC", busy: [span(10, 11)], working: span(9, 17), free: [span(9, 10)], overlaps: 0, status: .mostlyFree)
        var snapshot = FixtureReader.snapshot(publishedAt: hour(8), now: hour(9))
        snapshot.availability = [record]
        let context = SnapshotContext(snapshot: snapshot, offline: false, now: hour(9.5))
        #expect(HomeSummary(context: context, hidden: []).availability?.freeTime == 3600)

        let navigation = Navigation()
        navigation.calendarDay = "2027-01-06"
        navigation.openAvailability()
        #expect(navigation.tab == .calendar && navigation.calendarMode == .availability && navigation.calendarDay == nil)
    }
}
