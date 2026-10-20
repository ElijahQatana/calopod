import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Availability calculation")
struct AvailabilityCalculatorTests {
    @Test("Busy intervals are clamped and merged while free events are ignored")
    func mergedIntervals() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(100)
        let instances = [
            instance(id: "early", start: start.addingTimeInterval(-10), end: start.addingTimeInterval(20)),
            instance(id: "duplicate", start: start, end: start.addingTimeInterval(20)),
            instance(
                id: "free-event",
                start: start.addingTimeInterval(10),
                end: start.addingTimeInterval(30),
                availability: "free"
            ),
            instance(id: "overlap", start: start.addingTimeInterval(15), end: start.addingTimeInterval(40)),
            instance(
                id: "touching",
                start: start.addingTimeInterval(40),
                end: start.addingTimeInterval(50),
                availability: "tentative"
            ),
            instance(id: "late", start: start.addingTimeInterval(70), end: end.addingTimeInterval(20)),
        ]

        let result = AvailabilityCalculator.calculate(
            instances: instances,
            from: start,
            through: end
        )

        #expect(result.busy == [
            AvailabilityInterval(kind: .busy, start: start, end: start.addingTimeInterval(50)),
            AvailabilityInterval(kind: .busy, start: start.addingTimeInterval(70), end: end),
        ])
        #expect(result.free == [
            AvailabilityInterval(
                kind: .free,
                start: start.addingTimeInterval(50),
                end: start.addingTimeInterval(70)
            ),
        ])
    }

    @Test("An empty calendar leaves the whole window free")
    func emptyWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        let end = start.addingTimeInterval(100)

        let result = AvailabilityCalculator.calculate(
            instances: [],
            from: start,
            through: end
        )

        #expect(result.busy.isEmpty)
        #expect(result.free == [AvailabilityInterval(kind: .free, start: start, end: end)])
    }

    @Test("Free time and busy time count inside working hours, the rest is reported outside")
    func workingHours() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
        }
        // Monday 2 March 2026 to Wednesday; Tuesday is a day off.
        let hours = try WorkingHours(days: [
            1: WorkingHours.Day(startMinute: 540, endMinute: 1020),
            3: WorkingHours.Day(startMinute: 600, endMinute: 780),
        ])
        let instances = [
            instance(id: "late", start: at(2, 18, 0), end: at(2, 19, 0)),
            instance(id: "standup", start: at(2, 9, 0), end: at(2, 9, 30)),
            instance(id: "clash", start: at(2, 9, 15), end: at(2, 10, 0)),
            instance(id: "off-day", start: at(3, 10, 0), end: at(3, 11, 0)),
        ]

        let result = AvailabilityCalculator.calculate(
            instances: instances, from: at(2, 0, 0), through: at(5, 0, 0), workingHours: hours, timeZone: zone)

        #expect(result.free == [
            AvailabilityInterval(kind: .free, start: at(2, 10, 0), end: at(2, 17, 0)),
            AvailabilityInterval(kind: .free, start: at(4, 10, 0), end: at(4, 13, 0)),
        ])
        #expect(result.busy == [AvailabilityInterval(kind: .busy, start: at(2, 9, 0), end: at(2, 10, 0))])
        #expect(result.outside == [
            OutsideInterval(side: .after, start: at(2, 18, 0), end: at(2, 19, 0)),
            OutsideInterval(side: .dayOff, start: at(3, 10, 0), end: at(3, 11, 0)),
        ])
        #expect(result.overlaps == 1)
        #expect(result.workingWindows?.count == 2)
    }

    @Test("A Monday with meetings before and after the working day")
    func outsideHours() throws {
        let (zone, at) = newYork()
        let hours = try WorkingHours(days: [1: WorkingHours.Day(startMinute: 540, endMinute: 1020)])
        let instances = [
            instance(id: "early", start: at(2, 7, 0), end: at(2, 8, 0)),
            instance(id: "one", start: at(2, 13, 0), end: at(2, 14, 30)),
            instance(id: "two", start: at(2, 15, 30), end: at(2, 16, 30)),
            instance(id: "late", start: at(2, 19, 30), end: at(2, 20, 0)),
        ]
        let day = DateInterval(start: at(2, 0, 0), end: at(3, 0, 0))

        let result = AvailabilityCalculator.calculate(
            instances: instances, from: day.start, through: day.end, workingHours: hours, timeZone: zone)
        let summary = AvailabilityDay(result, day: day)

        #expect(result.outside.map(\.side) == [.before, .after])
        #expect([summary.freeSeconds, summary.busySeconds, summary.outsideSeconds] == [19_800, 9_000, 5_400])
        #expect(summary.load == .mostlyFree)
    }

    @Test("A meeting across the start or end of the day is split at the boundary")
    func straddling() throws {
        let (zone, at) = newYork()
        let hours = try WorkingHours(days: [1: WorkingHours.Day(startMinute: 540, endMinute: 1020)])
        let instances = [
            instance(id: "start", start: at(2, 8, 0), end: at(2, 9, 30)),
            instance(id: "end", start: at(2, 16, 30), end: at(2, 18, 0)),
        ]

        let result = AvailabilityCalculator.calculate(
            instances: instances, from: at(2, 0, 0), through: at(3, 0, 0), workingHours: hours, timeZone: zone)

        #expect(result.busy.map { [$0.start, $0.end] } == [[at(2, 9, 0), at(2, 9, 30)], [at(2, 16, 30), at(2, 17, 0)]])
        #expect(result.outside == [
            OutsideInterval(side: .before, start: at(2, 8, 0), end: at(2, 9, 0)),
            OutsideInterval(side: .after, start: at(2, 17, 0), end: at(2, 18, 0)),
        ])
    }

    @Test("Overlapping meetings only crowd the working day when they overlap inside it")
    func overlapsOutside() throws {
        let (zone, at) = newYork()
        let hours = try WorkingHours(days: [1: WorkingHours.Day(startMinute: 540, endMinute: 1020)])
        let instances = [
            instance(id: "a", start: at(2, 7, 0), end: at(2, 8, 0)),
            instance(id: "b", start: at(2, 7, 30), end: at(2, 8, 30)),
            instance(id: "c", start: at(2, 10, 0), end: at(2, 11, 0)),
            instance(id: "d", start: at(2, 10, 30), end: at(2, 11, 30)),
        ]

        let result = AvailabilityCalculator.calculate(
            instances: instances, from: at(2, 0, 0), through: at(3, 0, 0), workingHours: hours, timeZone: zone)

        #expect(result.overlaps == 1)
        #expect(result.outside == [OutsideInterval(side: .before, start: at(2, 7, 0), end: at(2, 8, 30))])
    }

    @Test("Meetings on a day off are all outside, and the day stays off")
    func dayOff() throws {
        let (zone, at) = newYork()
        let hours = try WorkingHours(days: [1: WorkingHours.Day(startMinute: 540, endMinute: 1020)])
        let day = DateInterval(start: at(3, 0, 0), end: at(4, 0, 0))

        let result = AvailabilityCalculator.calculate(
            instances: [instance(id: "x", start: at(3, 10, 0), end: at(3, 11, 0))],
            from: day.start, through: day.end, workingHours: hours, timeZone: zone)
        let summary = AvailabilityDay(result, day: day)

        #expect(result.busy.isEmpty)
        #expect([summary.busySeconds, summary.outsideSeconds, summary.freeSeconds] == [0, 3_600, 0])
        #expect(summary.load == .dayOff)
    }

    @Test("On the spring forward day a meeting before working hours is still before")
    func clockChange() throws {
        let (zone, at) = newYork()
        let hours = try WorkingHours(days: [7: WorkingHours.Day(startMinute: 240, endMinute: 600)])
        let day = DateInterval(start: at(8, 0, 0), end: at(9, 0, 0))

        // The meeting runs from 1:00 to 4:30 on the wall clock, 2.5 real hours, and the clocks jump at 2:00.
        let result = AvailabilityCalculator.calculate(
            instances: [instance(id: "night", start: at(8, 1, 0), end: at(8, 4, 30))],
            from: day.start, through: day.end, workingHours: hours, timeZone: zone)

        #expect(result.outside.map { $0.end.timeIntervalSince($0.start) } == [7_200])
        #expect(result.busy.map { $0.end.timeIntervalSince($0.start) } == [1_800])
    }

    @Test("A spring forward day keeps working hours on the wall clock")
    func daylightSaving() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let hours = try WorkingHours(days: [7: WorkingHours.Day(startMinute: 60, endMinute: 240)])
        let next = calendar.date(byAdding: .day, value: 1, to: sunday)!

        let result = AvailabilityCalculator.calculate(
            instances: [], from: sunday, through: next, workingHours: hours, timeZone: zone)

        // 1:00 to 4:00 on the wall clock is two hours of real time, the clocks jump at 2:00.
        #expect(result.free.map { $0.end.timeIntervalSince($0.start) } == [7_200])
    }

    @Test("Day totals and load")
    func dayLoad() {
        let day = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 1_000)
        func load(freeSeconds: Double) -> AvailabilityLoad {
            let free = AvailabilityInterval(kind: .free, start: day.start, end: day.start.addingTimeInterval(freeSeconds))
            return AvailabilityDay(AvailabilityResult(busy: [], free: freeSeconds > 0 ? [free] : []), day: day).load
        }
        #expect([load(freeSeconds: 600), load(freeSeconds: 200), load(freeSeconds: 100)] == [.mostlyFree, .tight, .overbooked])
        let off = AvailabilityResult(busy: [], free: [], workingWindows: [])
        #expect(AvailabilityDay(off, day: day).load == .dayOff)
    }

    /// March 2026 in New York, where the clocks go forward on the 8th.
    private func newYork() -> (TimeZone, (Int, Int, Int) -> Date) {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return (zone, { day, hour, minute in
            calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
        })
    }

    private func instance(
        id: String,
        start: Date,
        end: Date,
        availability: String = "busy"
    ) -> StoredNormalizedInstance {
        StoredNormalizedInstance(
            sourceKeyHash: id,
            connectionID: "connection",
            calendarBindingID: "calendar",
            providerEventID: id,
            recurrenceID: nil,
            startsAt: start,
            endsAt: end,
            isAllDay: false,
            availability: availability,
            isCancelled: false,
            isPrivate: false,
            title: "Synthetic event",
            contentFingerprint: "fingerprint-\(id)",
            providerUpdatedAt: nil
        )
    }
}
