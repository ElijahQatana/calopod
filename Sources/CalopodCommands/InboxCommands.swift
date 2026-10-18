import ArgumentParser
import CalopodDomain
import CalopodRuntime
import CalopodStore
import CalopodSync
import Foundation

public struct InboxOptions: ParsableArguments {
    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions
    @Option(name: .long) public var connection: String?
    @Option(name: .long) public var calendar: String?
    @Flag(name: .long) public var excludeMaybe = false
    @Flag(name: .long, help: "Only events with known conflicts.") public var conflicts = false
    @Flag(name: .long, help: "After the list, show for each item that shares time with another item why it is or isn't taken for a Calopod copy.") public var explain = false
    public init() {}
}

public struct InboxCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "inbox", abstract: "Read retained local inbox observations.",
        subcommands: [InboxActivityCommand.self, InboxRefreshCommand.self, InboxInspectCommand.self, InboxAcknowledgeCommand.self, InboxConfigCommand.self, InboxReviewCommand.self])
    @OptionGroup public var options: InboxOptions
    public init() {}
    public func run() async throws {
        do {
            try writeInbox(options: options, activity: false)
        } catch { try failCommand(error) }
    }
}

public struct InboxActivityCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "activity", abstract: "List unread activity, newest first.")
    @OptionGroup public var options: InboxOptions
    @Flag(name: .long) public var all = false
    public init() {}
    public func run() async throws {
        do {
            try writeInbox(options: options, activity: true, all: all)
        } catch { try failCommand(error) }
    }
}

public struct InboxRefreshCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "refresh", abstract: "Read sources into the local cache without target reconciliation.")
    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions
    @Option(name: .long) public var connection: String?
    @Option(name: .long) public var calendar: String?
    public init() {}
    public func run() async throws {
        do {
            let requested = try resolveRange(range, default: .none)
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let repository = try CommandEnvironment.repository()
            let sources = try selectedCalendarSources(connectionID: connection, calendarID: calendar, repository: repository)
            let resolved: ResolvedDateRange
            if let requested { resolved = requested }
            else {
                let url = try LaunchAgentController().propertyListURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw ValidationError("Supply --day or --from and --through when no tracked-window service is configured.")
                }
                let config = try AgentServiceConfiguration.load(from: url)
                let schedule = try AgentSchedule(interval: Double(config.intervalSeconds), maximumJitter: Double(config.jitterSeconds),
                    lookbackDays: config.lookbackDays, horizonDays: config.horizonDays)
                var localCalendar = Calendar.current
                if let zone = range.timezone { localCalendar.timeZone = TimeZone(identifier: zone)! }
                resolved = ResolvedDateRange(window: try CalendarReadWindow.covering(try schedule.window(containing: Date(), calendar: localCalendar), calendar: localCalendar),
                    timeZoneIdentifier: localCalendar.timeZone.identifier)
            }
            let refresh = await refreshCalendarSources(sources, from: resolved.window.start, through: resolved.window.end, repository: repository)
            try OutputRenderer.write(command: "inbox.refresh", payload: inboxRefreshPayload(refresh, range: resolved),
                warnings: refresh.warnings, format: output.format, showIDs: output.ids)
        } catch { try failCommand(error) }
    }
}

public struct InboxInspectCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Inspect a retained revision without reviewing it.")
    @Argument public var itemID: String
    @OptionGroup public var output: OutputOptions
    public init() {}
    public func run() async throws {
        do {
            let read = try CommandEnvironment.runtimeEnvironment().readOnlyState()
            defer { withExtendedLifetime(read) {} }
            let repository = read.repository
            try OutputRenderer.write(command: "inbox.inspect", payload: try InboxCLI.inspect(itemID, repository: repository),
                format: output.format, showIDs: output.ids, human: output.localContext(repository: repository))
        } catch { try failCommand(error) }
    }
}

