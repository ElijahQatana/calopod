@testable import CalopodCommands
import Foundation
import Testing

@Suite struct CoverageGapTests {
    private let zone = TimeZone(identifier: "UTC")!
    private func day(_ day: Int, _ hour: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test(arguments: [
        (11, 0, 30, 0, nil as String?),
        (18, 0, 25, 0, nil),
        (18, 19, 30, 0, "read from Oct 18 19:00, these dates start earlier"),
        (11, 0, 23, 0, "read until Oct 23, these dates run later"),
        (19, 0, 21, 0, "read from Oct 19 until Oct 21, which is less than these dates"),
    ])
    func describesOnlyWhatIsMissing(from: Int, fromHour: Int, to: Int, toHour: Int, expected: String?) {
        let text = CoverageGap.describe(read: day(from, fromHour)...day(to, toHour), range: day(18)..<day(25), timeZone: zone)
        #expect(text == expected)
    }
}
