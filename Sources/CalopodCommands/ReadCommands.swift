import ArgumentParser
import CalopodStore
import Foundation

public struct CalendarsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List selectable calendars."
    )

    @OptionGroup public var output: OutputOptions

    @Option(name: .long, help: "Logical Connection identifier. Uses the only Google Connection when omitted.")
    public var connection: String?

    public init() {}

    public func run() async throws {
        do {
            let repository = try CommandEnvironment.repository()
            let selected = try selectedGoogleConnection(id: connection, repository: repository)
            let calendars = try await CommandEnvironment.googleService().refreshCalendars(
                connectionID: selected.id
            )
            try OutputRenderer.write(
                command: "calendars",
                payload: CommandPayload(
                    status: "ok",
                    message: calendars.isEmpty ? "No calendars were found." : "Selectable calendars.",
                    count: calendars.count,
                    items: calendars.map {
                        CommandItem(
                            id: $0.id,
                            kind: "calendar",
                            label: $0.displayLabel,
                            parentID: $0.connectionID,
                            selected: $0.isSelected,
                            readOnly: $0.isReadOnly
                        )
                    }
                ),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }

}

public struct EventsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List normalized events for a day or range."
    )

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    @Option(name: .long, help: "Logical Connection identifier. Uses the only Google Connection when omitted.")
    public var connection: String?

    @Option(name: .long, help: "Calendar identifier from the calendars command. Uses the only selected calendar when omitted.")
    public var calendar: String?

    public init() {}

    public func run() async throws {
        let resolved = try resolveRange(range, default: .currentDay)
        guard let resolved else { return }
        do {
            let repository = try CommandEnvironment.repository()
            let selectedConnection = try selectedGoogleConnection(
                id: connection,
                repository: repository
            )
            let selectedCalendar = try selectedCalendarBinding(
                id: calendar,
                connectionID: selectedConnection.id,
                repository: repository
            )
            let page = try await CommandEnvironment.googleService().events(
                connectionID: selectedConnection.id,
                binding: selectedCalendar,
                from: resolved.window.start,
                through: resolved.window.end,
                useIncrementalRefresh: false
            )
            try OutputRenderer.write(
                command: "events",
                payload: CommandPayload(
                    status: "ok",
                    message: page.events.isEmpty ? "No events were found." : "Events in the requested range.",
                    count: page.events.count,
                    range: RangeOutput(range: resolved),
                    items: page.events.map {
                        CommandItem(
                            id: $0.eventID,
                            kind: "event",
                            label: $0.title,
                            parentID: selectedCalendar.id,
                            startsAt: outputDate($0.start),
                            endsAt: outputDate($0.end),
                            allDay: $0.isAllDay,
                            cancelled: $0.isCancelled,
                            availability: $0.availability.rawValue
                        )
                    }
                ),
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }
}

private func outputDate(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
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
