import Foundation

/// All-day events are stored as midnight instants in the source's own zone,
/// so the calendar day has to be read back in that zone. Without a zone the
/// day is read in UTC, which is what the writers did before zones were kept.
public enum AllDayDate {
    public static func days(
        startsAt: Date,
        endsAt: Date,
        timeZoneIdentifier: String?
    ) -> (start: String, end: String) {
        let zone = timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .gmt
        return (day(startsAt, in: zone), day(endsAt, in: zone))
    }

    /// Midnight of a `yyyy-MM-dd` day in the given zone.
    public static func midnight(of day: String, in zone: TimeZone) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func day(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
