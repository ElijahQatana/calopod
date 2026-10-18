import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation

public enum ManagedEventMutation: Sendable {
    case create(ManagedEventWriteRequest)
    case update(
        providerEventID: String,
        expectedVersion: String?,
        request: ManagedEventWriteRequest
    )
    case delete(providerEventID: String, expectedVersion: String?)
}

public enum ManagedEventMutationResult: Sendable {
    case written(ManagedEventWriteResult)
    case deleted
}

public typealias ManagedEventBatchPerformer = @Sendable ([[ManagedEventMutation]]) async throws
    -> [[Result<ManagedEventMutationResult, ProviderFailure>]]

public enum ManagedEventLifecycleError: Error, Equatable, Sendable {
    case ambiguousMapping
    case ambiguousRepair(SyncPlanReason)
    case invalidPlanItem
    case missingVerifiedTarget
    case unexpectedProviderResult
}

public struct ManagedEventLifecycleSummary: Equatable, Sendable {
    public let providerWriteCount: Int
    public let mappingReconciliationCount: Int
    public let noOpCount: Int

    public init(
        providerWriteCount: Int,
        mappingReconciliationCount: Int,
        noOpCount: Int
    ) {
        self.providerWriteCount = providerWriteCount
        self.mappingReconciliationCount = mappingReconciliationCount
        self.noOpCount = noOpCount
    }
}

/// Executes a plan against a provider and keeps the mirror mappings in step. `perform` is injected
/// so tests can use a fake provider.
public struct ManagedEventLifecycleService: Sendable {
    private let repository: LocalStateRepository
    private let keyVault: OwnershipKeyVault

    public init(repository: LocalStateRepository, secretStore: any SecretStore) {
        self.repository = repository
        keyVault = OwnershipKeyVault(secretStore: secretStore)
    }

