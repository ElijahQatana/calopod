import ArgumentParser
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation

/// Lists source events from the local cache, refreshing unless --cached is supplied.
public struct EventsCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "List normalized events for a day or range."
    )

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    @Flag(name: .long, help: "Read retained local data without refreshing sources.")
    public var cached = false

    @Option(name: .long, help: "Limit events to one Connection. Uses every enabled selected Connection when omitted.")
    public var connection: String?

    @Option(name: .long, help: "Limit events to one selected calendar. Uses every selected calendar when omitted.")
    public var calendar: String?

    @Option(name: .long, help: "Show all calendars, only those arms copy from (sources), or only those they write to (destinations).")
    public var view: CalendarViewMode = .all

    @Flag(name: .long, inversion: .prefixedNo, help: "Include the copies Calopod made. On for --view destinations and off otherwise unless set.")
    public var copies: Bool?

    public init() {}

    public func run() async throws {
        let resolved = try resolveRange(range, default: .currentDay)
        guard let resolved else { return }
        do {
            let read = try await calendarCommandRead(
                environment: CommandEnvironment.runtimeEnvironment(),
                cached: cached, connectionID: connection, calendarID: calendar, range: resolved
            )
            defer { withExtendedLifetime(read) {} }
            let repository = read.repository
            let sources = read.sources
            let refresh = read.refresh
            // Ignored calendars keep syncing, but their events are left out, as in the app's schedule.
            let names = CalendarNames(repository)
            let arms = try repository.arms()
            let roles = CalendarRoles(arms: arms)
            let shown = sources.map(\.calendar.id).filter { !names.isIgnored($0) && roles.includes($0, in: view) }
            let events = try repository.normalizedInstances(
                calendarBindingIDs: shown,
                from: resolved.window.start,
                through: resolved.window.end
            )
            let copyItems = copies ?? view.copiesShownByDefault
                ? try destinationCopies(arms: arms, repository: repository, into: Set(shown), range: resolved)
                : []
            try OutputRenderer.write(
                command: "events",
                payload: CommandPayload(
                    status: cached || refresh.failedSourceCount != 0 ? "partial" : "ok",
                    message: events.isEmpty ? "No events were found." : "Events in the requested range.",
                    count: events.count + copyItems.count,
                    range: RangeOutput(range: resolved),
                    sources: commandSources(sources, names: names),
                    items: copyItems + events.map {
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

/// The Busy or full-detail copies the arms made on these calendars, drawn at the source's time as in the app.
func destinationCopies(
    arms: [StoredArm], repository: LocalStateRepository, into targets: Set<String>, range: ResolvedDateRange
) throws -> [CommandItem] {
    let active = arms.filter { $0.isEnabled && targets.contains($0.targetBindingID) }
    let originals = Dictionary(
        uniqueKeysWithValues: try repository.normalizedInstances(
            calendarBindingIDs: Array(Set(active.flatMap(\.sourceBindingIDs))),
            from: range.window.start, through: range.window.end
        ).map { ($0.sourceKeyHash, $0) })
    var items: [CommandItem] = []
    for arm in active {
        for mapping in try repository.mirrorMappings(armID: arm.id) {
            guard let event = originals[mapping.sourceKeyHash], event.calendarBindingID != arm.targetBindingID else { continue }
            items.append(CommandItem(
                id: "copy:\(arm.targetBindingID):\(event.sourceKeyHash)", kind: "copy",
                label: arm.ruleMode == .fullDetails ? event.title : "Busy", parentID: arm.targetBindingID,
                startsAt: outputDate(event.startsAt), endsAt: outputDate(event.endsAt), allDay: event.isAllDay,
                cancelled: false, availability: event.availability))
        }
    }
    return items.sorted { ($0.startsAt ?? "", $0.id) < ($1.startsAt ?? "", $1.id) }
}

private func outputDate(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

/// Shows combined Busy and Free intervals for a range. Only times are used, never titles or
/// locations.
public struct AvailabilityCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "availability",
        abstract: "Show combined busy and free intervals for a day or range."
    )

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    @Flag(name: .long, help: "Read retained local data without refreshing sources.")
    public var cached = false

    @Option(name: .long, help: "Limit Availability to one Connection identifier.")
    public var connection: String?

    @Option(name: .long, help: "Limit Availability to one selected calendar identifier.")
    public var calendar: String?

    public init() {}

    public func run() async throws {
        let resolved = try resolveRange(range, default: .currentDay)
        guard let resolved else { return }
        do {
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
                    status: cached || refresh.failedSourceCount != 0 ? "partial" : "ok",
                    message: intervals.isEmpty
                        ? "No Availability intervals were found."
                        : "Availability in the requested range.",
                    count: intervals.count,
                    range: RangeOutput(range: resolved),
                    sources: commandSources(sources, names: CalendarNames(repository)),
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

private func commandSources(_ sources: [CalendarReadSource], names: CalendarNames) -> [CommandSource] {
    sources.map {
        names.source(CommandSource(
            id: $0.calendar.id,
            connectionID: $0.connection.id,
            provider: $0.connection.provider,
            label: $0.calendar.displayLabel
        ))
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
