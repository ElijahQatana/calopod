import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Focus time")
struct FocusTimeTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let midnight = Date(timeIntervalSince1970: 1_799_971_200)
    private var day: DateInterval { DateInterval(start: midnight, duration: 86_400) }

    @Test("The longest stretch and the flag, in minutes after midnight", arguments: [
        (busy: [(Int, Int)](), longest: 480, short: false),
        (busy: [(720, 780)], longest: 240, short: false),
        (busy: [(600, 660), (720, 840), (900, 960)], longest: 60, short: true),
        (busy: [(480, 1_080)], longest: 0, short: true),
        (busy: [(660, 720), (780, 840), (900, 960)], longest: 120, short: false),
        (busy: [(659, 720), (780, 840), (900, 960)], longest: 119, short: true),
        (busy: [(420, 540), (1_020, 1_100)], longest: 480, short: false),
    ])
    func longest(busy: [(Int, Int)], longest: Int, short: Bool) throws {
        let result = AvailabilityCalculator.calculate(
            instances: busy.map { event(from: $0.0, to: $0.1) }, from: day.start, through: day.end,
            workingHours: try everyDay(540, 1_020), timeZone: utc)

        #expect(result.longestFree(in: day) == TimeInterval(longest * 60))
        #expect(AvailabilityDay(result, day: day).longestFreeSeconds == TimeInterval(longest * 60))
        #expect(result.lacksFocus(in: day, length: 7_200) == short)
    }

    @Test("A day off is never short, even with a meeting on it")
    func dayOff() throws {
        let result = AvailabilityCalculator.calculate(
            instances: [event(from: 600, to: 660)], from: day.start, through: day.end,
            workingHours: try WorkingHours(days: [:]), timeZone: utc)

        #expect(result.longestFree(in: day) == 0)
        #expect(!result.lacksFocus(in: day, length: 7_200))
    }

    @Test("Padded copies count as busy")
    func padded() throws {
        let arm = StoredArm(
            id: "synthetic-arm", configurationID: "config", sourceBindingIDs: ["synthetic-calendar"],
            targetBindingID: "target", ruleMode: .busy,
            padding: ArmPadding(beforeMinutes: 60, afterMinutes: 60, inPersonOnly: false))
        let meeting = [event(from: 780, to: 840)]
        func longest(_ instances: [StoredNormalizedInstance]) throws -> TimeInterval {
            try AvailabilityCalculator.calculate(
                instances: instances, from: day.start, through: day.end,
                workingHours: everyDay(540, 1_020), timeZone: utc).longestFree(in: day)
        }

        #expect(try longest(meeting) == 14_400)
        #expect(try longest(AvailabilityCalculator.withPadding(meeting, arms: [arm])) == 10_800)
    }

    @Test("Days with a clock change are 23 or 25 hours long", arguments: [(3, 8, 23.0), (11, 1, 25.0)])
    func clockChange(month: Int, dayOfMonth: Int, hours: Double) throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(year: 2026, month: month, day: dayOfMonth))!
        let wholeDay = DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)

        let result = AvailabilityCalculator.calculate(
            instances: [], from: wholeDay.start, through: wholeDay.end,
            workingHours: try everyDay(0, 1_440), timeZone: zone)

        #expect(result.longestFree(in: wholeDay) == hours * 3_600)
        #expect(!result.lacksFocus(in: wholeDay, length: hours * 3_600))
        #expect(result.lacksFocus(in: wholeDay, length: hours * 3_600 + 1))
    }

    private func everyDay(_ start: Int, _ end: Int) throws -> WorkingHours {
        try WorkingHours(days: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, try WorkingHours.Day(startMinute: start, endMinute: end)) }))
    }

    private func event(from start: Int, to end: Int) -> StoredNormalizedInstance {
        StoredNormalizedInstance(
            sourceKeyHash: "synthetic-\(start)", connectionID: "connection", calendarBindingID: "synthetic-calendar",
            providerEventID: "synthetic-\(start)", recurrenceID: nil,
            startsAt: midnight.addingTimeInterval(TimeInterval(start * 60)),
            endsAt: midnight.addingTimeInterval(TimeInterval(end * 60)),
            isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false,
            title: "Synthetic event", contentFingerprint: "fingerprint-\(start)", providerUpdatedAt: nil)
    }
}
