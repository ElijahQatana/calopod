import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation

public enum ManagedEventConvergenceError: Error, Equatable, Sendable {
    case didNotConverge
}

public struct ManagedEventConvergenceService: Sendable {
    private let repository: LocalStateRepository
    private let lifecycle: ManagedEventLifecycleService
    private let observer: ManagedTargetObserver

    public init(repository: LocalStateRepository, secretStore: any SecretStore) {
        self.repository = repository
        lifecycle = ManagedEventLifecycleService(
            repository: repository,
            secretStore: secretStore
        )
        observer = ManagedTargetObserver(secretStore: secretStore)
    }

    public func converge(
        initialItems: [SyncPlanItem],
        arm: StoredArm,
        initialObservations: [TargetEventObservation],
        window: SyncWindow,
        maximumMutationPasses: Int = 3,
        readSnapshots: @Sendable () async throws -> [ManagedEventSnapshot],
        perform: @Sendable (ManagedEventMutation) async throws -> ManagedEventMutationResult
    ) async throws -> ManagedEventLifecycleSummary {
        var items = initialItems.filter { $0.armID == arm.id }
        var observations = initialObservations
        var providerWrites = 0
        var reconciliations = 0
        var noOps = 0

        if items.allSatisfy({ $0.action == .noOp }) {
            return ManagedEventLifecycleSummary(
                providerWriteCount: 0,
                mappingReconciliationCount: 0,
                noOpCount: items.count
            )
        }

        for pass in 0..<maximumMutationPasses {
            let summary = try await lifecycle.apply(
                items: items,
                arm: arm,
                observations: observations,
                perform: perform
            )
            providerWrites += summary.providerWriteCount
            reconciliations += summary.mappingReconciliationCount
            noOps += summary.noOpCount

            guard summary.providerWriteCount > 0
                    || summary.mappingReconciliationCount > 0 else {
                return ManagedEventLifecycleSummary(
                    providerWriteCount: providerWrites,
                    mappingReconciliationCount: reconciliations,
                    noOpCount: noOps
                )
            }

            let mappings = try repository.mirrorMappings(armID: arm.id)
            observations = try observer.observations(
                snapshots: try await readSnapshots(),
                arm: arm,
                mappings: mappings
            )
            let sources = try repository.normalizedInstances(
                calendarBindingIDs: arm.sourceBindingIDs,
                from: window.start,
                through: window.end
            )
            items = SyncPlanner.plan(
                arm: arm,
                sources: sources,
                mappings: mappings,
                targetEvents: observations,
                window: window,
                sourceSnapshotComplete: true,
                targetSnapshotComplete: true
            ).items
            if items.allSatisfy({ $0.action == .noOp }) {
                return ManagedEventLifecycleSummary(
                    providerWriteCount: providerWrites,
                    mappingReconciliationCount: reconciliations,
                    noOpCount: noOps
                )
            }
            if pass == maximumMutationPasses - 1 {
                throw ManagedEventConvergenceError.didNotConverge
            }
        }

        throw ManagedEventConvergenceError.didNotConverge
    }
}
