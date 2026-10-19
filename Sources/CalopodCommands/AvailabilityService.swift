import CalopodStore
import CalopodSync
import Foundation

/// One day of availability, from the same calculation `calopod availability` uses.
public struct AvailabilityDayReport: Equatable, Sendable {
    public let day: DateInterval
    public let result: AvailabilityResult
    public let summary: AvailabilityDay
}

/// Reads the local copy and works out availability for whole days, using the saved working hours.
/// It never contacts a provider, like `calopod availability --cached`.
public struct AvailabilityService: Sendable {
    private let makeRepository: @Sendable () throws -> LocalStateRepository

    public init() { makeRepository = { try CommandEnvironment.repository() } }

    init(makeRepository: @escaping @Sendable () throws -> LocalStateRepository) { self.makeRepository = makeRepository }

    /// `days` are local day starts in `calendar`'s time zone.
    public func report(days: [Date], calendar: Calendar = .current) throws -> [AvailabilityDayReport] {
        let repository = try makeRepository()
        let hours = try repository.workingHours()
        let sources = try selectedCalendarSources(connectionID: nil, calendarID: nil, repository: repository)
        let ranges = days.compactMap { start -> DateInterval? in
            calendar.date(byAdding: .day, value: 1, to: start).map { DateInterval(start: start, end: $0) }
        }
        guard let first = ranges.map(\.start).min(), let last = ranges.map(\.end).max() else { return [] }
        let instances = try repository.normalizedInstances(
            calendarBindingIDs: sources.map(\.calendar.id), from: first, through: last)
        return ranges.map { range in
            let result = AvailabilityCalculator.calculate(
                instances: instances, from: range.start, through: range.end,
                workingHours: hours, timeZone: calendar.timeZone)
            return AvailabilityDayReport(day: range, result: result, summary: AvailabilityDay(result, day: range))
        }
    }
}
