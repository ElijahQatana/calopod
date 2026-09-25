import ArgumentParser
import CalopodDomain
import CalopodEventKit
import CalopodProviders
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
        do {
            let resolved = try resolveRange(range, default: .none)
            guard let resolved else {
                throw ValidationError("Pass --day or both --from and --through for a bounded sync.")
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
            var observationsByArm: [String: [TargetEventObservation]] = [:]
            var targetFailureCount = 0
            var targetWarnings: [String] = []
            let secretStore = KeychainSecretStore()
            let observer = ManagedTargetObserver(secretStore: secretStore)
            for arm in arms {
                guard let target = try repository.calendarBinding(id: arm.targetBindingID) else {
                    throw ValidationError("An Arm target calendar is no longer available.")
                }
                let events = try repository.normalizedInstances(
                    calendarBindingIDs: arm.sourceBindingIDs,
                    from: resolved.window.start,
                    through: resolved.window.end
                )
                let mappings = try repository.mirrorMappings(armID: arm.id)
                let observations: [TargetEventObservation]
                let targetComplete: Bool
                do {
                    let snapshots = try await managedTargetSnapshots(
                        target: target,
                        from: resolved.window.start,
                        through: resolved.window.end,
                        repository: repository
                    )
                    observations = try observer.observations(
                        snapshots: snapshots,
                        arm: arm,
                        mappings: mappings
                    )
                    targetComplete = true
                } catch {
                    observations = []
                    targetComplete = false
                    targetFailureCount += 1
                    targetWarnings.append(
                        "A managed target could not be refreshed; no writes will be attempted."
                    )
                }
                observationsByArm[arm.id] = observations
                let plan = SyncPlanner.plan(
                    arm: arm,
                    sources: events,
                    mappings: mappings,
                    targetEvents: observations,
                    window: resolved.window,
                    sourceSnapshotComplete: refresh.failedSourceCount == 0,
                    targetSnapshotComplete: targetComplete
                )
                planItems.append(contentsOf: plan.items)
            }
            planItems.sort {
                ($0.armID, $0.mirrorKey, $0.action.rawValue)
                    < ($1.armID, $1.mirrorKey, $1.action.rawValue)
            }

            if dryRun {
                let warnings = refresh.warnings + targetWarnings
                try OutputRenderer.write(
                    command: "sync",
                    payload: CommandPayload(
                        status: refresh.failedSourceCount == 0 && targetFailureCount == 0
                            ? "ok"
                            : "partial",
                        message: planItems.isEmpty
                            ? "The dry run found no planned operations."
                            : "Dry-run synchronization plan.",
                        count: planItems.count,
                        range: RangeOutput(range: resolved),
                        mode: SyncMode.dryRun.rawValue,
                        items: planItems.map(planItem)
                    ),
                    warnings: warnings,
                    format: output.format
                )
                return
            }

            guard refresh.failedSourceCount == 0 else {
                throw ValidationError("Apply stopped because at least one source calendar could not refresh.")
            }
            guard targetFailureCount == 0 else {
                throw ValidationError("Apply stopped because at least one target calendar could not refresh.")
            }
            let ambiguous = planItems.first {
                $0.action == .repair && !isDeterministicRepair($0)
            }
            if let ambiguous {
                throw ValidationError(
                    "Apply stopped at an ambiguous \(ambiguous.reason.rawValue) repair. Inspect the dry run before retrying."
                )
            }

            let armsByID = Dictionary(uniqueKeysWithValues: arms.map { ($0.id, $0) })
            let lifecycle = ManagedEventLifecycleService(
                repository: repository,
                secretStore: secretStore
            )
            var appliedCount = 0
            var reconciledCount = 0
            var noOpCount = 0
            for armID in armsByID.keys.sorted() {
                guard let arm = armsByID[armID],
                      let target = try repository.calendarBinding(id: arm.targetBindingID) else {
                    throw ValidationError("The planned Arm or target calendar is no longer available.")
                }
                let summary = try await lifecycle.apply(
                    items: planItems,
                    arm: arm,
                    observations: observationsByArm[arm.id] ?? []
                ) { mutation in
                    try await performManagedMutation(
                        mutation,
                        target: target,
                        repository: repository
                    )
                }
                appliedCount += summary.providerWriteCount
                reconciledCount += summary.mappingReconciliationCount
                noOpCount += summary.noOpCount
            }

            let message: String
            if appliedCount > 0 {
                message = "Applied managed event lifecycle changes."
            } else if reconciledCount > 0 {
                message = "Reconciled managed event state without provider writes."
            } else if noOpCount > 0 {
                message = "Managed events already match the requested state."
            } else {
                message = "The sync found no operations to apply."
            }
            try OutputRenderer.write(
                command: "sync",
                payload: CommandPayload(
                    status: "ok",
                    message: message,
                    count: appliedCount,
                    range: RangeOutput(range: resolved),
                    mode: SyncMode.apply.rawValue,
                    items: planItems.map(planItem)
                ),
                warnings: refresh.warnings + targetWarnings,
                format: output.format
            )
        } catch {
            try failCommand(error)
        }
    }
}