    /// Applies the Arm's plan items in order. Repairs whose evidence is ambiguous are refused
    /// first; a wrong guess would change the wrong event.
    public func apply(
        items: [SyncPlanItem],
        arm: StoredArm,
        observations: [TargetEventObservation],
        now: @escaping @Sendable () -> Date = Date.init,
        perform: @Sendable (ManagedEventMutation) async throws -> ManagedEventMutationResult
    ) async throws -> ManagedEventLifecycleSummary {
        let relevant = items.filter { $0.armID == arm.id }
        let observationsByMirror = Dictionary(
            grouping: observations.compactMap { observation in
                observation.mirrorKey.map { ($0, observation) }
            },
            by: { $0.0 }
        ).mapValues { $0.map(\.1) }
        for item in relevant where item.action == .repair {
            guard repairIsDeterministic(item, observationsByMirror: observationsByMirror) else {
                throw ManagedEventLifecycleError.ambiguousRepair(item.reason)
            }
        }

        guard var mappings = Dictionary(
            uniquelyKeyed: try repository.mirrorMappings(armID: arm.id).map {
                ($0.mirrorKey, $0)
            }
        ) else {
            throw ManagedEventLifecycleError.ambiguousMapping
        }
        var providerWrites = 0
        var reconciliations = 0
        var noOps = 0

        for item in relevant {
            let verified = (observationsByMirror[item.mirrorKey] ?? [])
                .filter { $0.ownershipStatus == .verified }
            switch item.action {
            case .create:
                let mapping = try await create(
                    item: item,
                    arm: arm,
                    now: now(),
                    perform: perform
                )
                mappings[item.mirrorKey] = mapping
                providerWrites += 1
            case .update:
                guard let mapping = mappings[item.mirrorKey],
                      verified.count == 1,
                      let target = verified.first,
                      target.providerEventID == mapping.providerEventID else {
                    throw ManagedEventLifecycleError.missingVerifiedTarget
                }
                let request = try writeRequest(item: item, arm: arm)
                let result = try await perform(
                    .update(
                        providerEventID: target.providerEventID,
                        expectedVersion: target.providerVersion ?? mapping.providerVersion,
                        request: request
                    )
                )
                guard case let .written(written) = result else {
                    throw ManagedEventLifecycleError.unexpectedProviderResult
                }
                let updated = try mappingAfterWrite(
                    item: item,
                    arm: arm,
                    result: written,
                    now: now()
                )
                try repository.saveMirrorMapping(updated)
                mappings[item.mirrorKey] = updated
                providerWrites += 1
            case .remove:
                guard let mapping = mappings[item.mirrorKey],
                      verified.count == 1,
                      let target = verified.first,
                      target.providerEventID == mapping.providerEventID else {
                    throw ManagedEventLifecycleError.missingVerifiedTarget
                }
                let result = try await perform(
                    .delete(
                        providerEventID: target.providerEventID,
                        expectedVersion: target.providerVersion ?? mapping.providerVersion
                    )
                )
                guard case .deleted = result else {
                    throw ManagedEventLifecycleError.unexpectedProviderResult
                }
                try repository.removeMirrorMapping(mirrorKey: item.mirrorKey)
                mappings.removeValue(forKey: item.mirrorKey)
                providerWrites += 1
            case .noOp:
                // A no-op writes nothing to the provider, but refresh the stored mapping if it
                // drifted (for example a version bump from an unrelated edit).
                noOps += 1
                guard let mapping = mappings[item.mirrorKey],
                      verified.count == 1,
                      let target = verified.first,
                      let fingerprint = item.desiredFingerprint else {
                    continue
                }
                let sourceKeyHash = item.sourceKeyHash ?? mapping.sourceKeyHash
                let ownershipKeyID = target.ownershipKeyID ?? mapping.ownershipKeyID
                let externalID = target.providerExternalID ?? mapping.providerExternalID
                guard mapping.sourceKeyHash != sourceKeyHash
                        || mapping.providerEventID != target.providerEventID
                        || mapping.providerVersion != target.providerVersion
                        || mapping.desiredFingerprint != fingerprint
                        || mapping.ownershipKeyID != ownershipKeyID
                        || mapping.providerExternalID != externalID else {
                    continue
                }
                let refreshed = StoredMirrorMapping(
                    mirrorKey: mapping.mirrorKey,
                    armID: mapping.armID,
                    sourceKeyHash: sourceKeyHash,
                    providerEventID: target.providerEventID,
                    providerVersion: target.providerVersion,
                    desiredFingerprint: fingerprint,
                    ownershipKeyID: ownershipKeyID,
                    updatedAt: now(),
                    providerExternalID: externalID
                )
                try repository.saveMirrorMapping(refreshed)
                mappings[item.mirrorKey] = refreshed
                reconciliations += 1
            case .repair:
                switch item.reason {
                case .mappingMissing, .providerIdentityChanged:
                    // One verified target exists but the mapping is missing or stale: adopt it
                    // instead of creating a second.
                    guard verified.count == 1,
                          let target = verified.first,
                          let sourceKeyHash = item.sourceKeyHash,
                          let fingerprint = item.desiredFingerprint,
                          let ownershipKeyID = target.ownershipKeyID else {
                        throw ManagedEventLifecycleError.missingVerifiedTarget
                    }
                    let adopted = StoredMirrorMapping(
                        mirrorKey: item.mirrorKey,
                        armID: arm.id,
                        sourceKeyHash: sourceKeyHash,
                        providerEventID: target.providerEventID,
                        providerVersion: target.providerVersion,
                        desiredFingerprint: fingerprint,
                        ownershipKeyID: ownershipKeyID,
                        updatedAt: now(),
                        providerExternalID: target.providerExternalID
                    )
                    try repository.saveMirrorMapping(adopted)
                    mappings[item.mirrorKey] = adopted
                    reconciliations += 1
                case .targetMissing:
                    // The mapped event is gone: drop the mapping and recreate if the source still
                    // wants a mirror. This heals a manual delete.
                    if mappings[item.mirrorKey] != nil {
                        try repository.removeMirrorMapping(mirrorKey: item.mirrorKey)
                        mappings.removeValue(forKey: item.mirrorKey)
                        reconciliations += 1
                    }
                    if item.payload != nil {
                        let mapping = try await create(
                            item: item,
                            arm: arm,
                            now: now(),
                            perform: perform
                        )
                        mappings[item.mirrorKey] = mapping
                        providerWrites += 1
                    }
                case .verifiedDuplicates:
                    // Several verified events claim one mirror: keep a deterministic survivor (see
                    // `duplicateOrder`), update it, delete the rest.
                    guard verified.count > 1,
                          item.sourceKeyHash != nil,
                          item.desiredFingerprint != nil else {
                        throw ManagedEventLifecycleError.missingVerifiedTarget
                    }
                    let mapping = mappings[item.mirrorKey]
                    let survivor = verified.sorted {
                        duplicateOrder($0, $1, mappedProviderEventID: mapping?.providerEventID)
                    }[0]
                    let request = try writeRequest(item: item, arm: arm)
                    let updateResult = try await perform(
                        .update(
                            providerEventID: survivor.providerEventID,
                            expectedVersion: survivor.providerVersion,
                            request: request
                        )
                    )
                    guard case let .written(written) = updateResult else {
                        throw ManagedEventLifecycleError.unexpectedProviderResult
                    }
                    let updated = try mappingAfterWrite(
                        item: item,
                        arm: arm,
                        result: written,
                        now: now()
                    )
                    try repository.saveMirrorMapping(updated)
                    mappings[item.mirrorKey] = updated
                    providerWrites += 1

                    for duplicate in verified
                        .filter({ $0.providerEventID != survivor.providerEventID })
                        .sorted(by: { $0.providerEventID < $1.providerEventID }) {
                        let deleteResult = try await perform(
                            .delete(
                                providerEventID: duplicate.providerEventID,
                                expectedVersion: duplicate.providerVersion
                            )
                        )
                        guard case .deleted = deleteResult else {
                            throw ManagedEventLifecycleError.unexpectedProviderResult
                        }
                        providerWrites += 1
                    }
                default:
                    throw ManagedEventLifecycleError.ambiguousRepair(item.reason)
                }
            }
        }

        return ManagedEventLifecycleSummary(
            providerWriteCount: providerWrites,
            mappingReconciliationCount: reconciliations,
            noOpCount: noOps
        )
    }

