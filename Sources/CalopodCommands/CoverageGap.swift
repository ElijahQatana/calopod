import Foundation

/// Words for the part of a date range a calendar's last read does not reach. The Mac app and the
/// command line both use it, so they report the same gap.
public enum CoverageGap {
    /// Nil when the read spans the whole range.
    public static func describe(
        read coverage: ClosedRange<Date>, range: Range<Date>, timeZone: TimeZone = .current
    ) -> String? {
        let startsLate = coverage.lowerBound > range.lowerBound
        let endsEarly = coverage.upperBound < range.upperBound
        switch (startsLate, endsEarly) {
        case (false, false): return nil
        case (true, false):
            return "read from \(label(coverage.lowerBound, timeZone)), these dates start earlier"
        case (false, true):
            return "read until \(label(coverage.upperBound, timeZone)), these dates run later"
        case (true, true):
            return "read from \(label(coverage.lowerBound, timeZone)) until \(label(coverage.upperBound, timeZone)), which is less than these dates"
        }
    }

    private static func label(_ date: Date, _ timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = calendar.startOfDay(for: date) == date ? "MMM d" : "MMM d HH:mm"
        return formatter.string(from: date)
    }
}