private func isDeterministicRepair(_ item: SyncPlanItem) -> Bool {
    switch item.reason {
    case .mappingMissing, .providerIdentityChanged:
        item.sourceKeyHash != nil && item.desiredFingerprint != nil
    case .targetMissing:
        true
    default:
        false
    }
}

private func managedTargetSnapshots(
    target: StoredCalendarBinding,
    from start: Date,
    through end: Date,
    repository: LocalStateRepository
) async throws -> [ManagedEventSnapshot] {
    guard !target.isReadOnly,
          let connection = try repository.connection(id: target.connectionID),
          connection.isEnabled else {
        throw ValidationError("The Arm target calendar is not writable or its Connection is disabled.")
    }
    switch connection.provider {
    case "google":
        return try await CommandEnvironment.googleService().managedEvents(
            connectionID: connection.id,
            binding: target,
            from: start,
            through: end
        )
    case "microsoft":
        return try await CommandEnvironment.microsoftService().managedEvents(
            connectionID: connection.id,
            binding: target,
            from: start,
            through: end
        )
    case "eventkit":
        #if os(macOS)
        let response = try EventKitHostRunner().perform(
            EventKitHostRequest(
                operation: .managedEvents,
                calendarIDs: [target.providerCalendarID],
                start: start,
                end: end
            )
        )
        guard response.status == .fullAccess, response.errorCode == nil else {
            throw ProviderFailure.permissionDenied
        }
        return response.managedEvents
        #else
        throw CommandEnvironmentError.unsupportedPlatform
        #endif
    default:
        throw ValidationError("The Arm target provider does not support managed writes.")
    }
}

private func performManagedMutation(
    _ mutation: ManagedEventMutation,
    target: StoredCalendarBinding,
    repository: LocalStateRepository
) async throws -> ManagedEventMutationResult {
    guard !target.isReadOnly,
          let connection = try repository.connection(id: target.connectionID),
          connection.isEnabled else {
        throw ValidationError("The Arm target calendar is not writable or its Connection is disabled.")
    }
    switch connection.provider {
    case "google":
        let service = try CommandEnvironment.googleService()
        switch mutation {
        case let .create(request):
            return .written(try await service.createManagedEvent(
                connectionID: connection.id,
                binding: target,
                request: request
            ))
        case let .update(providerEventID, expectedVersion, request):
            return .written(try await service.updateManagedEvent(
                connectionID: connection.id,
                binding: target,
                providerEventID: providerEventID,
                expectedVersion: expectedVersion,
                request: request
            ))
        case let .delete(providerEventID, expectedVersion):
            try await service.deleteManagedEvent(
                connectionID: connection.id,
                binding: target,
                providerEventID: providerEventID,
                expectedVersion: expectedVersion
            )
            return .deleted
        }
    case "microsoft":
        let service = try CommandEnvironment.microsoftService()
        switch mutation {
        case let .create(request):
            return .written(try await service.createManagedEvent(
                connectionID: connection.id,
                binding: target,
                request: request
            ))
        case let .update(providerEventID, expectedVersion, request):
            return .written(try await service.updateManagedEvent(
                connectionID: connection.id,
                binding: target,
                providerEventID: providerEventID,
                expectedVersion: expectedVersion,
                request: request
            ))
        case let .delete(providerEventID, expectedVersion):
            try await service.deleteManagedEvent(
                connectionID: connection.id,
                binding: target,
                providerEventID: providerEventID,
                expectedVersion: expectedVersion
            )
            return .deleted
        }
    case "eventkit":
        #if os(macOS)
        let request: EventKitHostRequest
        switch mutation {
        case let .create(managed):
            request = EventKitHostRequest(
                operation: .createManagedEvent,
                calendarIDs: [target.providerCalendarID],
                managedEvent: managed
            )
        case let .update(providerEventID, expectedVersion, managed):
            request = EventKitHostRequest(
                operation: .updateManagedEvent,
                calendarIDs: [target.providerCalendarID],
                managedEvent: managed,
                providerEventID: providerEventID,
                expectedProviderVersion: expectedVersion
            )
        case let .delete(providerEventID, expectedVersion):
            request = EventKitHostRequest(
                operation: .deleteManagedEvent,
                calendarIDs: [target.providerCalendarID],
                providerEventID: providerEventID,
                expectedProviderVersion: expectedVersion
            )
        }
        let response = try EventKitHostRunner().perform(
            request
        )
        guard response.status == .fullAccess, response.errorCode == nil else {
            throw ProviderFailure.invalidResponse
        }
        switch mutation {
        case .create, .update:
            guard let result = response.managedEvent else {
                throw ProviderFailure.invalidResponse
            }
            return .written(result)
        case .delete:
            return .deleted
        }
        #else
        throw CommandEnvironmentError.unsupportedPlatform
        #endif
    default:
        throw ValidationError("The Arm target provider does not support managed writes.")
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
