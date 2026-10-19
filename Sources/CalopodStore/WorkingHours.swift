import Foundation
import GRDB

public enum WorkingHoursError: Error, Equatable, LocalizedError {
    case invalidWeekday
    case invalidTimes

    public var errorDescription: String? {
        switch self {
        case .invalidWeekday: "Weekdays are numbered 1 (Monday) to 7 (Sunday)."
        case .invalidTimes: "A working day has to end after it starts, and stay within one day."
        }
    }
}

/// The hours a person is available each weekday, in their local time zone. Kept in the local state
/// so the Mac app and the command line share one copy. A day is either a start and end in minutes
/// after midnight, or a day off.
public struct WorkingHours: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        public let startMinute: Int
        public let endMinute: Int

        public init(startMinute: Int, endMinute: Int) throws {
            guard (0...1440).contains(startMinute), (0...1440).contains(endMinute), startMinute < endMinute else {
                throw WorkingHoursError.invalidTimes
            }
            self.startMinute = startMinute
            self.endMinute = endMinute
        }
    }

    /// Weekdays run from 1 (Monday) to 7 (Sunday).
    public let days: [Int: Day]

    /// Weekdays missing from `days` are days off.
    public init(days: [Int: Day]) throws {
        guard days.keys.allSatisfy({ (1...7).contains($0) }) else { throw WorkingHoursError.invalidWeekday }
        self.days = days
    }

    /// Monday to Friday, 9:00 to 17:00.
    public static let standard = try! WorkingHours(
        days: Dictionary(uniqueKeysWithValues: (1...5).map { ($0, try! Day(startMinute: 540, endMinute: 1020)) }))

    public func day(isoWeekday: Int) -> Day? { days[isoWeekday] }

    /// A copy with one weekday replaced, or turned into a day off when `day` is nil.
    public func setting(isoWeekday: Int, to day: Day?) throws -> WorkingHours {
        var updated = days
        updated[isoWeekday] = day
        return try WorkingHours(days: updated)
    }

    /// Monday is 1 and Sunday is 7, whatever the calendar's first weekday is.
    public static func isoWeekday(of date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// The working window of the local day that starts at `dayStart`, or nil on a day off.
    public func window(forDayStarting dayStart: Date, calendar: Calendar) -> DateInterval? {
        guard let day = days[Self.isoWeekday(of: dayStart, calendar: calendar)] else { return nil }
        // Wall-clock times, so a day with a clock change still starts and ends at the same hours.
        guard let start = wallClock(day.startMinute, on: dayStart, calendar: calendar),
              let end = wallClock(day.endMinute, on: dayStart, calendar: calendar), start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    private func wallClock(_ minute: Int, on dayStart: Date, calendar: Calendar) -> Date? {
        if minute == 1440 { return calendar.date(byAdding: .day, value: 1, to: dayStart) }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart)
    }
}

extension LocalStateRepository {
    /// The saved hours, or Monday to Friday 9:00 to 17:00 when nothing was saved or the saved rows
    /// cannot be used.
    public func workingHours() throws -> WorkingHours {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT weekday, start_minute, end_minute FROM working_hours")
            guard !rows.isEmpty else { return .standard }
            var days: [Int: WorkingHours.Day] = [:]
            for row in rows {
                guard let start: Int = row["start_minute"], let end: Int = row["end_minute"] else { continue }
                guard let day = try? WorkingHours.Day(startMinute: start, endMinute: end) else { return .standard }
                days[row["weekday"]] = day
            }
            return (try? WorkingHours(days: days)) ?? .standard
        }
    }

    public func saveWorkingHours(_ hours: WorkingHours) throws {
        try database.write { db in
            for weekday in 1...7 {
                let day = hours.day(isoWeekday: weekday)
                try db.execute(sql: """
                    INSERT INTO working_hours (weekday, start_minute, end_minute) VALUES (?, ?, ?)
                    ON CONFLICT(weekday) DO UPDATE SET start_minute = excluded.start_minute,
                        end_minute = excluded.end_minute
                    """, arguments: [weekday, day?.startMinute, day?.endMinute])
            }
        }
    }
}
