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

    @Test("Free time stays inside working hours and busy time outside them is kept")
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
            instance(id: "late", start: at(2, 18), end: at(2, 19)),
            instance(id: "standup", start: at(2, 9), end: at(2, 9, 30)),
            instance(id: "clash", start: at(2, 9, 15), end: at(2, 10)),
            instance(id: "off-day", start: at(3, 10), end: at(3, 11)),
        ]

        let result = AvailabilityCalculator.calculate(
            instances: instances, from: at(2, 0), through: at(5, 0), workingHours: hours, timeZone: zone)

        #expect(result.free == [
            AvailabilityInterval(kind: .free, start: at(2, 10), end: at(2, 17)),
            AvailabilityInterval(kind: .free, start: at(4, 10), end: at(4, 13)),
        ])
        #expect(result.busy.count == 3)
        #expect(result.overlaps == 1)
        #expect(result.workingWindows?.count == 2)
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
