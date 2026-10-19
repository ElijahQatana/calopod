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
        status: AvailabilityStatus? = nil
    ) -> AvailabilityFigures {
        AvailabilityFigures(
            AvailabilityDay(day: "2027-01-04", timeZoneIdentifier: "UTC", busy: busy, working: working, free: free, overlaps: overlaps, status: status))!
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

    @Test func statusColorsFollowTheMac() {
        let colors: [AvailabilityStatus: Color?] = [.mostlyFree: Theme.good, .tight: Theme.caution, .overbooked: Theme.bad, .dayOff: nil]
        for (status, color) in colors { #expect(status.color == color) }
    }

    @Test func aDayOffHasNoFreeTimeAndSaysSo() {
        let day = figures(busy: [span(10, 11)], free: [], overlaps: 0, status: .dayOff)
        #expect(day.freeTime == 0 && day.busyTime == 3600)
        #expect(day.hoursLine(locale: uk) == "Day off. Anything you book counts as busy.")
        #expect(day.summary(locale: uk) == "Monday is a day off.")
    }

    @Test func anOlderMacShowsBusyTimeOnly() {
        let day = figures(busy: [span(10, 11), span(14, 15)])
        #expect(day.busyTime == 2 * 3600)
        #expect(day.freeTime == nil && day.worked == nil)
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

        let old = try await week(.oldMac)
        #expect(old.count == 7 && old.allSatisfy { $0.freeTime == nil } && old[0].busyTime == 5.5 * 3600)

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
