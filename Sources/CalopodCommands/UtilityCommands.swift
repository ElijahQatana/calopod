import ArgumentParser
import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation

public struct SyncCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Plan or run synchronization for a configured range."
    )

    @Flag(name: .long, help: "Plan changes without writing provider data.")
    public var dryRun = false

    @OptionGroup public var range: DateRangeOptions
    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() async throws {
        guard dryRun else {
            try OutputRenderer.write(
                command: "sync",
                payload: CommandPayload(
                    status: "unavailable",
                    message: "Apply is not available yet. Run sync with --dry-run."
                ),
                format: output.format
            )
            throw ExitCode(CalopodExitCode.unavailable.rawValue)
        }

        do {
            let resolved = try resolveRange(range, default: .none)
            guard let resolved else {
                throw ValidationError("Pass --day or both --from and --through for a bounded dry run.")
            }
            let repository = try CommandEnvironment.repository()
            let arms = try repository.arms().filter(\.isEnabled)
            let sources = try armReadSources(arms: arms, repository: repository)
            let refresh = await refreshCalendarSources(
                sources,
                from: resolved.window.start,
                through: resolved.window.end,
                repository: repository
            )
            var planItems: [SyncPlanItem] = []
            for arm in arms {
                let events = try repository.normalizedInstances(
                    calendarBindingIDs: arm.sourceBindingIDs,
                    from: resolved.window.start,
                    through: resolved.window.end
                )
                let plan = SyncPlanner.plan(
                    arm: arm,
                    sources: events,
                    mappings: try repository.mirrorMappings(armID: arm.id),
                    targetEvents: [],
                    window: resolved.window,
                    sourceSnapshotComplete: refresh.failedSourceCount == 0
                )
                planItems.append(contentsOf: plan.items)
            }
            planItems.sort {
                ($0.armID, $0.mirrorKey, $0.action.rawValue)
                    < ($1.armID, $1.mirrorKey, $1.action.rawValue)
            }

            try OutputRenderer.write(
                command: "sync",
                payload: CommandPayload(
                    status: refresh.failedSourceCount == 0 ? "ok" : "partial",
                    message: planItems.isEmpty
                        ? "The dry run found no planned operations."
                        : "Dry-run synchronization plan.",
                    count: planItems.count,
                    range: RangeOutput(range: resolved),
                    mode: SyncMode.dryRun.rawValue,
                    items: planItems.map(planItem)
                ),
                warnings: refresh.warnings,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }
}

private func armReadSources(
    arms: [StoredArm],
    repository: LocalStateRepository
) throws -> [CalendarReadSource] {
    let sourceIDs = Set(arms.flatMap(\.sourceBindingIDs))
    var sources: [CalendarReadSource] = []
    for sourceID in sourceIDs.sorted() {
        guard let calendar = try repository.calendarBinding(id: sourceID), calendar.isSelected else {
            throw ValidationError("Arm source calendar '\(sourceID)' was not found or is not selected.")
        }
        guard let connection = try repository.connection(id: calendar.connectionID),
              connection.isEnabled else {
            throw ValidationError("The Connection for Arm source '\(sourceID)' is not enabled.")
        }
        guard ["eventkit", "google", "microsoft"].contains(connection.provider) else {
            throw ValidationError("Arm source calendar '\(sourceID)' cannot be refreshed yet.")
        }
        sources.append(CalendarReadSource(connection: connection, calendar: calendar))
    }
    return sources
}

private func planItem(_ item: SyncPlanItem) -> CommandItem {
    CommandItem(
        id: item.id,
        kind: item.action.rawValue,
        label: item.payload?.title,
        parentID: item.sourceKeyHash,
        startsAt: planOutputDate(item.payload?.startsAt),
        endsAt: planOutputDate(item.payload?.endsAt),
        allDay: item.payload?.isAllDay,
        availability: item.payload?.availability,
        reason: item.reason.rawValue,
        armID: item.armID,
        mirrorKey: item.mirrorKey,
        desiredFingerprint: item.desiredFingerprint
    )
}

private func planOutputDate(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

public struct DoctorCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Inspect local configuration and provider health."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try OutputRenderer.write(
            command: "doctor",
            payload: CommandPayload(
                status: "ok",
                message: "The command shell and shared core are available."
            ),
            format: output.format
        )
    }
}

public struct AgentCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Inspect or run the local background agent."
    )

    @OptionGroup public var output: OutputOptions

    public init() {}

    public func run() throws {
        try OutputRenderer.write(
            command: "agent",
            payload: CommandPayload(
                status: "unavailable",
                message: "Agent installation and control are planned for the background-service milestone."
            ),
            format: output.format
        )
        throw ExitCode(CalopodExitCode.unavailable.rawValue)
    }
}
