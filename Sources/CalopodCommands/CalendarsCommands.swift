import ArgumentParser
import CalopodStore
import CalopodSync

private let localOnly = "This only changes how Calopod shows the calendar on this Mac. Nothing is changed at the provider."

/// Lists calendars and selects or deselects them, and keeps the names, Ignored list and colors
/// chosen on this Mac. Those choices are shared with the app through the local state.
public struct CalendarsCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "calendars",
        abstract: "List calendars and keep their names, Ignored list and colors.",
        discussion: localOnly,
        subcommands: [
            CalendarsListCommand.self,
            CalendarsNameCommand.self,
            CalendarsIgnoreCommand.self,
            CalendarsUnignoreCommand.self,
            CalendarsHideCommand.self,
            CalendarsShowCommand.self,
            CalendarsColorCommand.self,
            CalendarsPrunePreferencesCommand.self,
        ],
        defaultSubcommand: CalendarsListCommand.self
    )

    public init() {}
}

/// Lists a Connection's calendars and selects or deselects them. `--select` runs the
/// duplicate-source check first.
public struct CalendarsListCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List selectable calendars.",
        discussion: "Ignored calendars are left out unless you add --include-ignored; JSON output then has ignoredCount. "
            + "Colors: " + CalendarPalette.entries.map(\.id).joined(separator: ", ") + "."
    )

    @OptionGroup public var output: OutputOptions

    @Option(name: .long, help: "Logical Connection identifier. Uses the only supported Connection when omitted.")
    public var connection: String?

    @Flag(name: .long, help: "List every Connection's calendars from retained local data, without asking the provider.")
    public var cached = false

    @Option(name: .long, help: "Select one calendar identifier returned by this command.")
    public var select: String?

    @Option(name: .long, help: "Deselect one calendar identifier returned by this command.")
    public var deselect: String?

    @Flag(name: .long, help: "Also list the calendars you ignored, as the Calendars screen does under Ignored.")
    public var includeIgnored = false

    public init() {}

    public func run() async throws {
        do {
            if select != nil, deselect != nil {
                throw ValidationError("Use either --select or --deselect, not both.")
            }
            if includeIgnored, select != nil || deselect != nil {
                throw ValidationError("--include-ignored only changes the list. Leave it out to select or deselect.")
            }
            if cached {
                guard select == nil, deselect == nil else {
                    throw ValidationError("--cached only lists calendars. Leave it out to select or deselect.")
                }
                let read = try CommandEnvironment.runtimeEnvironment().readOnlyState()
                defer { withExtendedLifetime(read) {} }
                var bindings: [StoredCalendarBinding] = []
                for stored in try read.repository.connections() where (connection ?? stored.id) == stored.id {
                    bindings += try read.repository.calendarBindings(connectionID: stored.id)
                }
                try writeList(bindings, message: "Calendars from retained local data.", repository: read.repository)
                return
            }
            let repository = try CommandEnvironment.repository()
            let selected = try selectedConnection(id: connection, repository: repository)
            let calendars = try await refreshCalendars(for: selected)
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
                try write([updated], message: shouldSelect ? "Selected the calendar." : "Deselected the calendar.",
                          repository: repository)
                return
            }
            let warnings = try CalendarSelectionSafety.warnings(
                for: calendars,
                connection: selected,
                repository: repository
            )
            try writeList(calendars, message: calendars.isEmpty ? "No calendars were found." : "Selectable calendars.",
                          warnings: warnings, repository: repository)
        } catch {
            try failCommand(error, format: output.format)
        }
    }

    private func write(
        _ calendars: [StoredCalendarBinding], message: String, repository: LocalStateRepository
    ) throws {
        try OutputRenderer.write(
            command: "calendars",
            payload: calendarsPayload(calendars, message: message, repository: repository),
            format: output.format,
            showIDs: output.ids,
            human: output.localContext(repository: repository)
        )
    }

    /// Like the Calendars screen, the list leaves ignored calendars out unless asked.
    private func writeList(
        _ calendars: [StoredCalendarBinding], message: String, warnings: [String] = [], repository: LocalStateRepository
    ) throws {
        let listing = CalendarListing(calendars, includeIgnored: includeIgnored, names: CalendarNames(repository))
        var human = output.localContext(repository: repository)
        human.footer = listing.footer
        try OutputRenderer.write(
            command: "calendars",
            payload: calendarsPayload(listing.shown, message: listing.shown.isEmpty && listing.ignoredCount > 0
                ? "No calendars are shown." : message, repository: repository, ignoredCount: listing.omittedCount),
            warnings: warnings + listing.stillSelectedWarnings,
            format: output.format,
            showIDs: output.ids,
            human: human
        )
    }
}

