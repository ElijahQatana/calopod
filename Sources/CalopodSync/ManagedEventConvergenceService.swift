import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation

public enum ManagedEventConvergenceError: Error, Equatable, Sendable {
    case didNotConverge
}

/// Drives an Arm to a converged state: apply, re-read the target, re-plan, repeat. One pass can
/// leave follow-up work, such as a recreated event, so convergence is what counts as done.
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

    /// Applies and re-plans up to `maximumMutationPasses` times, until a pass writes nothing or the
    /// plan is all no-ops. The cap makes an oscillation fail with `.didNotConverge`.
    public func converge(
        initialItems: [SyncPlanItem],
        arm: StoredArm,
        targetProvider: ProviderKind,
        initialObservations: [TargetEventObservation],
        window: SyncWindow,
        maximumMutationPasses: Int = 3,
        readSnapshots: @Sendable () async throws -> [ManagedEventSnapshot],
        performBatch: ManagedEventBatchPerformer? = nil,
        perform: @Sendable (ManagedEventMutation) async throws -> ManagedEventMutationResult
    ) async throws -> ManagedEventLifecycleSummary {
        var items = initialItems.filter { $0.armID == arm.id }
        var observations = initialObservations
        var providerWrites = 0
        var reconciliations = 0
        var noOps = 0

        // Already converged: skip straight to the summary.
        if items.allSatisfy({ $0.action == .noOp }) {
            return ManagedEventLifecycleSummary(
                providerWriteCount: 0,
                mappingReconciliationCount: 0,
                noOpCount: items.count
            )
        }

        for pass in 0..<maximumMutationPasses {
            let summary: ManagedEventLifecycleSummary
            if let performBatch {
                summary = try await lifecycle.applyBatch(
                    items: items, arm: arm, observations: observations, perform: performBatch
                )
            } else {
                summary = try await lifecycle.apply(
                    items: items, arm: arm, observations: observations, perform: perform
                )
            }
            providerWrites += summary.providerWriteCount
            reconciliations += summary.mappingReconciliationCount
            noOps += summary.noOpCount

            // A pass that changed nothing can't change the next plan, so stop.
            guard summary.providerWriteCount > 0
                    || summary.mappingReconciliationCount > 0 else {
                return ManagedEventLifecycleSummary(
                    providerWriteCount: providerWrites,
                    mappingReconciliationCount: reconciliations,
                    noOpCount: noOps
                )
            }

            // Re-read the target after writes; the provider is the truth for IDs, versions and
            // concurrent edits.
            let mappings = try repository.mirrorMappings(armID: arm.id)
            observations = try observer.observations(
                snapshots: try await readSnapshots(),
                arm: arm,
                mappings: mappings,
                targetProvider: targetProvider
            )
            let sources = try repository.normalizedInstances(
                calendarBindingIDs: arm.sourceBindingIDs,
                from: window.start,
                through: window.end
            )
            items = SyncPlanner.plan(
                arm: arm,
                targetProvider: targetProvider,
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
