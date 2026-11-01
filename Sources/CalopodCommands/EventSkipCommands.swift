import ArgumentParser
import CalopodStore

public struct EventsSkipCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "Stop copying an event.",
        discussion: "Takes an id from `calopod events --ids`. Saved on this Mac only; the event is not changed. A copy Calopod already made is removed on the next sync."
    )

    @Argument(help: "An event id from `calopod events --ids`.") public var event: String
    @Flag(name: .long, help: "Skip every event in the series, not just this one.") public var series = false
    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        do {
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let repository = try CommandEnvironment.repository()
            let message = try EventSkipService.skip(eventID: event, wholeSeries: series, repository: repository)
            try OutputRenderer.write(command: "events.skip", payload: CommandPayload(status: "ok", message: message, count: 1),
                format: output.format, showIDs: output.ids, human: output.localContext(repository: repository))
        } catch { try failCommand(error, format: output.format) }
    }
}

public struct EventsUnskipCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "unskip",
        abstract: "Copy a skipped event again.",
        discussion: "Takes an event id or an id from `calopod events skipped --ids`."
    )

    @Argument(help: "An event id, or an id from `calopod events skipped --ids`.") public var event: String
    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        do {
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let repository = try CommandEnvironment.repository()
            let message = try EventSkipService.unskip(event, repository: repository)
            try OutputRenderer.write(command: "events.unskip", payload: CommandPayload(status: "ok", message: message, count: 1),
                format: output.format, showIDs: output.ids, human: output.localContext(repository: repository))
        } catch { try failCommand(error, format: output.format) }
    }
}

public struct EventsSkippedCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "skipped",
        abstract: "List the events Calopod does not copy."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        do {
            let state = try CommandEnvironment.runtimeEnvironment().readOnlyState()
            defer { withExtendedLifetime(state) {} }
            let repository = state.repository
            let skipped = try EventSkipService.skipped(repository: repository)
            try OutputRenderer.write(command: "events.skipped", payload: CommandPayload(
                status: "ok", message: skipped.isEmpty ? "No events are skipped." : "Events Calopod does not copy.",
                count: skipped.count, items: skipped.map(Self.item)),
                format: output.format, showIDs: output.ids, human: output.localContext(repository: repository))
        } catch { try failCommand(error, format: output.format) }
    }

    static func item(_ skipped: (skip: EventSkip, event: StoredNormalizedInstance?)) -> CommandItem {
        var label = skipped.event?.title ?? "Not in the synced range"
        if skipped.event?.providerSeriesID != nil { label += skipped.skip.occurrence.isEmpty ? " (series)" : " (one occurrence)" }
        return CommandItem(
            id: skipped.skip.id, kind: "skipped-event", label: label,
            parentID: skipped.skip.calendarBindingID, startsAt: outputDate(skipped.event?.startsAt))
    }
}