    // Validate the whole pass before writing, then persist each confirmed result.
    public func applyBatch(
        items: [SyncPlanItem],
        arm: StoredArm,
        observations: [TargetEventObservation],
        perform: ManagedEventBatchPerformer
    ) async throws -> ManagedEventLifecycleSummary {
        let relevant = items.filter { $0.armID == arm.id }
        guard Set(relevant.map(\.mirrorKey)).count == relevant.count,
              let mappings = Dictionary(uniquelyKeyed:
                try repository.mirrorMappings(armID: arm.id).map { ($0.mirrorKey, $0) }) else {
            throw ManagedEventLifecycleError.ambiguousMapping
        }
        let grouped = Dictionary(grouping: observations.filter { $0.mirrorKey != nil },
                                 by: { $0.mirrorKey! })
        var batches: [[ManagedEventMutation]] = []
        for item in relevant {
            let verified = (grouped[item.mirrorKey] ?? []).filter { $0.ownershipStatus == .verified }
            let mapping = mappings[item.mirrorKey]
            var mutations: [ManagedEventMutation] = []
            switch item.action {
            case .create:
                mutations = [.create(try writeRequest(item: item, arm: arm))]
            case .update, .remove:
                guard let mapping, verified.count == 1, let target = verified.first,
                      target.providerEventID == mapping.providerEventID else {
                    throw ManagedEventLifecycleError.missingVerifiedTarget
                }
                let version = target.providerVersion ?? mapping.providerVersion
                if item.action == .remove {
                    mutations = [.delete(providerEventID: target.providerEventID, expectedVersion: version)]
                } else {
                    mutations = [.update(providerEventID: target.providerEventID, expectedVersion: version,
                                         request: try writeRequest(item: item, arm: arm))]
                }
            case .noOp:
                break
            case .repair:
                guard repairIsDeterministic(item, observationsByMirror: grouped) else {
                    throw ManagedEventLifecycleError.ambiguousRepair(item.reason)
                }
                switch item.reason {
                case .targetMissing:
                    if item.payload != nil {
                        mutations = [.create(try writeRequest(item: item, arm: arm))]
                    }
                case .verifiedDuplicates:
                    let survivor = verified.sorted {
                        duplicateOrder($0, $1, mappedProviderEventID: mapping?.providerEventID)
                    }[0]
                    mutations = [.update(providerEventID: survivor.providerEventID,
                                         expectedVersion: survivor.providerVersion,
                                         request: try writeRequest(item: item, arm: arm))]
                    mutations += verified.filter { $0.providerEventID != survivor.providerEventID }
                        .sorted { $0.providerEventID < $1.providerEventID }
                        .map { .delete(providerEventID: $0.providerEventID, expectedVersion: $0.providerVersion) }
                case .mappingMissing, .providerIdentityChanged:
                    break
                default:
                    throw ManagedEventLifecycleError.ambiguousRepair(item.reason)
                }
            }
            batches.append(mutations)
        }
        let results = batches.allSatisfy(\.isEmpty) ? batches.map { _ in [] } : try await perform(batches)
        guard results.count == batches.count,
              zip(results, batches).allSatisfy({ $0.count == $1.count }) else {
            throw ProviderFailure.invalidResponse
        }
        var writes = 0
        var reconciliations = 0
        var noOps = 0
        var failedItems: [Int] = []
        for (index, item) in relevant.enumerated() {
            let replies = MutationReplies(results[index])
            do {
                let summary = try await apply(items: [item], arm: arm, observations: observations) { _ in
                    try await replies.next()
                }
                writes += summary.providerWriteCount
                reconciliations += summary.mappingReconciliationCount
                noOps += summary.noOpCount
            } catch {
                failedItems.append(index)
            }
        }
        guard failedItems.isEmpty else {
            throw ManagedEventBatchError(failedItemIndices: failedItems)
        }
        return ManagedEventLifecycleSummary(providerWriteCount: writes,
                                            mappingReconciliationCount: reconciliations, noOpCount: noOps)
    }

