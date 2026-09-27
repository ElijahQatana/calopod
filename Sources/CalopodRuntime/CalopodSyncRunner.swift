import CalopodDomain
import CalopodEventKit
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation

public enum SyncTrigger: String, Sendable {
    case manual
    case automatic
}

public struct SyncExecutionResult: Sendable {
    public let status: String
    public let mode: SyncMode
    public let window: SyncWindow
    public let items: [SyncPlanItem]
    public let appliedCount: Int
    public let reconciledCount: Int
    public let noOpCount: Int
    public let warnings: [String]

    public init(
        status: String,
        mode: SyncMode,
        window: SyncWindow,
        items: [SyncPlanItem],
        appliedCount: Int,
        reconciledCount: Int,
        noOpCount: Int,
        warnings: [String]
    ) {
        self.status = status
        self.mode = mode
        self.window = window
        self.items = items
        self.appliedCount = appliedCount
        self.reconciledCount = reconciledCount
        self.noOpCount = noOpCount
        self.warnings = warnings
    }
}

public struct SyncEngine: Sendable {
    private let environment: CalopodRuntimeEnvironment

    public init(environment: CalopodRuntimeEnvironment) {
        self.environment = environment
    }

    public func run(
        _ request: SyncRequest,
        trigger: SyncTrigger
    ) async throws -> SyncExecutionResult {
        guard let window = request.window else {
            throw CalopodRuntimeError.invalidConfiguration("sync-window")
        }
        try environment.stateLocation.prepareDirectory()
        let lock = try ProcessLock.acquire(at: environment.stateLocation.lockURL)
        defer { withExtendedLifetime(lock) {} }

        let repository = try environment.repository()
        let runID = try repository.beginSyncRun(
            mode: request.mode.rawValue,
            trigger: trigger.rawValue
        )
        do {
            let result = try await execute(
                mode: request.mode,
                window: window,
                repository: repository
            )
            try repository.finishSyncRun(
                id: runID,
                status: "succeeded",
                plannedCount: result.items.count,
                appliedCount: result.appliedCount,
                reconciledCount: result.reconciledCount,
                noOpCount: result.noOpCount,
                warningCount: result.warnings.count
            )
            return result
        } catch is CancellationError {
            try? repository.finishSyncRun(
                id: runID,
                status: "interrupted",
                errorCode: "interrupted"
            )
            throw CancellationError()
        } catch {
            try? repository.finishSyncRun(
                id: runID,
                status: "failed",
                errorCode: syncFailureCategory(error)
            )
            throw error
        }
    }

