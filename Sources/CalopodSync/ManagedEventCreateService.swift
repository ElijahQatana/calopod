import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation

public enum ManagedEventCreateError: Error, Equatable, Sendable {
    case invalidPlanItem
}

/// Minimal, single-item counterpart to `ManagedEventLifecycleService`: signs
/// and issues one `.create` mutation and records the resulting mapping. Kept
/// separate so a caller that only ever creates managed events (rather than
/// running the full plan-and-repair lifecycle) doesn't need to depend on the
/// larger service.
public struct ManagedEventCreateService: Sendable {
    private let repository: LocalStateRepository
    private let keyVault: OwnershipKeyVault

    public init(repository: LocalStateRepository, secretStore: any SecretStore) {
        self.repository = repository
        keyVault = OwnershipKeyVault(secretStore: secretStore)
    }

    @discardableResult
    public func applyCreate(
        _ item: SyncPlanItem,
        arm: StoredArm,
        now: Date = Date(),
        perform: @Sendable (ManagedEventWriteRequest) async throws -> ManagedEventWriteResult
    ) async throws -> StoredMirrorMapping {
        guard item.action == .create,
              item.armID == arm.id,
              let payload = item.payload,
              let desiredFingerprint = item.desiredFingerprint,
              let sourceKeyHash = item.sourceKeyHash else {
            throw ManagedEventCreateError.invalidPlanItem
        }
        let ownershipKey = try keyVault.loadOrCreate(configurationID: arm.configurationID)
        let binding = try repository.calendarBinding(id: arm.targetBindingID)
        let connection = try binding.flatMap { try repository.connection(id: $0.connectionID) }
        let provenance = try OwnershipMarkerCodec.sign(
            configurationID: arm.configurationID,
            armID: arm.id,
            mirrorKey: item.mirrorKey,
            sourceKeyHash: sourceKeyHash,
            ruleMode: arm.ruleMode,
            key: ownershipKey,
            targetBindingID: connection?.provider == "eventkit" ? arm.targetBindingID : nil
        )
        let result = try await perform(
            ManagedEventWriteRequest(
                desiredFingerprint: desiredFingerprint,
                payload: payload,
                provenance: provenance
            )
        )
        let mapping = StoredMirrorMapping(
            mirrorKey: item.mirrorKey,
            armID: arm.id,
            sourceKeyHash: sourceKeyHash,
            providerEventID: result.providerEventID,
            providerVersion: result.providerVersion,
            desiredFingerprint: desiredFingerprint,
            ownershipKeyID: ownershipKey.id,
            updatedAt: now
        )
        try repository.saveMirrorMapping(mapping)
        return mapping
    }
}
