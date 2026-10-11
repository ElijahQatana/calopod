import CalopodDomain
import Foundation
import Testing

@Suite("All-day dates")
struct AllDayDateTests {
    // Midnight to midnight in the zone, for the day after the given one.
    @Test("The day is read in the source zone", arguments: [
        ("Asia/Tokyo", 2026, 10, 5, "2026-10-05", "2026-10-06"),
        ("Europe/Paris", 2026, 10, 5, "2026-10-05", "2026-10-06"),
        ("America/Los_Angeles", 2026, 10, 5, "2026-10-05", "2026-10-06"),
        ("Europe/Paris", 2026, 10, 25, "2026-10-25", "2026-10-26"),
        ("America/New_York", 2026, 11, 1, "2026-11-01", "2026-11-02"),
        ("Asia/Tokyo", 2026, 12, 31, "2026-12-31", "2027-01-01"),
    ])
    func zoneDays(zone: String, year: Int, month: Int, day: Int, start: String, end: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        let first = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        let next = calendar.date(byAdding: .day, value: 1, to: first)!

        let days = AllDayDate.days(startsAt: first, endsAt: next, timeZoneIdentifier: zone)

        #expect(days.start == start)
        #expect(days.end == end)
    }

    @Test("Without a zone the day is read in UTC")
    func utcFallback() {
        let first = Date(timeIntervalSince1970: 1_790_035_200)
        let days = AllDayDate.days(startsAt: first, endsAt: first.addingTimeInterval(86_400), timeZoneIdentifier: nil)
        #expect(days.start < days.end)
        #expect(AllDayDate.midnight(of: days.start, in: .gmt) == first)
    }
}
