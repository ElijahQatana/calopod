import ArgumentParser
import CalopodStore
import Foundation

public struct CalendarsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List selectable calendars."
    )

    @OptionGroup public var output: OutputOptions

    @Option(name: .long, help: "Logical Connection identifier. Uses the only supported Connection when omitted.")
    public var connection: String?

    @Option(name: .long, help: "Select one calendar identifier returned by this command.")
    public var select: String?

    @Option(name: .long, help: "Deselect one calendar identifier returned by this command.")
    public var deselect: String?

    public init() {}

    public func run() async throws {
        do {
            let repository = try CommandEnvironment.repository()
            let selected = try selectedConnection(id: connection, repository: repository)
            let calendars = try await refreshCalendars(for: selected)
            if select != nil, deselect != nil {
                throw ValidationError("Use either --select or --deselect, not both.")
            }
            if let calendarID = select ?? deselect {
                guard let calendar = calendars.first(where: { $0.id == calendarID }) else {
                    throw ValidationError("Calendar '\(calendarID)' was not found on that Connection.")
                }
                let shouldSelect = select != nil
                if shouldSelect,
                   let conflict = try CalendarSelectionSafety.conflictMessage(
                       selecting: calendar,
                       on: selected,
                       repository: repository
                   ) {
                    throw ValidationError(conflict)
                }
                guard let updated = try repository.setCalendarSelection(
                    id: calendar.id,
                    isSelected: shouldSelect
                ) else {
                    throw ValidationError("Calendar '\(calendarID)' was not found on that Connection.")
                }
                try OutputRenderer.write(
                    command: "calendars",
                    payload: CommandPayload(
                        status: "ok",
                        message: shouldSelect ? "Selected the calendar." : "Deselected the calendar.",
                        count: 1,
                        items: [calendarItem(updated)]
                    ),
                    format: output.format
                )
                return
            }
            let warnings = try CalendarSelectionSafety.warnings(
                for: calendars,
                connection: selected,
                repository: repository
            )
            try OutputRenderer.write(
                command: "calendars",
                payload: CommandPayload(
                    status: "ok",
                    message: calendars.isEmpty ? "No calendars were found." : "Selectable calendars.",
                    count: calendars.count,
                    items: calendars.map(calendarItem)
                ),
                warnings: warnings,
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

    @Option(name: .long, help: "Logical Connection identifier. Uses the only supported Connection when omitted.")
    public var connection: String?

    @Option(name: .long, help: "Calendar identifier from the calendars command. Uses the only selected calendar when omitted.")
    public var calendar: String?

    public init() {}

    public func run() async throws {
        let resolved = try resolveRange(range, default: .currentDay)
        guard let resolved else { return }
        do {
            let repository = try CommandEnvironment.repository()
            let selectedConnection = try selectedConnection(
                id: connection,
                repository: repository
            )
            let selectedCalendar = try selectedCalendarBinding(
                id: calendar,
                connectionID: selectedConnection.id,
                repository: repository
            )
            let page = try await readEvents(
                connection: selectedConnection,
                binding: selectedCalendar,
                start: resolved.window.start,
                end: resolved.window.end
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

private func calendarItem(_ binding: StoredCalendarBinding) -> CommandItem {
    CommandItem(
        id: binding.id,
        kind: "calendar",
        label: binding.displayLabel,
        parentID: binding.connectionID,
        selected: binding.isSelected,
        readOnly: binding.isReadOnly,
        sourceType: binding.providerSourceType,
        sourceLabel: binding.providerSourceLabel
    )
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
