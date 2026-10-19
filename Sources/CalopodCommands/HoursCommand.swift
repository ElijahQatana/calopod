import ArgumentParser
import CalopodStore
import Foundation

/// The working hours as `calopod hours --format json` prints them.
public struct WorkingHoursOutput: Codable, Equatable, Sendable {
    public struct Day: Codable, Equatable, Sendable {
        public let weekday: String
        public let working: Bool
        public let start: String?
        public let end: String?
    }

    public let timeZone: String
    public let days: [Day]

    public init(_ hours: WorkingHours, timeZone: TimeZone = .current) {
        self.timeZone = timeZone.identifier
        days = (1...7).map { weekday in
            let day = hours.day(isoWeekday: weekday)
            return Day(
                weekday: HoursText.names[weekday - 1], working: day != nil,
                start: day.map { HoursText.clock($0.startMinute) }, end: day.map { HoursText.clock($0.endMinute) })
        }
    }
}

/// A working window as availability prints it, in UTC like the other times.
public struct WorkingWindowOutput: Codable, Equatable, Sendable {
    public let startsAt: String
    public let endsAt: String
}

enum HoursText {
    static let names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    /// "09:00" or "9:30", up to "24:00".
    static func minute(_ text: String) throws -> Int {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...59).contains(minute), (0...24).contains(hour), hour * 60 + minute <= 1440 else {
            throw ValidationError("Invalid time '\(text)'. Use HH:MM, such as 09:00.")
        }
        return hour * 60 + minute
    }

    /// Day names or three-letter short forms, ranges such as mon-fri, and the words weekdays,
    /// weekend and all, separated by commas.
    static func weekdays(_ text: String) throws -> Set<Int> {
        func number(_ word: Substring) throws -> Int {
            let lower = word.lowercased()
            guard lower.count >= 3, let index = names.firstIndex(where: { $0.hasPrefix(lower) }) else {
                throw ValidationError("Unknown day '\(word)'. Use monday to sunday, or mon-fri, weekdays, weekend or all.")
            }
            return index + 1
        }
        var result = Set<Int>()
        for part in text.split(separator: ",") {
            switch part.lowercased() {
            case "weekdays": result.formUnion(1...5)
            case "weekend": result.formUnion(6...7)
            case "all": result.formUnion(1...7)
            default:
                let ends = part.split(separator: "-")
                guard (1...2).contains(ends.count) else { throw ValidationError("Unknown day '\(part)'.") }
                let first = try number(ends[0]), last = try number(ends[ends.count - 1])
                guard first <= last else { throw ValidationError("The range '\(part)' must go forward within one week.") }
                result.formUnion(first...last)
            }
        }
        guard !result.isEmpty else { throw ValidationError("Give at least one day.") }
        return result
    }

    static func lines(_ hours: WorkingHours, timeZone: TimeZone = .current) -> [String] {
        (1...7).map { weekday in
            let name = names[weekday - 1].capitalized
            guard let day = hours.day(isoWeekday: weekday) else { return "\(name): day off" }
            return "\(name): \(clock(day.startMinute)) to \(clock(day.endMinute))"
        } + ["Times are in your local time zone (\(timeZone.identifier)). Availability counts free time only inside these hours."]
    }
}

public struct HoursCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hours",
        abstract: "Show or change working hours.",
        discussion: "Working hours are per weekday, in your local time zone. `calopod availability` counts free time only inside them. The Calopod app uses the same hours.",
        subcommands: [HoursSetCommand.self])

    @OptionGroup public var output: OutputOptions
    public init() {}

    public func run() async throws {
        do {
            try writeHours(try CommandEnvironment.repository().workingHours(), message: nil, format: output.format)
        } catch { try failCommand(error, format: output.format) }
    }
}

public struct HoursSetCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change working hours for some days.",
        discussion: "Days are names or short forms, ranges such as mon-fri, or the words weekdays, weekend and all, separated by commas. Example: calopod hours set --days mon-thu --start 08:30 --end 17:00")

    @Option(name: .long, help: "The days to change, such as mon-fri or sat,sun.")
    public var days: String
    @Option(name: .long, help: "When work starts, as HH:MM.") public var start: String?
    @Option(name: .long, help: "When work ends, as HH:MM.") public var end: String?
    @Flag(name: .long, help: "Make these days days off.") public var off = false
    @OptionGroup public var output: OutputOptions
    public init() {}

    public func validate() throws {
        if off && (start != nil || end != nil) { throw ValidationError("--off cannot be combined with --start or --end.") }
        if !off && start == nil && end == nil { throw ValidationError("Nothing to change. Give --start, --end or --off.") }
    }

    /// The hours after applying these options. A day that was off needs both times.
    func resolve(_ current: WorkingHours) throws -> WorkingHours {
        var updated = current
        let start = try self.start.map(HoursText.minute), end = try self.end.map(HoursText.minute)
        for weekday in try HoursText.weekdays(days).sorted() {
            if off {
                updated = try updated.setting(isoWeekday: weekday, to: nil)
                continue
            }
            let existing = current.day(isoWeekday: weekday)
            guard let from = start ?? existing?.startMinute, let to = end ?? existing?.endMinute else {
                throw ValidationError("\(HoursText.names[weekday - 1].capitalized) is a day off, so give both --start and --end.")
            }
            updated = try updated.setting(isoWeekday: weekday, to: WorkingHours.Day(startMinute: from, endMinute: to))
        }
        return updated
    }

    public func run() async throws {
        do {
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let state = try CommandEnvironment.repository()
            let hours = try resolve(state.workingHours())
            try state.saveWorkingHours(hours)
            try writeHours(hours, message: "Saved. The Calopod app picks the change up the next time it refreshes.", format: output.format)
        } catch { try failCommand(error, format: output.format) }
    }
}

private func writeHours(_ hours: WorkingHours, message: String?, format: OutputFormat) throws {
    try OutputRenderer.write(
        command: "hours",
        payload: CommandPayload(status: "ok", message: message ?? "Working hours.", workingHours: WorkingHoursOutput(hours)),
        format: format, human: HumanOutputContext(footer: HoursText.lines(hours)))
}
