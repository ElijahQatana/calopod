import CalopodDomain
import CalopodEventKit
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation

/// Whether a run came from the CLI or the agent's schedule. Recorded for history only.
public enum SyncTrigger: String, Sendable {
    case manual
    case automatic
}

/// The outcome of one run: counts and warnings only, no event detail.
public struct SyncExecutionResult: Sendable {
    public let status: String
    public let mode: SyncMode
    public let window: SyncWindow
    public let items: [SyncPlanItem]
    public let appliedCount: Int
    public let reconciledCount: Int
    public let noOpCount: Int
    public let warnings: [String]
    public let ingestion: EventIngestionSummary
    public let review: SyncReviewSummary

    public init(
        status: String,
        mode: SyncMode,
        window: SyncWindow,
        items: [SyncPlanItem],
        appliedCount: Int,
        reconciledCount: Int,
        noOpCount: Int,
        warnings: [String],
        ingestion: EventIngestionSummary = EventIngestionSummary(),
        review: SyncReviewSummary = SyncReviewSummary()
    ) {
        self.status = status
        self.mode = mode
        self.window = window
        self.items = items
        self.appliedCount = appliedCount
        self.reconciledCount = reconciledCount
        self.noOpCount = noOpCount
        self.warnings = warnings
        self.ingestion = ingestion
        self.review = review
    }
}

/// The shared sync engine. The CLI's `sync` and the agent both call this, for dry-run and apply
/// alike.
public struct SyncEngine: Sendable {
    private let environment: CalopodRuntimeEnvironment

    public init(environment: CalopodRuntimeEnvironment) {
        self.environment = environment
    }

