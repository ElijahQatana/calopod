import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation

public enum ManagedEventConvergenceError: Error, Equatable, Sendable {
    case didNotConverge
}

/// Drives a single Arm to a converged state: apply the current plan, re-read
/// the target and re-plan, and repeat until nothing is left to do. A single
/// `apply` pass can leave follow-up work behind (a repair that recreates an
/// event still needs that new event picked up by the next plan), so
/// convergence — not one pass — is the actual unit of "sync completed".
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

    /// Repeatedly applies and re-plans (up to `maximumMutationPasses`) until
    /// a pass makes no provider writes or mapping changes, or the resulting
    /// plan is all no-ops. The pass cap exists so a misbehaving provider or
    /// an unexpected oscillation fails loudly with `.didNotConverge` instead
    /// of retrying forever.
    public func converge(
        initialItems: [SyncPlanItem],
        arm: StoredArm,
        targetProvider: ProviderKind,
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

        // Already converged: nothing to apply, so skip straight to the
        // no-op summary without spending a pass or touching the provider.
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

            // A pass that changed nothing can't produce a different plan on
            // the next iteration, so stop rather than re-reading the target
            // for no reason.
            guard summary.providerWriteCount > 0
                    || summary.mappingReconciliationCount > 0 else {
                return ManagedEventLifecycleSummary(
                    providerWriteCount: providerWrites,
                    mappingReconciliationCount: reconciliations,
                    noOpCount: noOps
                )
            }

            // Re-read the target from scratch rather than trust in-memory
            // state after writes, since the provider is the source of truth
            // for what actually landed (IDs, versions, and any changes made
            // concurrently by something else).
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