    private func execute(
        mode: SyncMode,
        window: SyncWindow,
        repository: LocalStateRepository
    ) async throws -> SyncExecutionResult {
        let eligibility = try eligibleArms(repository: repository)
        let arms = eligibility.arms
        let sources = try armReadSources(arms: arms, repository: repository)
        let refresh = await refreshCalendarSources(
            sources,
            from: window.start,
            through: window.end,
            repository: repository
        )
        var planItems: [SyncPlanItem] = []
        var observationsByArm: [String: [TargetEventObservation]] = [:]
        var targetFailureCount = 0
        var targetWarnings: [String] = []
        var writerBlockedArmIDs = Set<String>()
        let secretStore = KeychainSecretStore()
        let observer = ManagedTargetObserver(secretStore: secretStore)
        for arm in arms {
            guard let target = try repository.calendarBinding(id: arm.targetBindingID),
                  let targetConnection = try repository.connection(id: target.connectionID) else {
                throw CalopodRuntimeError.invalidConfiguration("arm-target")
            }
            if targetConnection.provider == "eventkit" {
                let currentDevice = try repository.currentDevice(
                    configurationID: arm.configurationID
                )
                if !ArmWriterPolicy.allowsApply(
                    arm: arm,
                    targetProvider: .eventKit,
                    currentDeviceID: currentDevice.id
                ) {
                    writerBlockedArmIDs.insert(arm.id)
                    targetWarnings.append(
                        "An EventKit Arm is read-only on this device until it is selected as the preferred writer."
                    )
                }
            }
            let events = try repository.normalizedInstances(
                calendarBindingIDs: arm.sourceBindingIDs,
                from: window.start,
                through: window.end
            )
            let mappings = try repository.mirrorMappings(armID: arm.id)
            let observations: [TargetEventObservation]
            let targetComplete: Bool
            do {
                let snapshots = try await managedTargetSnapshots(
                    target: target,
                    from: window.start,
                    through: window.end,
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
                window: window,
                sourceSnapshotComplete: refresh.failedSourceCount == 0,
                targetSnapshotComplete: targetComplete
            )
            planItems.append(contentsOf: plan.items)
        }
        planItems.sort {
            ($0.armID, $0.mirrorKey, $0.action.rawValue)
                < ($1.armID, $1.mirrorKey, $1.action.rawValue)
        }

        let warnings = eligibility.warnings + refresh.warnings + targetWarnings
        if mode == .dryRun {
            return SyncExecutionResult(
                status: refresh.failedSourceCount == 0 && targetFailureCount == 0
                    ? "ok"
                    : "partial",
                mode: mode,
                window: window,
                items: planItems,
                appliedCount: 0,
                reconciledCount: 0,
                noOpCount: planItems.filter { $0.action == .noOp }.count,
                warnings: warnings
            )
        }

        guard refresh.failedSourceCount == 0 else {
            throw CalopodRuntimeError.sourceRefreshFailed
        }
        guard targetFailureCount == 0 else {
            throw CalopodRuntimeError.targetRefreshFailed
        }
        guard writerBlockedArmIDs.isEmpty else {
            throw CalopodRuntimeError.writerNotPreferred
        }
        guard !planItems.contains(where: {
            $0.action == .repair && !isDeterministicRepair($0)
        }) else {
            throw CalopodRuntimeError.ambiguousRepair
        }

        let armsByID = Dictionary(uniqueKeysWithValues: arms.map { ($0.id, $0) })
        let convergence = ManagedEventConvergenceService(
            repository: repository,
            secretStore: secretStore
        )
        var appliedCount = 0
        var reconciledCount = 0
        var noOpCount = 0
        for armID in armsByID.keys.sorted() {
            guard let arm = armsByID[armID],
                  let target = try repository.calendarBinding(id: arm.targetBindingID) else {
                throw CalopodRuntimeError.invalidConfiguration("arm-target")
            }
            let summary: ManagedEventLifecycleSummary
            do {
                summary = try await convergence.converge(
                    initialItems: planItems,
                    arm: arm,
                    initialObservations: observationsByArm[arm.id] ?? [],
                    window: window
                ) {
                    try await managedTargetSnapshots(
                        target: target,
                        from: window.start,
                        through: window.end,
                        repository: repository
                    )
                } perform: { mutation in
                    try await performManagedMutation(
                        mutation,
                        target: target,
                        repository: repository
                    )
                }
            } catch ManagedEventConvergenceError.didNotConverge {
                throw CalopodRuntimeError.convergenceFailed
            }
            appliedCount += summary.providerWriteCount
            reconciledCount += summary.mappingReconciliationCount
            noOpCount += summary.noOpCount
        }

        return SyncExecutionResult(
            status: "ok",
            mode: mode,
            window: window,
            items: planItems,
            appliedCount: appliedCount,
            reconciledCount: reconciledCount,
            noOpCount: noOpCount,
            warnings: warnings
        )
    }

    private func eligibleArms(
        repository: LocalStateRepository
    ) throws -> (arms: [StoredArm], warnings: [String]) {
        var arms: [StoredArm] = []
        var skippedDisabledConnection = false
        for arm in try repository.arms() where arm.isEnabled {
            guard let target = try repository.calendarBinding(id: arm.targetBindingID),
                  let targetConnection = try repository.connection(id: target.connectionID) else {
                throw CalopodRuntimeError.invalidConfiguration("arm-target")
            }
            var connections = [targetConnection]
            for sourceID in arm.sourceBindingIDs {
                guard let source = try repository.calendarBinding(id: sourceID),
                      source.isSelected,
                      let connection = try repository.connection(id: source.connectionID) else {
                    throw CalopodRuntimeError.invalidConfiguration("arm-source")
                }
                connections.append(connection)
            }
            if connections.contains(where: { !$0.isEnabled }) {
                skippedDisabledConnection = true
                continue
            }
            arms.append(arm)
        }
        return (
            arms,
            skippedDisabledConnection
                ? ["Skipped an Arm because one of its Connections is disabled."]
                : []
        )
    }

    private func armReadSources(
        arms: [StoredArm],
        repository: LocalStateRepository
    ) throws -> [CalendarReadSource] {
        let sourceIDs = Set(arms.flatMap(\.sourceBindingIDs))
        var sources: [CalendarReadSource] = []
        for sourceID in sourceIDs.sorted() {
            guard let calendar = try repository.calendarBinding(id: sourceID), calendar.isSelected,
                  let connection = try repository.connection(id: calendar.connectionID),
                  connection.isEnabled,
                  ["eventkit", "google", "microsoft"].contains(connection.provider) else {
                throw CalopodRuntimeError.invalidConfiguration("arm-source")
            }
            sources.append(CalendarReadSource(connection: connection, calendar: calendar))
        }
        return sources
    }

    private func refreshCalendarSources(
        _ sources: [CalendarReadSource],
        from start: Date,
        through end: Date,
        repository: LocalStateRepository
    ) async -> CalendarRefreshSummary {
        let cache = EventCache(repository: repository)
        var failedCount = 0
        var discardedCount = 0
        var warnings: [String] = []
        var groups: [(connection: StoredConnection, sources: [CalendarReadSource])] = []
        for source in sources {
            if let index = groups.firstIndex(where: { $0.connection.id == source.connection.id }) {
                groups[index].sources.append(source)
            } else {
                groups.append((source.connection, [source]))
            }
        }

        for group in groups {
            var failureCode: String?
            if group.connection.provider == "eventkit" {
                do {
                    let response = try EventKitHostRunner(environment: environment).perform(
                        EventKitHostRequest(
                            operation: .events,
                            calendarIDs: group.sources.map(\.calendar.providerCalendarID),
                            start: start,
                            end: end
                        )
                    )
                    guard response.status == .fullAccess, response.errorCode == nil else {
                        throw ProviderFailure.permissionDenied
                    }
                    for source in group.sources {
                        let page = ProviderEventPage(
                            events: response.events.filter {
                                $0.calendarID == source.calendar.providerCalendarID
                            },
                            nextSyncToken: nil,
                            refreshMode: .full
                        )
                        let result = try cache.apply(
                            page,
                            connection: source.connection,
                            calendar: source.calendar,
                            from: start,
                            through: end
                        )
                        discardedCount += result.discardedCount
                    }
                } catch {
                    failedCount += group.sources.count
                    failureCode = refreshFailureCode(error)
                }
            } else {
                for source in group.sources {
                    do {
                        let page = try await readEvents(
                            connection: source.connection,
                            binding: source.calendar,
                            start: start,
                            end: end,
                            repository: repository
                        )
                        let result = try cache.apply(
                            page,
                            connection: source.connection,
                            calendar: source.calendar,
                            from: start,
                            through: end
                        )
                        discardedCount += result.discardedCount
                    } catch {
                        failedCount += 1
                        failureCode = failureCode ?? refreshFailureCode(error)
                    }
                }
            }

            if let failureCode {
                try? repository.markConnectionStale(
                    connectionID: group.connection.id,
                    errorCode: failureCode
                )
                warnings.append(
                    "\(providerDisplayName(group.connection.provider)) could not refresh every selected calendar; cached data may be stale."
                )
            }
        }
        if discardedCount > 0 {
            warnings.append("Ignored \(discardedCount) malformed or out-of-range event records.")
        }
        return CalendarRefreshSummary(
            failedSourceCount: failedCount,
            warnings: warnings
        )
    }

    private func readEvents(
        connection: StoredConnection,
        binding: StoredCalendarBinding,
        start: Date,
        end: Date,
        repository: LocalStateRepository
    ) async throws -> ProviderEventPage {
        switch connection.provider {
        case "google":
            return try await environment.googleService(repository: repository).events(
                connectionID: connection.id,
                binding: binding,
                from: start,
                through: end,
                useIncrementalRefresh: true
            )
        case "microsoft":
            return try await environment.microsoftService(repository: repository).events(
                connectionID: connection.id,
                binding: binding,
                from: start,
                through: end,
                useIncrementalRefresh: true
            )
        default:
            throw CalopodRuntimeError.invalidConfiguration("source-provider")
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
            throw CalopodRuntimeError.invalidConfiguration("arm-target")
        }
        switch connection.provider {
        case "google":
            return try await environment.googleService(repository: repository).managedEvents(
                connectionID: connection.id,
                binding: target,
                from: start,
                through: end
            )
        case "microsoft":
            return try await environment.microsoftService(repository: repository).managedEvents(
                connectionID: connection.id,
                binding: target,
                from: start,
                through: end
            )
        case "eventkit":
            #if os(macOS)
            let response = try EventKitHostRunner(environment: environment).perform(
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
            throw CalopodRuntimeError.unsupportedPlatform
            #endif
        default:
            throw CalopodRuntimeError.invalidConfiguration("target-provider")
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
            throw CalopodRuntimeError.invalidConfiguration("arm-target")
        }
        switch connection.provider {
        case "google":
            let service = try environment.googleService(repository: repository)
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
            let service = try environment.microsoftService(repository: repository)
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
            let response = try EventKitHostRunner(environment: environment).perform(request)
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
            throw CalopodRuntimeError.unsupportedPlatform
            #endif
        default:
            throw CalopodRuntimeError.invalidConfiguration("target-provider")
        }
    }
}

private struct CalendarReadSource: Sendable {
    let connection: StoredConnection
    let calendar: StoredCalendarBinding
}

private struct CalendarRefreshSummary: Sendable {
    let failedSourceCount: Int
    let warnings: [String]
}

private func isDeterministicRepair(_ item: SyncPlanItem) -> Bool {
    switch item.reason {
    case .mappingMissing, .providerIdentityChanged:
        item.sourceKeyHash != nil && item.desiredFingerprint != nil
    case .targetMissing:
        true
    case .verifiedDuplicates:
        item.sourceKeyHash != nil && item.desiredFingerprint != nil
    default:
        false
    }
}

public func syncFailureCategory(_ error: Error) -> String {
    if let runtime = error as? CalopodRuntimeError {
        return switch runtime {
        case .busy: "busy"
        case .missingEventKitHost, .invalidEventKitHostPath: "eventkit-host"
        case .eventKitHostFailed: "eventkit-host-response"
        case .missingGoogleClientID, .missingMicrosoftClientID, .invalidConfiguration:
            "configuration"
        case .unsupportedPlatform: "unsupported-platform"
        case .invalidStatePath: "local-state"
        case .noEnabledArms: "configuration"
        case .sourceRefreshFailed: "source-refresh"
        case .targetRefreshFailed: "target-refresh"
        case .writerNotPreferred: "writer-policy"
        case .ambiguousRepair: "ambiguous-repair"
        case .convergenceFailed: "convergence"
        }
    }
    if error is SecretStoreError { return "credential-access" }
    guard let provider = error as? ProviderFailure else { return "local-state" }
    return switch provider {
    case .accountPolicyRequired: "account-policy"
    case .authorizationRequired, .refreshRejected: "authorization"
    case .configurationMissing: "configuration"
    case .consentDenied: "consent"
    case .cursorExpired: "cursor"
    case .httpStatus: "provider-http"
    case .invalidResponse: "provider-response"
    case .permissionDenied: "permission"
    case .temporaryFailure: "temporary"
    }
}

private func refreshFailureCode(_ error: Error) -> String {
    syncFailureCategory(error)
}

private func providerDisplayName(_ provider: String) -> String {
    switch provider {
    case "eventkit": "Calendars on this Mac"
    case "google": "Google Calendar"
    case "microsoft": "Microsoft Calendar"
    default: "Calendar provider"
    }
}
