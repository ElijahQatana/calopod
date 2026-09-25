import CalopodProviders
import CalopodStore
import Foundation

public struct ManagedTargetObserver: Sendable {
    private let keyVault: OwnershipKeyVault

    public init(secretStore: any SecretStore) {
        keyVault = OwnershipKeyVault(secretStore: secretStore)
    }

    public func observations(
        snapshots: [ManagedEventSnapshot],
        arm: StoredArm,
        mappings: [StoredMirrorMapping]
    ) throws -> [TargetEventObservation] {
        let ownershipKey = try keyVault.load(configurationID: arm.configurationID)
        let mappingsByProviderID = Dictionary(
            mappings.map { ($0.providerEventID, $0) },
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
                    isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity
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
                    isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity
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
                        isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity
                    )
                }
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
                        isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity
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
                        isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity
                    )
                }
                let expectedMirror = SyncPlanner.mirrorKey(
                    armID: arm.id,
                    sourceKeyHash: marker.sourceKeyHash
                )
                let status: TargetOwnershipStatus
                let mappedMarkerMismatch = mapped.map {
                    $0.mirrorKey != marker.mirrorKey || $0.sourceKeyHash != marker.sourceKeyHash
                } ?? false
                if marker.schemaVersion != 1
                    || marker.mirrorKey != expectedMirror
                    || mappedMarkerMismatch {
                    status = .invalidMarker
                } else if let ownershipKey,
                          ownershipKey.id == marker.ownershipKeyID,
                          (try? OwnershipMarkerCodec.verify(marker, key: ownershipKey)) != nil {
                    status = .verified
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
                    isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity
                )
            }
        }.sorted {
            ($0.mirrorKey ?? "", $0.providerEventID)
                < ($1.mirrorKey ?? "", $1.providerEventID)
        }
    }
}