public struct CalendarsNameCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "name",
        abstract: "Give a calendar a name of your own, or go back to its real name.",
        discussion: "The calendar can be given as its identifier or as its exact current name. " + localOnly
    )

    @Argument(help: "Calendar identifier, or its exact current or real name.")
    public var calendar: String

    @Argument(help: "The name to show.")
    public var name: String?

    @Flag(name: .long, help: "Remove the chosen name and show the real one.")
    public var clear = false

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func validate() throws {
        if clear == (name != nil) { throw ValidationError("Give a name, or use --clear.") }
    }

    public func run() throws {
        try changeCalendar(command: "calendars.name", output: output) {
            try CalendarsEdit.name(calendar, to: clear ? nil : name, repository: $0)
        }
    }
}

public struct CalendarsIgnoreCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ignore",
        abstract: "Leave a calendar out of the calendar list and events output.",
        discussion: "Example: calopod calendars ignore \"Holidays\"\n\n"
            + "An ignored calendar keeps syncing and can still be named by identifier or name. "
            + "List it with calendars --include-ignored. " + localOnly
    )

    @Argument(help: "Calendar identifier, or its exact current or real name.")
    public var calendar: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try changeCalendar(command: "calendars.ignore", output: output) {
            try CalendarsEdit.ignore(calendar, true, repository: $0)
        }
    }
}

public struct CalendarsUnignoreCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unignore",
        abstract: "Stop ignoring a calendar.",
        discussion: "Example: calopod calendars unignore \"Holidays\"\n\n" + localOnly
    )

    @Argument(help: "Calendar identifier, or its exact current or real name.")
    public var calendar: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try changeCalendar(command: "calendars.unignore", output: output) {
            try CalendarsEdit.ignore(calendar, false, repository: $0)
        }
    }
}

public struct CalendarsHideCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "hide",
        abstract: "Hide a calendar in one view of the Calendar screen and of events --view.",
        discussion: "Each view (all, sources, destinations) keeps its own hidden calendars; the app shares them. " + localOnly
    )

    @Argument(help: "Calendar identifier, or its exact current or real name.")
    public var calendar: String

    @Option(name: .long, help: "The view to hide it in: all, sources or destinations.")
    public var view: CalendarViewMode

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try changeCalendar(command: "calendars.hide", output: output) {
            try CalendarsEdit.hide(calendar, true, view: view, repository: $0)
        }
    }
}

public struct CalendarsShowCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a calendar again in one view.",
        discussion: localOnly
    )

    @Argument(help: "Calendar identifier, or its exact current or real name.")
    public var calendar: String

    @Option(name: .long, help: "The view to show it in: all, sources or destinations.")
    public var view: CalendarViewMode

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try changeCalendar(command: "calendars.show", output: output) {
            try CalendarsEdit.hide(calendar, false, view: view, repository: $0)
        }
    }
}

public struct CalendarsColorCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "Choose a calendar's color from the palette.",
        discussion: "Colors: " + CalendarPalette.entries.map(\.id).joined(separator: ", ") + ". " + localOnly
    )

    @Argument(help: "Calendar identifier, or its exact current or real name.")
    public var calendar: String

    @Argument(help: ArgumentHelp("Palette color: " + CalendarPalette.entries.map(\.id).joined(separator: ", ") + "."))
    public var color: String

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try changeCalendar(command: "calendars.color", output: output) {
            try CalendarsEdit.color(calendar, color, repository: $0)
        }
    }
}

public struct CalendarsPrunePreferencesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "prune-preferences",
        abstract: "Remove saved names, colors and ignores for calendars that no longer exist.",
        discussion: "Only choices for a calendar with no binding and no connection are removed. "
            + "Calendars you can still see are never touched. " + localOnly
    )

    @Flag(name: .long, help: "Only count the choices that would be removed.")
    public var dryRun = false

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try changeCalendar(command: "calendars.prune-preferences", output: output) {
            try CalendarsEdit.prune(dryRun: dryRun, repository: $0)
        }
    }
}

private func changeCalendar(
    command: String, output: OutputOptions, change: (LocalStateRepository) throws -> CommandPayload
) throws {
    do {
        let lock = try CommandEnvironment.writerLock()
        defer { withExtendedLifetime(lock) {} }
        let repository = try CommandEnvironment.repository()
        try OutputRenderer.write(
            command: command,
            payload: try change(repository),
            format: output.format,
            showIDs: output.ids,
            human: output.localContext(repository: repository)
        )
    } catch {
        try failCommand(error, format: output.format)
    }
}

enum CalendarsEdit {
    /// A nil, blank or real name clears the chosen name.
    static func name(_ reference: String, to name: String?, repository: LocalStateRepository) throws -> CommandPayload {
        let binding = try resolveCalendar(reference, repository: repository)
        let text = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let text, text.isEmpty { throw ValidationError("The name cannot be empty. Use --clear to remove it.") }
        let alias = text == binding.displayLabel ? nil : text
        try repository.setCalendarAlias(alias, calendarID: binding.id)
        let message = alias == nil ? "Cleared the name. The real name is shown again." : "Named the calendar. " + localOnly
        return calendarsPayload([binding], message: message, repository: repository)
    }

    static func prune(dryRun: Bool, repository: LocalStateRepository) throws -> CommandPayload {
        let count = try repository.pruneCalendarPreferences(dryRun: dryRun)
        let things = count == 1 ? "1 saved choice" : "\(count) saved choices"
        let message = dryRun
            ? "\(things) would be removed. Nothing was changed."
            : (count == 0 ? "Nothing to remove." : "Removed \(things) for calendars that no longer exist.")
        return CommandPayload(status: "ok", message: message, count: count)
    }

    static func ignore(_ reference: String, _ ignored: Bool, repository: LocalStateRepository) throws -> CommandPayload {
        let binding = try resolveCalendar(reference, repository: repository)
        try repository.setCalendarIgnored(ignored, calendarID: binding.id)
        var message = ignored ? "Ignored the calendar. " : "Stopped ignoring the calendar. "
        // The app does the same: ignoring hides a calendar but a selected one keeps syncing.
        if ignored, binding.isSelected { message += "It is still selected and keeps syncing. " }
        let shown = try CalendarListing.defaultCount(repository: repository)
        message += "calopod calendars now lists \(shown) \(shown == 1 ? "calendar" : "calendars") by default. " + localOnly
        return calendarsPayload([binding], message: message, repository: repository)
    }

    static func hide(_ reference: String, _ hidden: Bool, view: CalendarViewMode, repository: LocalStateRepository) throws -> CommandPayload {
        let binding = try resolveCalendar(reference, repository: repository)
        try repository.setCalendarHidden(hidden, view: view.rawValue, calendarID: binding.id)
        let message = (hidden ? "Hid the calendar in \(view.title). " : "Showing the calendar in \(view.title) again. ") + localOnly
        return calendarsPayload([binding], message: message, repository: repository)
    }

    static func color(_ reference: String, _ color: String, repository: LocalStateRepository) throws -> CommandPayload {
        guard let entry = CalendarPalette.entry(id: color.lowercased()) else {
            throw ValidationError("'\(color)' is not a palette color. Choose one of: "
                + CalendarPalette.entries.map(\.id).joined(separator: ", ") + ".")
        }
        let binding = try resolveCalendar(reference, repository: repository)
        try repository.setCalendarColor(entry.id, calendarID: binding.id)
        return calendarsPayload([binding], message: "Set the color to \(entry.id). " + localOnly, repository: repository)
    }
}