    /// Runs one sync under the process lock and always records an outcome, even on failure.
    public func run(
        _ request: SyncRequest,
        trigger: SyncTrigger
    ) async throws -> SyncExecutionResult {
        guard let window = request.window else {
            throw CalopodRuntimeError.invalidConfiguration("sync-window")
        }
        try environment.stateLocation.prepareDirectory()
        let lock = try ProcessLock.acquire(at: environment.stateLocation.lockURL)
        // Held only by staying alive; `defer` keeps ARC from releasing (and unlocking) `lock`
        // before `execute` finishes.
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

    /// Plans every eligible Arm and, in apply mode only, converges each one. Dry-run never reaches
    /// `performManagedMutation`.
    private func execute(
        mode: SyncMode,
        window: SyncWindow,
        repository: LocalStateRepository
    ) async throws -> SyncExecutionResult {
        let eligibility = try eligibleArms(repository: repository)
        let arms = eligibility.arms
        let sources = try armReadSources(arms: arms, repository: repository)
        // Reads span the tracked window, not just the plan window, so the Calendar and Inbox
        // screens see these calendars as read for the days they show.
        let readWindow = (try? CalendarReadWindow.covering(window)) ?? window
        let armRefresh = await refreshCalendarSources(
            sources,
            from: readWindow.start,
            through: readWindow.end,
            repository: repository
        )
        // Calendars no Arm uses are still shown, so they are read too. A failure here is a
        // warning only; it must not hold back an Arm's writes.
        let otherSources = (try? otherSelectedSources(excluding: sources, repository: repository)) ?? []
        let otherRefresh = await refreshCalendarSources(
            otherSources, from: readWindow.start, through: readWindow.end, repository: repository)
        var ingestion = armRefresh.ingestion
        ingestion.add(otherRefresh.ingestion)
        let refresh = CalendarRefreshSummary(
            ingestion: ingestion, failedSourceCount: armRefresh.failedSourceCount,
            warnings: armRefresh.warnings + otherRefresh.warnings)
        guard let sourceProviders = Dictionary(
            uniquelyKeyed: sources.map { ($0.calendar.id, $0.connection.provider) }
        ) else {
            throw CalopodRuntimeError.invalidConfiguration("arm-source")
        }
        var planItems: [SyncPlanItem] = []
        var review = SyncReviewSummary()
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
            guard let targetProvider = ProviderKind(rawValue: targetConnection.provider) else {
                throw CalopodRuntimeError.invalidConfiguration("target-provider")
            }
            // Checked while planning so a dry-run and the later apply agree on which Arms are
            // blocked.
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
                    mappings: mappings,
                    targetProvider: targetProvider
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
                targetProvider: targetProvider,
                sources: events,
                mappings: mappings,
                targetEvents: observations,
                window: window,
                sourceSnapshotComplete: refresh.failedSourceCount == 0,
                targetSnapshotComplete: targetComplete
            )
            review.add(SyncPlanReview.summarize(
                plan: plan, sources: events,
                sourceProviders: sourceProviders
            ))
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
                warnings: warnings,
                ingestion: refresh.ingestion,
                review: review
            )
        }

        // Apply's safety gate. A dry-run may report a plan from incomplete data with a warning;
        // apply refuses.
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

        guard let armsByID = Dictionary(uniquelyKeyed: arms.map { ($0.id, $0) }) else {
            throw CalopodRuntimeError.invalidConfiguration("arm-duplicate")
        }
        let convergence = ManagedEventConvergenceService(
            repository: repository,
            secretStore: secretStore
        )
        var appliedCount = 0
        var reconciledCount = 0
        var noOpCount = 0
        for armID in armsByID.keys.sorted() {
            guard let arm = armsByID[armID],
                  let target = try repository.calendarBinding(id: arm.targetBindingID),
                  let targetConnection = try repository.connection(id: target.connectionID),
                  let targetProvider = ProviderKind(rawValue: targetConnection.provider) else {
                throw CalopodRuntimeError.invalidConfiguration("arm-target")
            }
            let batch: ManagedEventBatchPerformer?
            #if os(macOS)
            if targetProvider == .eventKit {
                let host = try EventKitHostRunner(environment: environment)
                batch = { try await host.performMutations($0, calendarID: target.providerCalendarID) }
            } else {
                batch = nil
            }
            #else
            batch = nil
            #endif
            let summary: ManagedEventLifecycleSummary
            do {
                summary = try await convergence.converge(
                    initialItems: planItems,
                    arm: arm,
                    targetProvider: targetProvider,
                    initialObservations: observationsByArm[arm.id] ?? [],
                    window: window,
                    readSnapshots: {
                        try await managedTargetSnapshots(
                            target: target,
                            from: window.start,
                            through: window.end,
                            repository: repository
                        )
                    }, performBatch: batch, perform: { mutation in
                        try await performManagedMutation(
                            mutation,
                            target: target,
                            repository: repository
                        )
                    }
                )
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
            warnings: warnings,
            ingestion: refresh.ingestion,
            review: review
        )
    }

    /// Keeps enabled Arms whose Connections are enabled too. Disabled ones are skipped with one
    /// summary warning, not an error.
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

    private func otherSelectedSources(
        excluding used: [CalendarReadSource],
        repository: LocalStateRepository
    ) throws -> [CalendarReadSource] {
        let usedIDs = Set(used.map(\.calendar.id))
        var sources: [CalendarReadSource] = []
        for connection in try repository.connections()
        where connection.isEnabled && ["eventkit", "google", "microsoft"].contains(connection.provider) {
            for calendar in try repository.calendarBindings(connectionID: connection.id)
            where calendar.isSelected && !usedIDs.contains(calendar.id) {
                sources.append(CalendarReadSource(connection: connection, calendar: calendar))
            }
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
        var ingestion = EventIngestionSummary()
        var warnings: [String] = []
        // Sources on one connection are fetched together, so EventKit launches the host once.
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
                    let response = try await EventKitHostRunner(environment: environment).perform(
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
                        ingestion.add(result.ingestion)
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
                        ingestion.add(result.ingestion)
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
        warnings += ingestion.warnings
        return CalendarRefreshSummary(
            ingestion: ingestion,
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
            let response = try await EventKitHostRunner(environment: environment).perform(
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

    /// Routes a mutation to the target's real provider. The lifecycle and convergence services
    /// don't know which one it is.
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
            let response = try await EventKitHostRunner(environment: environment).perform(request)
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
    let ingestion: EventIngestionSummary
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

/// Maps any error to a short generic category, never the error's own message, which could echo
/// provider data.
public func syncFailureCategory(_ error: Error) -> String {
    if let runtime = error as? CalopodRuntimeError {
        return switch runtime {
        case .busy: "busy"
        case .missingEventKitHost, .invalidEventKitHostPath, .eventKitHostUntrusted:
            "eventkit-host"
        case .eventKitHostVersionMismatch: "eventkit-host-version"
        case .eventKitHostFailed: "eventkit-host-response"
        case .eventKitHostTimedOut: "eventkit-host-timeout"
        case .missingGoogleClientID, .missingMicrosoftClientID: "client-id"
        case .invalidConfiguration:
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
    if error is ManagedEventBatchError { return "managed-event-batch" }
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
