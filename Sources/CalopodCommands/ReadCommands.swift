import ArgumentParser

public struct CalendarsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List selectable calendars."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try OutputRenderer.write(
            command: "calendars",
            payload: CommandPayload(status: "ok", message: "No calendars are connected.", count: 0),
            format: output.format
        )
    }
}

public struct EventsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List normalized events for a day or range."
    )

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        let resolved = try resolveRange(range, default: .currentDay)
        try OutputRenderer.write(
            command: "events",
            payload: CommandPayload(
                status: "ok",
                message: "No events are available.",
                count: 0,
                range: resolved.map(RangeOutput.init)
            ),
            format: output.format
        )
    }
}

public struct AvailabilityCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "availability",
        abstract: "Show combined busy and free intervals for a day or range."
    )

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        let resolved = try resolveRange(range, default: .currentDay)
        try OutputRenderer.write(
            command: "availability",
            payload: CommandPayload(
                status: "ok",
                message: "No Availability sources are configured.",
                count: 0,
                range: resolved.map(RangeOutput.init)
            ),
            format: output.format
        )
    }
}

func resolveRange(
    _ options: DateRangeOptions,
    default defaultBehavior: DateRangeDefault
) throws -> ResolvedDateRange? {
    do {
        return try options.resolve(default: defaultBehavior)
    } catch let error as DateRangeInputError {
        throw ValidationError(error.description)
    }
}
