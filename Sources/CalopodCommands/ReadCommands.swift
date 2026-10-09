import ArgumentParser
import CalopodStore
import CalopodSync
import Foundation

/// Lists a Connection's calendars and lets the user select or deselect one.
/// `--select` runs the duplicate-source check first (`CalendarSelectionSafety`)
/// so a calendar that overlaps an existing direct provider connection is
/// rejected before it's ever marked selected.
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
                    format: output.format,
                    showIDs: output.ids,
                    human: output.localContext(repository: repository)
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
                format: output.format,
                showIDs: output.ids,
                human: output.localContext(repository: repository)
            )
        } catch {
            try failCommand(error)
        }
    }

}

/// Lists normalized source events for a range. This refreshes the local
/// cache first — the same read path `availability` uses — but, like the rest
/// of `CombinedRead`, never touches a managed target calendar.
public struct EventsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List normalized events for a day or range."
    )

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    @Option(name: .long, help: "Limit events to one Connection. Uses every enabled selected Connection when omitted.")
    public var connection: String?

    @Option(name: .long, help: "Limit events to one selected calendar. Uses every selected calendar when omitted.")
    public var calendar: String?

    public init() {}

    public func run() async throws {
        let resolved = try resolveRange(range, default: .currentDay)
        guard let resolved else { return }
        do {
            let repository = try CommandEnvironment.repository()
            let sources = try selectedCalendarSources(
                connectionID: connection,
                calendarID: calendar,
                repository: repository
            )
            let refresh = await refreshCalendarSources(
                sources,
                from: resolved.window.start,
                through: resolved.window.end,
                repository: repository
            )
            let events = try repository.normalizedInstances(
                calendarBindingIDs: sources.map(\.calendar.id),
                from: resolved.window.start,
                through: resolved.window.end
            )
            try OutputRenderer.write(
                command: "events",
                payload: CommandPayload(
                    status: refresh.failedSourceCount == 0 ? "ok" : "partial",
                    message: events.isEmpty ? "No events were found." : "Events in the requested range.",
                    count: events.count,
                    range: RangeOutput(range: resolved),
                    sources: commandSources(sources),
                    items: events.map {
                        CommandItem(
                            id: $0.sourceKeyHash,
                            kind: "event",
                            label: $0.title,
                            parentID: $0.calendarBindingID,
                            startsAt: outputDate($0.startsAt),
                            endsAt: outputDate($0.endsAt),
                            allDay: $0.isAllDay,
                            cancelled: false,
                            availability: $0.availability
                        )
                    },
                    ingestion: refresh.ingestion
                ),
                warnings: refresh.warnings,
                format: output.format,
                showIDs: output.ids,
                human: output.localContext(repository: repository)
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

/// Shows combined Busy/Free intervals across selected calendars for a range,
/// derived with `AvailabilityCalculator` from the same normalized events
/// `EventsCommand` lists — never source titles, locations, or other content.
public struct AvailabilityCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "availability",
        abstract: "Show combined busy and free intervals for a day or range."
    )

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    @Option(name: .long, help: "Limit Availability to one Connection identifier.")
    public var connection: String?

    @Option(name: .long, help: "Limit Availability to one selected calendar identifier.")
    public var calendar: String?

    public init() {}

    public func run() async throws {
        let resolved = try resolveRange(range, default: .currentDay)
        guard let resolved else { return }
        do {
            let repository = try CommandEnvironment.repository()
            let sources = try selectedCalendarSources(
                connectionID: connection,
                calendarID: calendar,
                repository: repository
            )
            let refresh = await refreshCalendarSources(
                sources,
                from: resolved.window.start,
                through: resolved.window.end,
                repository: repository
            )
            let events = try repository.normalizedInstances(
                calendarBindingIDs: sources.map(\.calendar.id),
                from: resolved.window.start,
                through: resolved.window.end
            )
            let availability = AvailabilityCalculator.calculate(
                instances: events,
                from: resolved.window.start,
                through: resolved.window.end
            )
            let intervals = (availability.busy + availability.free).sorted {
                if $0.start == $1.start {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.start < $1.start
            }
            try OutputRenderer.write(
                command: "availability",
                payload: CommandPayload(
                    status: refresh.failedSourceCount == 0 ? "ok" : "partial",
                    message: intervals.isEmpty
                        ? "No Availability intervals were found."
                        : "Availability in the requested range.",
                    count: intervals.count,
                    range: RangeOutput(range: resolved),
                    sources: commandSources(sources),
                    items: intervals.enumerated().map { index, interval in
                        CommandItem(
                            id: "availability-\(interval.kind.rawValue)-\(index + 1)",
                            kind: "availability",
                            label: interval.kind == .busy ? "Busy" : "Free",
                            startsAt: outputDate(interval.start),
                            endsAt: outputDate(interval.end),
                            availability: interval.kind.rawValue
                        )
                    },
                    ingestion: refresh.ingestion
                ),
                warnings: refresh.warnings,
                format: output.format,
                showIDs: output.ids,
                human: output.localContext(repository: repository)
            )
        } catch {
            try failCommand(error)
        }
    }
}

private func commandSources(_ sources: [CalendarReadSource]) -> [CommandSource] {
    sources.map {
        CommandSource(
            id: $0.calendar.id,
            connectionID: $0.connection.id,
            provider: $0.connection.provider,
            label: $0.calendar.displayLabel
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
