import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Free windows")
struct FreeWindowTests {
    private let zone = TimeZone(identifier: "America/New_York")!

    private func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func hours(_ days: [Int: (Int, Int)]) throws -> WorkingHours {
        try WorkingHours(days: days.mapValues { try! WorkingHours.Day(startMinute: $0.0 * 60, endMinute: $0.1 * 60) })
    }

    private func windows(
        _ events: [(Date, Date)], from start: Date, through end: Date, hours: WorkingHours?, atLeast minutes: Double,
        after: Date? = nil
    ) -> [DateInterval] {
        AvailabilityCalculator.calculate(
            instances: events.enumerated().map { instance(id: "synthetic-\($0.offset)", start: $0.element.0, end: $0.element.1) },
            from: start, through: end, workingHours: hours, timeZone: zone
        ).freeWindows(atLeast: minutes * 60, after: after).map { DateInterval(start: $0.start, end: $0.end) }
    }

    @Test("Windows shorter than asked are left out, and an event splits a window")
    func lengths() throws {
        // Monday 2 March 2026, 9:00 to 17:00 with a lunch from 12:00 to 13:00.
        let monday = try hours([1: (9, 17)])
        let lunch = [(at(2026, 3, 2, 12), at(2026, 3, 2, 13))]
        let morning = DateInterval(start: at(2026, 3, 2, 9), end: at(2026, 3, 2, 12))
        let afternoon = DateInterval(start: at(2026, 3, 2, 13), end: at(2026, 3, 2, 17))
        let cases: [(minutes: Double, expected: [DateInterval])] = [
            (30, [morning, afternoon]), (180, [morning, afternoon]), (181, [afternoon]), (240, [afternoon]), (241, []),
        ]
        for item in cases {
            #expect(windows(lunch, from: at(2026, 3, 2), through: at(2026, 3, 3), hours: monday, atLeast: item.minutes) == item.expected)
        }
    }

    @Test("A day off has no windows")
    func dayOff() throws {
        let hours = try hours([1: (9, 17), 3: (9, 17)])
        let found = windows([], from: at(2026, 3, 2), through: at(2026, 3, 5), hours: hours, atLeast: 60)
        #expect(found.map(\.start) == [at(2026, 3, 2, 9), at(2026, 3, 4, 9)])
    }

    @Test("Working hours decide where a window may start")
    func workingHours() throws {
        let day = (at(2026, 3, 2), at(2026, 3, 3))
        let early = [(at(2026, 3, 2, 6), at(2026, 3, 2, 8))]
        let on = windows(early, from: day.0, through: day.1, hours: try hours([1: (9, 17)]), atLeast: 60)
        let off = windows(early, from: day.0, through: day.1, hours: nil, atLeast: 60)
        #expect(on == [DateInterval(start: at(2026, 3, 2, 9), end: at(2026, 3, 2, 17))])
        #expect(off == [DateInterval(start: day.0, end: at(2026, 3, 2, 6)), DateInterval(start: at(2026, 3, 2, 8), end: day.1)])
    }

    @Test("A clock change makes the day 23 or 25 hours long")
    func daylightSaving() {
        let cases: [(day: (Int, Int), hours: Double, minutes: [Double: Int])] = [
            ((3, 8), 23, [1_380: 1, 1_381: 0]),
            ((11, 1), 25, [1_500: 1, 1_501: 0]),
        ]
        for item in cases {
            let start = at(2026, item.day.0, item.day.1), end = at(2026, item.day.0, item.day.1 + 1)
            #expect(end.timeIntervalSince(start) == item.hours * 3_600)
            for (minutes, count) in item.minutes {
                #expect(windows([], from: start, through: end, hours: nil, atLeast: minutes).count == count)
            }
        }
    }

    @Test("Time before the start point does not count toward the length")
    func after() {
        let day = (at(2026, 3, 2), at(2026, 3, 3))
        let found = windows([], from: day.0, through: day.1, hours: nil, atLeast: 60, after: at(2026, 3, 2, 23, 30))
        #expect(found.isEmpty)
        let late = windows([], from: day.0, through: day.1, hours: nil, atLeast: 60, after: at(2026, 3, 2, 12))
        #expect(late == [DateInterval(start: at(2026, 3, 2, 12), end: day.1)])
    }

    private func instance(id: String, start: Date, end: Date) -> StoredNormalizedInstance {
        StoredNormalizedInstance(
            sourceKeyHash: id, connectionID: "synthetic-source", calendarBindingID: "synthetic-calendar",
            providerEventID: id, recurrenceID: nil, startsAt: start, endsAt: end, isAllDay: false,
            availability: "busy", isCancelled: false, isPrivate: false, title: "Synthetic event",
            contentFingerprint: "fingerprint-\(id)", providerUpdatedAt: nil)
    }
}
