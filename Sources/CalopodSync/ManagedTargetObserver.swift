import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation

/// Turns target snapshots into ownership-classified observations, so the planner and lifecycle
/// service can trust `ownershipStatus`.
public struct ManagedTargetObserver: Sendable {
    private let keyVault: OwnershipKeyVault

    public init(secretStore: any SecretStore) {
        keyVault = OwnershipKeyVault(secretStore: secretStore)
    }

    /// Classifies each snapshot by its marker:
    /// - `.absent`: no marker. Unmanaged unless a mapping claims the event, in which case the
    ///   marker was lost.
    /// - `.invalid`: a marker exists but came back corrupted.
    /// - `.parsed`: decoded, then checked against this configuration, Arm and mirror key, and
    ///   finally verified with the ownership key.
    public func observations(
        snapshots: [ManagedEventSnapshot],
        arm: StoredArm,
        mappings: [StoredMirrorMapping],
        targetProvider: ProviderKind = .eventKit
    ) throws -> [TargetEventObservation] {
        let ownershipKey = try keyVault.load(configurationID: arm.configurationID)
        let mappingsByProviderID = Dictionary(
            mappings.filter { $0.armID == arm.id }.map { ($0.providerEventID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return snapshots.compactMap { snapshot in
            let mapped = mappingsByProviderID[snapshot.providerEventID]
            switch snapshot.markerStatus {
            case .absent:
                return TargetEventObservation(
                    calendarBindingID: arm.targetBindingID,
                    providerEventID: snapshot.providerEventID,
                    providerVersion: snapshot.providerVersion,
                    mirrorKey: mapped?.mirrorKey,
                    contentFingerprint: nil,
                    ownershipKeyID: mapped?.ownershipKeyID,
                    ownershipStatus: mapped == nil ? .unmanaged : .missingMarker,
                    createdAt: snapshot.createdAt,
                    isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity,
                    providerExternalID: snapshot.providerExternalID
                )
            case .invalid:
                return TargetEventObservation(
                    calendarBindingID: arm.targetBindingID,
                    providerEventID: snapshot.providerEventID,
                    providerVersion: snapshot.providerVersion,
                    mirrorKey: mapped?.mirrorKey,
                    contentFingerprint: nil,
                    ownershipKeyID: mapped?.ownershipKeyID,
                    ownershipStatus: .invalidMarker,
                    createdAt: snapshot.createdAt,
                    isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity,
                    providerExternalID: snapshot.providerExternalID
                )
            case .parsed:
                guard let marker = snapshot.provenance else {
                    return TargetEventObservation(
                        calendarBindingID: arm.targetBindingID,
                        providerEventID: snapshot.providerEventID,
                        providerVersion: snapshot.providerVersion,
                        mirrorKey: mapped?.mirrorKey,
                        contentFingerprint: nil,
                        ownershipKeyID: mapped?.ownershipKeyID,
                        ownershipStatus: .invalidMarker,
                        createdAt: snapshot.createdAt,
                        isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity,
                        providerExternalID: snapshot.providerExternalID
                    )
                }
                // A marker for another configuration or Arm isn't ours to manage. Report it only if
                // a mapping points at it.
                guard marker.configurationID == arm.configurationID else {
                    guard let mapped else { return nil }
                    return TargetEventObservation(
                        calendarBindingID: arm.targetBindingID,
                        providerEventID: snapshot.providerEventID,
                        providerVersion: snapshot.providerVersion,
                        mirrorKey: mapped.mirrorKey,
                        contentFingerprint: nil,
                        ownershipKeyID: marker.ownershipKeyID,
                        ownershipStatus: .unknownConfiguration,
                        createdAt: snapshot.createdAt,
                        isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity,
                        providerExternalID: snapshot.providerExternalID
                    )
                }
                guard marker.armID == arm.id else {
                    guard let mapped else { return nil }
                    return TargetEventObservation(
                        calendarBindingID: arm.targetBindingID,
                        providerEventID: snapshot.providerEventID,
                        providerVersion: snapshot.providerVersion,
                        mirrorKey: mapped.mirrorKey,
                        contentFingerprint: nil,
                        ownershipKeyID: marker.ownershipKeyID,
                        ownershipStatus: .unknownArm,
                        createdAt: snapshot.createdAt,
                        isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity,
                        providerExternalID: snapshot.providerExternalID
                    )
                }
                let expectedMirror = SyncPlanner.mirrorKey(
                    armID: arm.id,
                    sourceKeyHash: marker.sourceKeyHash
                )
                // The marker must match the mirror key from its own source hash and the stored
                // mapping; a mismatch means it can't be trusted.
                let status: TargetOwnershipStatus
                let mappedMarkerMismatch = mapped.map {
                    $0.mirrorKey != marker.mirrorKey || $0.sourceKeyHash != marker.sourceKeyHash
                } ?? false
                if ![1, 2].contains(marker.schemaVersion)
                    || marker.mirrorKey != expectedMirror
                    || mappedMarkerMismatch {
                    status = .invalidMarker
                } else if let ownershipKey,
                          ownershipKey.id == marker.ownershipKeyID,
                          (try? OwnershipMarkerCodec.verify(marker, key: ownershipKey)) != nil {
                    if (marker.schemaVersion == 2 && marker.targetBindingID != arm.targetBindingID)
                        || (targetProvider == .eventKit && mapped == nil) {
                        status = .wrongTarget
                    } else {
                        status = .verified
                    }
                } else if ownershipKey == nil {
                    status = .unknownConfiguration
                } else {
                    status = .invalidMarker
                }
                let fingerprint = snapshot.payload.map {
                    SyncPlanner.desiredFingerprint(payload: $0, ruleMode: marker.ruleMode)
                }
                return TargetEventObservation(
                    calendarBindingID: arm.targetBindingID,
                    providerEventID: snapshot.providerEventID,
                    providerVersion: snapshot.providerVersion,
                    mirrorKey: mapped?.mirrorKey ?? marker.mirrorKey,
                    contentFingerprint: fingerprint,
                    ownershipKeyID: marker.ownershipKeyID,
                    ownershipStatus: status,
                    createdAt: snapshot.createdAt,
                    isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity,
                    providerExternalID: snapshot.providerExternalID
                )
            }
        }.sorted {
            ($0.mirrorKey ?? "", $0.providerEventID)
                < ($1.mirrorKey ?? "", $1.providerEventID)
        }
    }
}