    /// Whether a repair has the evidence its reason expects. Any other reason falls through to
    /// `.ambiguousRepair` and needs a clean re-read.
    private func repairIsDeterministic(
        _ item: SyncPlanItem,
        observationsByMirror: [String: [TargetEventObservation]]
    ) -> Bool {
        let verified = (observationsByMirror[item.mirrorKey] ?? [])
            .filter { $0.ownershipStatus == .verified }
        switch item.reason {
        case .mappingMissing, .providerIdentityChanged:
            return verified.count == 1
                && item.sourceKeyHash != nil
                && item.desiredFingerprint != nil
        case .targetMissing:
            return (observationsByMirror[item.mirrorKey] ?? []).isEmpty
        case .verifiedDuplicates:
            return verified.count > 1
                && item.sourceKeyHash != nil
                && item.desiredFingerprint != nil
        default:
            return false
        }
    }

    /// Ranks duplicates to pick the survivor: the provider's preferred recurring identity, then the
    /// mapped event, then the older one, then ID order. Being deterministic means repeated runs
    /// don't flap.
    private func duplicateOrder(
        _ left: TargetEventObservation,
        _ right: TargetEventObservation,
        mappedProviderEventID: String?
    ) -> Bool {
        let leftRank = (
            left.isProviderPreferredIdentity ? 0 : 1,
            left.providerEventID == mappedProviderEventID ? 0 : 1,
            left.createdAt == nil ? 1 : 0
        )
        let rightRank = (
            right.isProviderPreferredIdentity ? 0 : 1,
            right.providerEventID == mappedProviderEventID ? 0 : 1,
            right.createdAt == nil ? 1 : 0
        )
        if leftRank != rightRank { return leftRank < rightRank }
        if let leftCreated = left.createdAt,
           let rightCreated = right.createdAt,
           leftCreated != rightCreated {
            return leftCreated < rightCreated
        }
        return left.providerEventID < right.providerEventID
    }

