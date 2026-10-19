import ArgumentParser
import CalopodDomain
import CalopodRuntime
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
        do {
            let resolved = try resolveRange(range, default: .none)
            guard let resolved else {
                throw ValidationError("Pass --day or both --from and --through for a bounded sync.")
            }
            let mode: SyncMode = dryRun ? .dryRun : .apply
            let result = try await CalopodRuntime.SyncEngine(
                environment: try CommandEnvironment.runtimeEnvironment()
            ).run(
                SyncRequest(mode: mode, window: resolved.window),
                trigger: .manual
            )

            let message: String
            if result.items.contains(where: \.isUnchecked) {
                message = SyncPlanItem.uncheckedExplanation
            } else if mode == .dryRun {
                message = result.items.isEmpty
                    ? "The dry run found no planned operations."
                    : "Dry-run synchronization plan."
            } else if result.appliedCount > 0 {
                message = "Applied managed event lifecycle changes."
            } else if result.reconciledCount > 0 {
                message = "Reconciled managed event state without provider writes."
            } else if result.noOpCount > 0 {
                message = "Managed events already match the requested state."
            } else {
                message = "The sync found no operations to apply."
            }
            try OutputRenderer.write(
                command: "sync",
                payload: CommandPayload(
                    status: result.status,
                    message: message,
                    count: mode == .dryRun ? result.items.count : result.appliedCount,
                    range: RangeOutput(range: resolved),
                    mode: mode.rawValue,
                    items: result.items.map(planItem),
                    ingestion: result.ingestion,
                    review: result.review
                ),
                warnings: result.warnings.filter { $0 != SyncPlanItem.uncheckedExplanation },
                format: output.format,
                showIDs: output.ids,
                human: HumanOutputContext(applied: result.appliedCount, reconciled: result.reconciledCount, noOps: result.noOpCount)
            )
        } catch {
            try failCommand(error)
        }
    }
}

private func planItem(_ item: SyncPlanItem) -> CommandItem {
    CommandItem(
        id: item.id,
        kind: item.isUnchecked ? "unchecked" : item.action.rawValue,
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
