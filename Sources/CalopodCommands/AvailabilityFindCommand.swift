import ArgumentParser
import CalopodDomain
import CalopodSync
import Foundation

/// Lists the free windows long enough for a meeting, from the same calculation as `availability show`.
public struct AvailabilityFindCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "List free windows of at least a given length.",
        discussion: "Looks from now. Without --within, --day or --from and --through, it looks 7 days ahead."
    )

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    @Option(name: .long, help: "How long the window must be, such as 45m or 2h.")
    public var duration: String

    @Option(name: .long, help: "How far ahead to look, such as 5d or 36h.")
    public var within: String?

    @Flag(name: .long, help: "Read retained local data without refreshing sources.")
    public var cached = false

    @Option(name: .long, help: "Limit the search to one Connection identifier.")
    public var connection: String?

    @Option(name: .long, help: "Limit the search to one selected calendar identifier.")
    public var calendar: String?

    @Flag(name: .long, help: "Count free time all day instead of only inside working hours (see `calopod hours`).")
    public var ignoreWorkingHours = false

    @Flag(name: .long, help: "Copy the windows as plain text for a message.")
    public var copy = false

    public init() {}

    public func validate() throws {
        guard FindSpan(duration)?.seconds != nil else {
            throw ValidationError("--duration must be a length such as 45m or 2h.")
        }
        if let within {
            guard let span = FindSpan(within), span.unit != .minute, span.count <= (span.unit == .day ? 366 : 8_784) else {
                throw ValidationError("--within must be a span such as 5d or 36h, up to 366 days.")
            }
            if range.day != nil || range.from != nil || range.through != nil {
                throw ValidationError("--within cannot be combined with --day, --from or --through.")
            }
        }
    }

    public func run() async throws {
        guard let length = FindSpan(duration)?.seconds else { return }
        do {
            let resolved = try window(now: Date())
            let read = try await calendarCommandRead(
                environment: CommandEnvironment.runtimeEnvironment(),
                cached: cached, connectionID: connection, calendarID: calendar, range: resolved
            )
            defer { withExtendedLifetime(read) {} }
            let repository = read.repository
            let sources = read.sources
            let refresh = read.refresh
            let events = try repository.normalizedInstances(
                calendarBindingIDs: sources.map(\.calendar.id),
                from: resolved.window.start,
                through: resolved.window.end
            )
            let availability = AvailabilityCalculator.calculate(
                instances: AvailabilityCalculator.withPadding(events, arms: try repository.arms()),
                from: resolved.window.start,
                through: resolved.window.end,
                workingHours: ignoreWorkingHours ? nil : try repository.workingHours(),
                timeZone: TimeZone(identifier: resolved.timeZoneIdentifier) ?? .current
            )
            let windows = availability.freeWindows(atLeast: length, after: Date())
            let items = Self.items(windows)
            try OutputRenderer.write(
                command: "availability.find",
                payload: CommandPayload(
                    status: cached || refresh.failedSourceCount != 0 ? "partial" : "ok",
                    message: items.isEmpty
                        ? "No free window of \(AvailabilityShowCommand.duration(length)) was found."
                        : "Free windows of at least \(AvailabilityShowCommand.duration(length)).",
                    count: items.count,
                    range: RangeOutput(range: resolved),
                    sources: commandSources(sources, names: CalendarNames(repository)),
                    items: items,
                    ingestion: refresh.ingestion,
                    lengthSeconds: Int(length)
                ),
                warnings: refresh.warnings,
                format: output.format,
                showIDs: output.ids,
                human: output.localContext(repository: repository)
            )
            if copy {
                let zone = TimeZone(identifier: resolved.timeZoneIdentifier) ?? .current
                let note = Self.copyNote(windows, timeZone: zone, copier: Pasteboard.copy)
                // Keep JSON on stdout as it is.
                if output.format == .json {
                    try? FileHandle.standardError.write(contentsOf: Data((note + "\n").utf8))
                } else {
                    print(note)
                }
            }
        } catch {
            try failCommand(error, format: output.format)
        }
    }

    /// The range to read: `--within` from now, the date options, or a week from now.
    func window(now: Date) throws -> ResolvedDateRange {
        if within == nil, let resolved = try resolveRange(range, default: .none) { return resolved }
        var timeZone = TimeZone.current
        if let name = range.timezone {
            guard let named = TimeZone(identifier: name) else {
                throw ValidationError(DateRangeInputError.invalidTimeZone(name).description)
            }
            timeZone = named
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let span = FindSpan(within ?? "7d"), let end = span.end(from: now, calendar: calendar) else {
            throw ValidationError("--within must be a span such as 5d or 36h.")
        }
        return ResolvedDateRange(window: try SyncWindow(start: now, end: end), timeZoneIdentifier: timeZone.identifier)
    }

    /// The text to print, with whether it reached the clipboard.
    static func copyNote(_ windows: [AvailabilityInterval], timeZone: TimeZone, copier: (String) -> Bool) -> String {
        guard !windows.isEmpty else { return "No free windows, so nothing was copied." }
        let text = FreeSlotText.text(windows, timeZone: timeZone)
        return text + "\n" + (copier(text) ? "Copied to the clipboard." : "No clipboard tool was found, so nothing was copied.")
    }

    static func items(_ windows: [AvailabilityInterval]) -> [CommandItem] {
        windows.enumerated().map { index, window in
            CommandItem(
                id: "availability-free-\(index + 1)", kind: "availability", label: "Free",
                startsAt: outputDate(window.start), endsAt: outputDate(window.end), availability: "free")
        }
    }
}
