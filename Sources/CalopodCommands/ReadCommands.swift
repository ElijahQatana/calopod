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

    @Option(name: .long, help: "Show all calendars, only those arms copy from (sources), or only those they write to (destinations). Calendars hidden in that view with `calendars hide` are left out unless --calendar names them.")
    public var view: CalendarViewMode?

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
            let viewMode = view ?? .all
            // Hidden calendars only apply when a view is asked for, so plain `events` is unchanged.
            let hidden = view == nil || calendar != nil ? [] : try repository.hiddenCalendars(view: viewMode.rawValue)
            let shown = sources.map(\.calendar.id).filter {
                !names.isIgnored($0) && roles.includes($0, in: viewMode) && !hidden.contains($0)
            }
            let events = try repository.normalizedInstances(
                calendarBindingIDs: shown,
                from: resolved.window.start,
                through: resolved.window.end
            )
            // Copies Calopod made never get a Join link.
            let originals = Set(((try? repository.inboxContextSnapshot()) ?? InboxContextSnapshot(sources: [], events: [])).events.map(\.event.sourceKeyHash))
            let copyItems = copies ?? viewMode.copiesShownByDefault
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
                        let join = originals.contains($0.sourceKeyHash) ? JoinSelector.link(for: $0) : nil
                        return CommandItem(
                            id: $0.sourceKeyHash,
                            kind: "event",
                            label: $0.title,
                            parentID: $0.calendarBindingID,
                            startsAt: outputDate($0.startsAt),
                            endsAt: outputDate($0.endsAt),
                            allDay: $0.isAllDay,
                            cancelled: false,
                            availability: $0.availability,
                            joinProvider: join?.provider.displayName,
                            joinURL: join?.webURL.absoluteString
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
            try failCommand(error, format: output.format)
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
                label: arm.ruleMode == .fullDetails ? event.title : arm.plainCopyTitle(isPrivate: event.isPrivate), parentID: arm.targetBindingID,
                startsAt: outputDate(event.startsAt), endsAt: outputDate(event.endsAt), allDay: event.isAllDay,
                cancelled: false, availability: event.availability,
                copyMode: arm.ruleMode == .fullDetails ? "full-details" : "busy",
                sourceResponse: copyResponseName(event.currentUserResponse.state)))
        }
    }
    return items.sorted { ($0.startsAt ?? "", $0.id) < ($1.startsAt ?? "", $1.id) }
}

func outputDate(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

/// Shows combined Busy and Free intervals for a range, or finds a free slot of a given length.
public struct AvailabilityCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "availability",
        abstract: "Show combined busy and free intervals, or find a free slot.",
        subcommands: [AvailabilityShowCommand.self, AvailabilityFindCommand.self],
        defaultSubcommand: AvailabilityShowCommand.self
    )

    public init() {}
}

/// Shows combined Busy and Free intervals for a range. Only times are used, never titles or
/// locations.
public struct AvailabilityShowCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "show",
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

    @Flag(name: .long, help: "Count free time all day instead of only inside working hours (see `calopod hours`).")
    public var ignoreWorkingHours = false

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
                instances: AvailabilityCalculator.withPadding(events, arms: try repository.arms()),
                from: resolved.window.start,
                through: resolved.window.end,
                workingHours: ignoreWorkingHours ? nil : try repository.workingHours(),
                timeZone: TimeZone(identifier: resolved.timeZoneIdentifier) ?? .current
            )
            let items = Self.items(availability)
            let day = AvailabilityDay(
                availability, day: DateInterval(start: resolved.window.start, end: resolved.window.end))
            var human = output.localContext(repository: repository)
            if availability.workingWindows != nil {
                human.footer = [
                    "Free \(Self.duration(day.freeSeconds)), busy \(Self.duration(day.busySeconds)), outside working hours \(Self.duration(day.outsideSeconds)).",
                    "Free and busy time count only inside working hours (see calopod hours). Use --ignore-working-hours to count the whole day.",
                ]
            }
            try OutputRenderer.write(
                command: "availability",
                payload: CommandPayload(
                    status: cached || refresh.failedSourceCount != 0 ? "partial" : "ok",
                    message: items.isEmpty
                        ? "No Availability intervals were found."
                        : "Availability in the requested range.",
                    count: items.count,
                    range: RangeOutput(range: resolved),
                    sources: commandSources(sources, names: CalendarNames(repository)),
                    items: items,
                    ingestion: refresh.ingestion,
                    workingWindows: availability.workingWindows?.map {
                        WorkingWindowOutput(startsAt: outputDate($0.start)!, endsAt: outputDate($0.end)!)
                    },
                    totals: AvailabilityTotalsOutput(
                        freeSeconds: Int(day.freeSeconds), busySeconds: Int(day.busySeconds),
                        outsideSeconds: Int(day.outsideSeconds))
                ),
                warnings: refresh.warnings,
                format: output.format,
                showIDs: output.ids,
                human: human
            )
        } catch {
            try failCommand(error, format: output.format)
        }
    }
}

extension AvailabilityShowCommand {
    /// Busy time outside working hours is its own kind: before-hours, after-hours or day-off. The
    /// busy kind is only time inside working hours.
    static func items(_ result: AvailabilityResult) -> [CommandItem] {
        var intervals: [(kind: String, start: Date, end: Date)] = []
        for interval in result.busy + result.free {
            intervals.append((interval.kind.rawValue, interval.start, interval.end))
        }
        for interval in result.outside {
            intervals.append((outsideKind(interval.side), interval.start, interval.end))
        }
        intervals.sort { $0.start == $1.start ? $0.kind < $1.kind : $0.start < $1.start }
        return intervals.enumerated().map { index, interval in
            CommandItem(
                id: "availability-\(interval.kind)-\(index + 1)", kind: "availability",
                label: label(interval.kind), startsAt: outputDate(interval.start),
                endsAt: outputDate(interval.end), availability: interval.kind)
        }
    }

    static func outsideKind(_ side: OutsideSide) -> String {
        switch side {
        case .before: "before-hours"
        case .after: "after-hours"
        case .dayOff: "day-off"
        }
    }

    static func label(_ kind: String) -> String {
        switch kind {
        case "busy": "Busy"
        case "free": "Free"
        case "before-hours": "Before hours"
        case "after-hours": "After hours"
        default: "Day off"
        }
    }

    /// "30 min", "1 hr", "1 hr 30 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let (hours, rest) = (minutes / 60, minutes % 60)
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }
}

func commandSources(_ sources: [CalendarReadSource], names: CalendarNames) -> [CommandSource] {
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
