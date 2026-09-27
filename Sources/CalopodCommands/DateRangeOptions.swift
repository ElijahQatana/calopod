import ArgumentParser
import CalopodDomain
import Foundation

public enum DateRangeDefault: Sendable {
    case currentDay
    case none
}

public enum DateRangeInputError: Error, Equatable, CustomStringConvertible {
    case conflictingDayAndRange
    case incompleteRange
    case invalidDate(String)
    case invalidTimestamp(String)
    case invalidTimeZone(String)
    case endMustFollowStart

    public var description: String {
        switch self {
        case .conflictingDayAndRange:
            "--day cannot be combined with --from or --through."
        case .incompleteRange:
            "--from and --through must be supplied together."
        case let .invalidDate(value):
            "Invalid date '\(value)'. Use YYYY-MM-DD."
        case let .invalidTimestamp(value):
            "Invalid timestamp '\(value)'. Use RFC 3339 with a UTC offset."
        case let .invalidTimeZone(value):
            "Unknown timezone '\(value)'. Use an IANA timezone such as America/New_York."
        case .endMustFollowStart:
            "The through boundary must be later than the from boundary."
        }
    }
}

/// A validated `SyncWindow` plus the timezone identifier it was resolved
/// against — kept alongside the window so a caller can echo back which
/// timezone date-only input was interpreted in.
public struct ResolvedDateRange: Equatable, Sendable {
    public let window: SyncWindow
    public let timeZoneIdentifier: String

    public init(window: SyncWindow, timeZoneIdentifier: String) {
        self.window = window
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

/// The `--day` / `--from` / `--through` / `--timezone` flags shared by every
/// command that operates over a date range, so each command gets identical
/// parsing and error messages instead of reimplementing this itself.
public struct DateRangeOptions: ParsableArguments {
    @Option(name: .long, help: "One local calendar day in YYYY-MM-DD form.")
    public var day: String?

    @Option(name: .long, help: "Inclusive date or exact RFC 3339 timestamp.")
    public var from: String?

    @Option(name: .long, help: "Inclusive date or exact RFC 3339 timestamp.")
    public var through: String?

    @Option(name: .long, help: "IANA timezone used for date-only input.")
    public var timezone: String?

    public init() {}

    public func resolve(
        default defaultBehavior: DateRangeDefault,
        now: Date = Date(),
        systemTimeZone: TimeZone = .current
    ) throws -> ResolvedDateRange? {
        try DateRangeResolver(
            day: day,
            from: from,
            through: through,
            timezone: timezone
        ).resolve(default: defaultBehavior, now: now, systemTimeZone: systemTimeZone)
    }
}

/// The actual parsing and validation behind `DateRangeOptions`, split out so
/// it can be tested directly against raw string input without going through
/// ArgumentParser.
public struct DateRangeResolver: Sendable {
    public let day: String?
    public let from: String?
    public let through: String?
    public let timezone: String?

    public init(
        day: String? = nil,
        from: String? = nil,
        through: String? = nil,
        timezone: String? = nil
    ) {
        self.day = day
        self.from = from
        self.through = through
        self.timezone = timezone
    }

    public func resolve(
        default defaultBehavior: DateRangeDefault,
        now: Date = Date(),
        systemTimeZone: TimeZone = .current
    ) throws -> ResolvedDateRange? {
        // `--day` and `--from`/`--through` are two different ways to express
        // the same window; accepting both would leave an ambiguous case
        // (which one wins if they disagree), so it's rejected outright
        // instead of picking a winner silently.
        if day != nil, from != nil || through != nil {
            throw DateRangeInputError.conflictingDayAndRange
        }

        if (from == nil) != (through == nil) {
            throw DateRangeInputError.incompleteRange
        }

        let selectedTimeZone = try resolveTimeZone(systemTimeZone: systemTimeZone)

        if let day {
            let start = try startOfDate(day, in: selectedTimeZone)
            let end = try nextDay(after: start, in: selectedTimeZone)
            return try resolved(start: start, end: end, timeZone: selectedTimeZone)
        }

        if let from, let through {
            let start = try lowerBoundary(from, in: selectedTimeZone)
            let end = try upperBoundary(through, in: selectedTimeZone)
            return try resolved(start: start, end: end, timeZone: selectedTimeZone)
        }

        switch defaultBehavior {
        case .currentDay:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = selectedTimeZone
            let start = calendar.startOfDay(for: now)
            let end = try nextDay(after: start, in: selectedTimeZone)
            return try resolved(start: start, end: end, timeZone: selectedTimeZone)
        case .none:
            return nil
        }
    }

    private func resolveTimeZone(systemTimeZone: TimeZone) throws -> TimeZone {
        guard let timezone else {
            return systemTimeZone
        }

        guard let value = TimeZone(identifier: timezone) else {
            throw DateRangeInputError.invalidTimeZone(timezone)
        }

        return value
    }

    private func lowerBoundary(_ value: String, in timeZone: TimeZone) throws -> Date {
        if isDateOnly(value) {
            return try startOfDate(value, in: timeZone)
        }
        return try timestamp(value)
    }

    private func upperBoundary(_ value: String, in timeZone: TimeZone) throws -> Date {
        if isDateOnly(value) {
            return try nextDay(after: startOfDate(value, in: timeZone), in: timeZone)
        }
        return try timestamp(value)
    }

    private func startOfDate(_ value: String, in timeZone: TimeZone) throws -> Date {
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces[0].count == 4,
              pieces[1].count == 2,
              pieces[2].count == 2,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]) else {
            throw DateRangeInputError.invalidDate(value)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day
        )

        guard let date = calendar.date(from: components) else {
            throw DateRangeInputError.invalidDate(value)
        }

        // `Calendar.date(from:)` normalizes an out-of-range day (e.g.
        // 2026-02-30) into the nearest valid date rather than failing, so the
        // result is converted back to components and compared against the
        // original input to catch exactly that case.
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == year, verified.month == month, verified.day == day else {
            throw DateRangeInputError.invalidDate(value)
        }

        return date
    }

    // An RFC 3339 timestamp must carry its own UTC offset — one that's
    // missing would force a silent guess at which timezone it means, which
    // is exactly the ambiguity a full timestamp (as opposed to a bare date)
    // is supposed to remove.
    private func timestamp(_ value: String) throws -> Date {
        guard value.contains("T"), hasExplicitOffset(value) else {
            throw DateRangeInputError.invalidTimestamp(value)
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        guard let date = wholeSeconds.date(from: value) else {
            throw DateRangeInputError.invalidTimestamp(value)
        }

        return date
    }

    private func nextDay(after date: Date, in timeZone: TimeZone) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let result = calendar.date(byAdding: .day, value: 1, to: date) else {
            throw DateRangeInputError.invalidDate("out of range")
        }
        return result
    }

    private func resolved(start: Date, end: Date, timeZone: TimeZone) throws -> ResolvedDateRange {
        guard end > start else {
            throw DateRangeInputError.endMustFollowStart
        }

        return ResolvedDateRange(
            window: try SyncWindow(start: start, end: end),
            timeZoneIdentifier: timeZone.identifier
        )
    }

    private func isDateOnly(_ value: String) -> Bool {
        !value.contains("T")
    }

    private func hasExplicitOffset(_ value: String) -> Bool {
        if value.hasSuffix("Z") {
            return true
        }

        return value.range(
            of: #"[+-][0-9]{2}:[0-9]{2}$"#,
            options: .regularExpression
        ) != nil
    }
}