    private func create(
        item: SyncPlanItem,
        arm: StoredArm,
        now: Date,
        perform: @Sendable (ManagedEventMutation) async throws -> ManagedEventMutationResult
    ) async throws -> StoredMirrorMapping {
        let request = try writeRequest(item: item, arm: arm)
        let result = try await perform(.create(request))
        guard case let .written(written) = result else {
            throw ManagedEventLifecycleError.unexpectedProviderResult
        }
        let mapping = try mappingAfterWrite(item: item, arm: arm, result: written, now: now)
        try repository.saveMirrorMapping(mapping)
        return mapping
    }

    /// Builds the write payload and signed marker. The marker lets a later sync, possibly on
    /// another device, recognize the event without relying on its ID.
    private func writeRequest(
        item: SyncPlanItem,
        arm: StoredArm
    ) throws -> ManagedEventWriteRequest {
        guard item.armID == arm.id,
              let payload = item.payload,
              let desiredFingerprint = item.desiredFingerprint,
              let sourceKeyHash = item.sourceKeyHash else {
            throw ManagedEventLifecycleError.invalidPlanItem
        }
        let key = try keyVault.loadOrCreate(configurationID: arm.configurationID)
        let binding = try repository.calendarBinding(id: arm.targetBindingID)
        let connection = try binding.flatMap { try repository.connection(id: $0.connectionID) }
        let marker = try OwnershipMarkerCodec.sign(
            configurationID: arm.configurationID,
            armID: arm.id,
            mirrorKey: item.mirrorKey,
            sourceKeyHash: sourceKeyHash,
            ruleMode: arm.ruleMode,
            key: key,
            targetBindingID: connection?.provider == "eventkit" ? arm.targetBindingID : nil
        )
        return ManagedEventWriteRequest(
            desiredFingerprint: desiredFingerprint,
            payload: payload,
            provenance: marker
        )
    }

    private func mappingAfterWrite(
        item: SyncPlanItem,
        arm: StoredArm,
        result: ManagedEventWriteResult,
        now: Date
    ) throws -> StoredMirrorMapping {
        guard let sourceKeyHash = item.sourceKeyHash,
              let fingerprint = item.desiredFingerprint else {
            throw ManagedEventLifecycleError.invalidPlanItem
        }
        let key = try keyVault.loadOrCreate(configurationID: arm.configurationID)
        return StoredMirrorMapping(
            mirrorKey: item.mirrorKey,
            armID: arm.id,
            sourceKeyHash: sourceKeyHash,
            providerEventID: result.providerEventID,
            providerVersion: result.providerVersion,
            desiredFingerprint: fingerprint,
            ownershipKeyID: key.id,
            updatedAt: now,
            providerExternalID: result.providerExternalID
        )
    }
}

public struct ManagedEventBatchError: Error, Equatable, Sendable {
    public let failedItemIndices: [Int]
}

private actor MutationReplies {
    private var replies: [Result<ManagedEventMutationResult, ProviderFailure>]

    init(_ replies: [Result<ManagedEventMutationResult, ProviderFailure>]) {
        self.replies = replies
    }

    func next() throws -> ManagedEventMutationResult {
        guard !replies.isEmpty else { throw ProviderFailure.invalidResponse }
        return try replies.removeFirst().get()
    }
}
