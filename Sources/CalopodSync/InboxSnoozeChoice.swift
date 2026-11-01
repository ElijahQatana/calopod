import Foundation

/// Where a snooze ends. Later today is three hours on, but not past midnight; the other two are 8:00.
public enum InboxSnoozeChoice: Equatable, Sendable {
    case laterToday, tomorrow, day(Date)

    static let morningHour = 8

    /// Nil when that moment is not ahead of `now`, such as a day that is already over.
    public func until(from now: Date, calendar: Calendar = .current) -> Date? {
        let morning = { (day: Date) in calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: day) }
        let end: Date?
        switch self {
        case .laterToday:
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            end = midnight.map { min(now.addingTimeInterval(3 * 3600), $0.addingTimeInterval(-1)) }
        case .tomorrow:
            end = calendar.date(byAdding: .day, value: 1, to: now).flatMap(morning)
        case .day(let day):
            end = morning(day)
        }
        return end.flatMap { $0 > now ? $0 : nil }
    }
}