public struct InboxAcknowledgeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(commandName: "acknowledge", abstract: "Review exactly one local revision; never send RSVP.")
    @Argument public var itemID: String
    @OptionGroup public var output: OutputOptions
    public init() {}
    public func run() async throws {
        do {
            let lock = try CommandEnvironment.writerLock()
            defer { withExtendedLifetime(lock) {} }
            let repository = try CommandEnvironment.repository()
            try OutputRenderer.write(command: "inbox.acknowledge", payload: try InboxCLI.acknowledge(itemID, repository: repository),
                format: output.format, showIDs: output.ids, human: output.localContext(repository: repository))
        } catch { try failCommand(error) }
    }
}

private func writeInbox(options: InboxOptions, activity: Bool, all: Bool = false) throws {
    let resolved = try resolveRange(options.range, default: .none)
    let read = try CommandEnvironment.runtimeEnvironment().readOnlyState()
    defer { withExtendedLifetime(read) {} }
    let repository = read.repository
    let payload = try InboxCLI.list(repository: repository, options: options, range: resolved, activity: activity, all: all)
    try OutputRenderer.write(command: activity ? "inbox.activity" : "inbox", payload: payload,
        format: options.output.format, showIDs: options.output.ids, human: options.output.localContext(repository: repository))
    if options.explain, !activity { print(try InboxCLI.explainCopies(payload, repository: repository)) }
}

func inboxRefreshPayload(_ refresh: CalendarRefreshSummary, range: ResolvedDateRange) -> CommandPayload {
    CommandPayload(status: refresh.failedSourceCount == 0 ? "ok" : "partial",
        message: "Refreshed \(refresh.refreshedSourceCount) sources; \(refresh.failedSourceCount) failed. Observed at \(InboxCLI.date(Date())!). Failed sources remain stale.",
        count: refresh.refreshedSourceCount, range: RangeOutput(range: range),
        selectedCalendarCount: refresh.selectedSourceCount, ingestion: refresh.ingestion)
}

public struct InboxItemDetail: Codable, Equatable, Sendable {
    let eventID: String
    let revision: Int64
    let currentRevisionID: String?
    let reviewed: Bool
    let response: EventResponse
    let reasons: [String]
    let changedFields: [String]
    let timing: String
    let observedAt: String?
    let acknowledgedAt: String?
    let activityTypes: [String]
    let location: String?
    let notes: String?
    let url: String?
    let organizer: EventParticipant?
    let conflicts: [InboxConflictDetail]
    let limits: [String]
    let presence: String
}
public struct InboxConflictDetail: Codable, Equatable, Sendable {
    let eventID: String
    let label: String?
    let calendarLabel: String?
    var calendarAlias: String? = nil
    let startsAt: String
    let endsAt: String
}
public struct InboxSourceDetail: Codable, Equatable, Sendable {
    let startsAt: String?
    let endsAt: String?
    let observedAt: String?
    let status: String
    /// Set when the read stops short of the requested range, in the same words the Mac app uses.
    var gap: String? = nil
}