/// Finds one calendar by identifier, else by exact shown or real name. A name that fits several
/// calendars lists them and fails.
func resolveCalendar(_ reference: String, repository: LocalStateRepository) throws -> StoredCalendarBinding {
    let connections = try repository.connections()
    let all = try connections.flatMap { try repository.calendarBindings(connectionID: $0.id) }
    if let byID = all.first(where: { $0.id == reference }) { return byID }
    let names = CalendarNames(repository)
    let matches = all.filter { $0.displayLabel == reference || names.preferences[$0.id]?.alias == reference }
    if matches.count == 1 { return matches[0] }
    guard !matches.isEmpty else { throw ValidationError("No calendar has the identifier or name '\(reference)'.") }
    let labels = Dictionary(connections.map { ($0.id, $0.displayLabel ?? $0.provider) }, uniquingKeysWith: { first, _ in first })
    let lines = matches.map {
        "  \($0.id): \(names.shown($0.id, real: $0.displayLabel) ?? "Unnamed calendar") (\(labels[$0.connectionID] ?? $0.connectionID))"
    }
    throw ValidationError("'\(reference)' matches more than one calendar. Use the identifier:\n" + lines.joined(separator: "\n"))
}

/// What the default calendar list shows: ignored calendars stay out unless asked for.
struct CalendarListing {
    let shown: [StoredCalendarBinding]
    let ignoredCount: Int
    let omittedCount: Int?
    let stillSelectedWarnings: [String]
    let footer: [String]

    init(_ calendars: [StoredCalendarBinding], includeIgnored: Bool, names: CalendarNames) {
        let ignored = calendars.filter { names.isIgnored($0.id) }
        ignoredCount = ignored.count
        shown = includeIgnored ? calendars : calendars.filter { !names.isIgnored($0.id) }
        omittedCount = includeIgnored ? nil : ignored.count
        stillSelectedWarnings = ignored.filter(\.isSelected).map {
            "\(names.shown($0.id, real: $0.displayLabel) ?? "Unnamed calendar") is ignored but still selected, so it keeps syncing. Ignoring only hides it."
        }
        var footer: [String] = []
        if let omitted = omittedCount, omitted > 0 {
            footer.append("\(omitted) ignored \(omitted == 1 ? "calendar is" : "calendars are") not shown. Use --include-ignored to list them.")
        }
        footer.append("Use calopod calendars ignore <calendar> to hide one.")
        self.footer = footer
    }

    /// Calendars across every Connection that the list shows without --include-ignored.
    static func defaultCount(repository: LocalStateRepository) throws -> Int {
        let names = CalendarNames(repository)
        return try repository.connections()
            .flatMap { try repository.calendarBindings(connectionID: $0.id) }
            .filter { !names.isIgnored($0.id) }.count
    }
}

func calendarsPayload(
    _ calendars: [StoredCalendarBinding], message: String, repository: LocalStateRepository, ignoredCount: Int? = nil
) -> CommandPayload {
    let names = CalendarNames(repository)
    return CommandPayload(
        status: "ok",
        message: message,
        count: calendars.count,
        items: calendars.map { binding in
            CommandItem(
                id: binding.id,
                kind: "calendar",
                label: binding.displayLabel,
                parentID: binding.connectionID,
                selected: binding.isSelected,
                readOnly: binding.isReadOnly,
                sourceType: binding.providerSourceType,
                sourceLabel: binding.providerSourceLabel,
                alias: names.alias(binding.id, real: binding.displayLabel),
                ignored: names.isIgnored(binding.id),
                color: names.preferences[binding.id]?.color
            )
        },
        colors: CalendarPalette.entries.map(\.id),
        ignoredCount: ignoredCount
    )
}
