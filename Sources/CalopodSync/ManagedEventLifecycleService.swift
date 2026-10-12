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

/// Executes a `SyncPlan`'s items against a calendar provider and keeps the
/// local mirror-mapping table in sync with what was actually written. This
/// is the only place that turns a plan decision into a real provider
/// mutation; `perform` is injected so the same logic runs against a live
/// provider in production and a fake one in tests.
public struct ManagedEventLifecycleService: Sendable {
    private let repository: LocalStateRepository
    private let keyVault: OwnershipKeyVault

    public init(repository: LocalStateRepository, secretStore: any SecretStore) {
        self.repository = repository
        keyVault = OwnershipKeyVault(secretStore: secretStore)
    }

    /// Applies every plan item that belongs to `arm`, in the order the
    /// planner produced them. Before doing anything, every `.repair` item is
    /// checked for determinism: a repair whose target-side evidence is
    /// ambiguous is refused outright rather than guessed at, since a wrong
    /// guess here means mutating or deleting the wrong calendar event.
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
                // A no-op still writes nothing to the provider, but the
                // locally stored mapping is refreshed if any of its fields
                // have drifted from what was actually observed (for example
                // a provider version bump from an unrelated edit), so later
                // planning passes compare against current, not stale, data.
                noOps += 1
                guard let mapping = mappings[item.mirrorKey],
                      verified.count == 1,
                      let target = verified.first,
                      let fingerprint = item.desiredFingerprint else {
                    continue
                }
                let sourceKeyHash = item.sourceKeyHash ?? mapping.sourceKeyHash
                let ownershipKeyID = target.ownershipKeyID ?? mapping.ownershipKeyID
                guard mapping.sourceKeyHash != sourceKeyHash
                        || mapping.providerEventID != target.providerEventID
                        || mapping.providerVersion != target.providerVersion
                        || mapping.desiredFingerprint != fingerprint
                        || mapping.ownershipKeyID != ownershipKeyID else {
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
                    updatedAt: now()
                )
                try repository.saveMirrorMapping(refreshed)
                mappings[item.mirrorKey] = refreshed
                reconciliations += 1
            case .repair:
                switch item.reason {
                case .mappingMissing, .providerIdentityChanged:
                    // A single verified target exists but the local mapping
                    // doesn't point at it (or points at a stale provider ID)
                    // — adopt the verified event as the mapping's target
                    // rather than creating a second one.
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
                        updatedAt: now()
                    )
                    try repository.saveMirrorMapping(adopted)
                    mappings[item.mirrorKey] = adopted
                    reconciliations += 1
                case .targetMissing:
                    // The mapped event is gone from the target. Drop the
                    // stale mapping first, then recreate it if the source
                    // still wants a mirror — this is what lets a manually
                    // deleted managed event heal itself on the next sync.
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
                    // More than one verified event claims the same mirror.
                    // Pick one deterministic survivor (see `duplicateOrder`),
                    // update it to the desired content, and delete the rest —
                    // never the other way around, so a duplicate never
                    // resolves by silently discarding real content.
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

    /// Whether a `.repair` item has exactly the evidence its reason expects,
    /// so `apply` can act on it without guessing. Any repair reason not
    /// listed here (`ownershipUnverified`, snapshot-incomplete states, and so
    /// on) always falls through to `.ambiguousRepair` — those require a
    /// clean re-read of the target, not an automatic decision.
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

    /// Ranks two duplicate verified events to pick which one survives:
    /// prefer the provider's own preferred identity for a recurring series,
    /// then the event the local mapping already points at, then the older
    /// event, then a stable ID comparison as the final tiebreaker. Keeping
    /// this purely deterministic means repeated runs always converge on the
    /// same survivor instead of flapping between duplicates.
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

    /// Builds the provider write payload plus a signed ownership marker.
    /// EventKit markers sign the target binding and require the stored
    /// provider event ID when a later sync verifies ownership.
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
            updatedAt: now
        )
    }
}