enum InboxCLI {
    /// Plain text: for each listed item that shares time with an event of another calendar, which
    /// copy checks passed. Local only.
    static func explainCopies(_ payload: CommandPayload, repository: LocalStateRepository) throws -> String {
        let diagnoses = try repository.inboxCopyDiagnoses()
        let dropped = try repository.inboxDroppedCopies()
        var lines = ["", "Why these items are listed (copy checks against events of other calendars at the same time):"]
        for item in payload.items ?? [] {
            guard let key = try? parse(item.id).0, let found = diagnoses[key] else { continue }
            let own = try repository.inboxObservation(sourceKeyHash: key)?.event
            lines.append("")
            lines.append("\(item.id): LISTED. \(own?.title ?? "?") [\(own?.calendarBindingID ?? "?")] response \(own?.currentUserResponse.state.rawValue ?? "?"), evidence \(own?.currentUserResponse.evidence.rawValue ?? "?"), guests \(own?.attendees.count ?? 0)")
            for diagnosis in found {
                lines.append("  against \(diagnosis.sourceTitle ?? "?") [\(diagnosis.sourceCalendar)], arm rule \(diagnosis.armRule ?? "?"): \(diagnosis.isCopy ? "TAKEN FOR A COPY" : "not a copy")")
                for check in diagnosis.checks { lines.append("    \(check.passed ? "pass" : "FAIL") \(check.name)") }
            }
        }
        for (key, sources) in dropped.sorted(by: { $0.key < $1.key }) {
            let own = try repository.inboxObservation(sourceKeyHash: key)?.event
            lines.append("")
            lines.append("\(key.prefix(8)): DROPPED as a copy. \(own?.title ?? "?") [\(own?.calendarBindingID ?? "?")] copies \(sources.count) event(s)")
        }
        if lines.count == 2 { lines.append("No listed item shares time with an event that an arm copies.") }
        return lines.joined(separator: "\n")
    }
    static func date(_ value: Date?) -> String? { value.map { ISO8601DateFormatter().string(from: $0) } }
    static func id(_ key: String, _ revision: Int64) -> String { "\(key):\(revision)" }
    static func parse(_ id: String) throws -> (String, Int64) {
        guard let split = id.lastIndex(of: ":"), let revision = Int64(id[id.index(after: split)...]), revision > 0,
              split != id.startIndex else { throw ValidationError("Use an event:revision identifier from inbox --ids or JSON.") }
        return (String(id[..<split]), revision)
    }
    static func snapshot(_ repository: LocalStateRepository, options: InboxOptions) throws -> InboxContextSnapshot {
        let full = try repository.inboxContextSnapshot()
        if let connection = options.connection, !full.sources.contains(where: { $0.connectionID == connection }) {
            throw ValidationError("Connection is not enabled or has no selected calendars.")
        }
        let sources = full.sources.filter { options.connection == nil || $0.connectionID == options.connection }
            .filter { options.calendar == nil || $0.bindingID == options.calendar }
        if options.calendar != nil && sources.isEmpty { throw ValidationError("Calendar is not selected on that Connection.") }
        let bindings = Set(sources.map(\.bindingID))
        return InboxContextSnapshot(sources: sources, events: full.events.filter { bindings.contains($0.event.calendarBindingID) },
            unprovenDuplicateBindingIDs: full.unprovenDuplicateBindingIDs.intersection(bindings))
    }
    static func list(repository: LocalStateRepository, options: InboxOptions, range: ResolvedDateRange?,
                     activity: Bool, all: Bool = false, now: Date = Date()) throws -> CommandPayload {
        let snapshot = try snapshot(repository, options: options)
        let names = CalendarNames(repository)
        let full = try repository.inboxContextSnapshot()
        let query = InboxAttentionQuery.evaluate(full, filter: InboxAttentionFilter(window: range?.window,
            excludeMaybe: options.excludeMaybe, conflictsOnly: options.conflicts, asOf: now), freshnessCutoff: now.addingTimeInterval(-3600))
        var items: [CommandItem]
        if activity {
            let bindings = Set(snapshot.sources.map(\.bindingID))
            let connectionIDs: Set<String> = Set(snapshot.sources.map(\.connectionID))
            var rows: [InboxActivity] = []
            for connectionID in connectionIDs {
                rows += try repository.inboxActivity(connectionID: connectionID, includeAcknowledged: all)
            }
            rows = rows.filter { (entry: InboxActivity) -> Bool in bindings.contains(entry.event.calendarBindingID) }
            rows = try rows.filter { (entry: InboxActivity) -> Bool in
                if full.events.contains(where: { $0.event.sourceKeyHash == entry.sourceKeyHash }) { return true }
                return try repository.inboxObservation(sourceKeyHash: entry.sourceKeyHash)?.tombstone != nil
            }
            rows = try rows.filter { (entry: InboxActivity) -> Bool in
                if !options.excludeMaybe { return true }
                return try repository.inboxObservation(sourceKeyHash: entry.sourceKeyHash)?.event.currentUserResponse.state != .tentative
            }
            rows = rows.filter { (entry: InboxActivity) -> Bool in
                guard let window = range?.window else { return true }
                return [entry.event, entry.previousEvent].compactMap { $0 }.contains { $0.endsAt > window.start && $0.startsAt < window.end }
            }
            rows = rows.filter { (entry: InboxActivity) -> Bool in
                !options.conflicts || query.rows.contains(where: { $0.item.event.sourceKeyHash == entry.sourceKeyHash && $0.reasons.contains(.conflict) })
            }
            rows.sort { (a: InboxActivity, b: InboxActivity) -> Bool in
                (a.observedAt, a.sourceKeyHash, a.revision) > (b.observedAt, b.sourceKeyHash, b.revision)
            }
            items = try rows.map { entry in item(entry.event, revision: entry.revision, activity: entry,
                row: query.rows.first { $0.item.event.sourceKeyHash == entry.sourceKeyHash }, observation: try repository.inboxObservation(sourceKeyHash: entry.sourceKeyHash), context: full, details: false, names: names) }
        } else {
            let bindings = Set(snapshot.sources.map(\.bindingID))
            items = query.rows.filter { bindings.contains($0.item.event.calendarBindingID) }.map { item($0.item.event, revision: $0.item.observation?.revision ?? 1, row: $0, context: full, details: false, names: names) }
        }
        let sources = snapshot.sources.map { names.source(source($0, now: now, range: range.map { $0.window.start..<$0.window.end })) }
        let gaps = Set(query.analysis.warnings.map { $0.kind.rawValue }).sorted()
        return CommandPayload(status: gaps.isEmpty ? "ok" : "partial",
            message: "\(items.count) retained items. Coverage is bounded.\(gaps.isEmpty ? "" : " Limits: " + gaps.joined(separator: ", "))",
            count: items.count, range: range.map(RangeOutput.init), sources: sources, items: items)
    }
    static func source(_ source: InboxContextSource, now: Date, range: Range<Date>? = nil) -> CommandSource {
        let stale = source.staleSince != nil || source.healthStatus != "healthy"
            || (source.coverage?.observedAt ?? .distantPast) < now.addingTimeInterval(-3600)
        var status = source.coverage == nil ? "unknown" : (stale ? "stale" : "fresh")
        var gap: String?
        if let coverage = source.coverage, coverage.startsAt <= coverage.endsAt, let range {
            gap = CoverageGap.describe(read: coverage.startsAt...coverage.endsAt, range: range)
            if gap != nil && status == "fresh" { status = "partial" }
        }
        return CommandSource(id: source.bindingID, connectionID: source.connectionID, provider: source.provider, label: source.calendarLabel,
            inbox: InboxSourceDetail(startsAt: date(source.coverage?.startsAt), endsAt: date(source.coverage?.endsAt),
                observedAt: date(source.coverage?.observedAt), status: status, gap: gap))
    }
    static func inspect(_ identifier: String, repository: LocalStateRepository) throws -> CommandPayload {
        let (key, revision) = try parse(identifier)
        let snapshot = try repository.inboxContextSnapshot()
        guard let observation = try repository.inboxObservation(sourceKeyHash: key),
              snapshot.sources.contains(where: { $0.bindingID == observation.event.calendarBindingID }),
              observation.tombstone != nil || snapshot.events.contains(where: { $0.event.sourceKeyHash == key }) else {
            throw ValidationError("Item is unavailable in selected sources.")
        }
        let activity = try repository.inboxActivity(connectionID: observation.event.connectionID, includeAcknowledged: true)
            .first { $0.sourceKeyHash == key && $0.revision == revision }
        guard revision == observation.revision || activity != nil else { throw ValidationError("Revision is no longer retained.") }
        let query = InboxAttentionQuery.evaluate(snapshot, freshnessCutoff: Date().addingTimeInterval(-3600))
        let row = query.rows.first { $0.item.event.sourceKeyHash == key }
        let names = CalendarNames(repository)
        return CommandPayload(status: "ok", message: "Local revision detail. Inspect does not acknowledge or send RSVP.", count: 1,
            sources: snapshot.sources.filter { $0.bindingID == observation.event.calendarBindingID }.map { names.source(source($0, now: Date())) }, items: [item(activity?.event ?? observation.event, revision: revision, activity: activity, row: row, observation: observation, context: snapshot, details: true, names: names)])
    }
    static func acknowledge(_ identifier: String, repository: LocalStateRepository) throws -> CommandPayload {
        _ = try inspect(identifier, repository: repository)
        let (key, revision) = try parse(identifier)
        guard try repository.acknowledgeInboxRevision(sourceKeyHash: key, revision: revision) else { throw ValidationError("Revision is unavailable.") }
        return CommandPayload(status: "ok", message: "Reviewed one revision locally. RSVP and conflicts are unchanged.", count: 1)
    }
    static func item(_ event: StoredNormalizedInstance, revision: Int64, activity: InboxActivity? = nil,
                     row: InboxAttentionRow? = nil, observation: InboxObservation? = nil, context: InboxContextSnapshot? = nil, details: Bool,
                     names: CalendarNames? = nil) -> CommandItem {
        let conflicts = (row?.conflicts ?? []).map { conflict in
            let key = conflict.pair.first == event.sourceKeyHash ? conflict.pair.second : conflict.pair.first
            let other = context?.events.first { $0.event.sourceKeyHash == key }?.event
            let label = context?.sources.first { $0.bindingID == other?.calendarBindingID }?.calendarLabel
            return InboxConflictDetail(eventID: key, label: other?.title,
                calendarLabel: label, calendarAlias: other.flatMap { names?.alias($0.calendarBindingID, real: label) },
                startsAt: date(conflict.overlap.start)!, endsAt: date(conflict.overlap.end)!)
        }
        let observed = observation ?? row?.item.observation
        let detail = InboxItemDetail(eventID: event.sourceKeyHash, revision: revision,
            currentRevisionID: observed.map { id(event.sourceKeyHash, $0.revision) },
            reviewed: activity.map { $0.acknowledgedAt != nil } ?? ((observed?.acknowledgedRevision ?? 0) >= revision), response: event.currentUserResponse,
            reasons: row?.reasons.map(\.rawValue) ?? [], changedFields: activity?.changedFields ?? [],
            timing: activity?.responseTiming.rawValue ?? row?.changeTiming?.rawValue ?? observed?.responseTiming.rawValue ?? "not-applicable",
            observedAt: date(activity?.observedAt ?? row?.item.observation?.lastObservedAt), acknowledgedAt: date(activity?.acknowledgedAt),
            activityTypes: activity?.types.map(\.rawValue) ?? observed?.tombstone.map { [$0.rawValue] } ?? [], location: details ? event.location : nil,
            notes: details ? event.notes : nil, url: details ? event.url : nil, organizer: details ? event.organizer : nil,
            conflicts: conflicts, limits: event.currentUserResponse.limits.map(\.rawValue) + event.currentUserResponse.actionCapability.unavailableReasons.map(\.rawValue) + ["provider-read-only-command"],
            presence: row?.item.isPresenceConfirmed == false ? "unconfirmed" : "observed")
        return CommandItem(id: id(event.sourceKeyHash, revision), kind: "inbox", label: event.title, parentID: event.calendarBindingID,
            startsAt: date(event.startsAt), endsAt: date(event.endsAt), allDay: event.isAllDay,
            cancelled: event.isCancelled || (activity == nil && observed?.tombstone != nil) || activity?.types.contains(.removed) == true || activity?.types.contains(.cancelled) == true, inbox: detail)
    }
}
