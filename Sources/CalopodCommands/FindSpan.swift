import Foundation

/// A length such as "45m", "2h" or "5d": a whole number and one unit.
public struct FindSpan: Equatable, Sendable {
    public enum Unit: Character, Sendable {
        case minute = "m"
        case hour = "h"
        case day = "d"
    }

    public let count: Int
    public let unit: Unit

    public init?(_ text: String) {
        guard let last = text.last, let unit = Unit(rawValue: last),
              let count = Int(text.dropLast()), count > 0, count <= 100_000 else { return nil }
        self.count = count
        self.unit = unit
    }

    /// Minutes and hours only; a day has no fixed length.
    public var seconds: TimeInterval? {
        switch unit {
        case .minute: TimeInterval(count * 60)
        case .hour: TimeInterval(count * 3_600)
        case .day: nil
        }
    }

    public func end(from start: Date, calendar: Calendar) -> Date? {
        switch unit {
        case .minute: calendar.date(byAdding: .minute, value: count, to: start)
        case .hour: calendar.date(byAdding: .hour, value: count, to: start)
        case .day: calendar.date(byAdding: .day, value: count, to: start)
        }
    }
}
