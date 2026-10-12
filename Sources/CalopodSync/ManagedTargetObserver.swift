import CalopodDomain
import CalopodProviders
import CalopodStore
import Foundation

/// Turns raw target-calendar snapshots into ownership-classified
/// `TargetEventObservation`s. This is where the signed ownership marker on
/// each event is decoded and checked, so everything downstream (the planner,
/// the lifecycle service) can trust `ownershipStatus` instead of
/// re-inspecting provider data itself.
public struct ManagedTargetObserver: Sendable {
    private let keyVault: OwnershipKeyVault

    public init(secretStore: any SecretStore) {
        keyVault = OwnershipKeyVault(secretStore: secretStore)
    }

    /// Classifies each snapshot by what its marker (if any) proves:
    /// - `.absent` — no marker at all; unmanaged unless a mapping already
    ///   claims this provider event, in which case the marker was lost.
    /// - `.invalid` — a marker exists but the provider couldn't return it
    ///   uncorrupted.
    /// - `.parsed` — a marker decoded successfully and is checked against
    ///   this configuration, this Arm, its expected mirror key, and finally
    ///   cryptographically verified against the stored ownership key.
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
                // A marker for a different configuration or Arm isn't this
                // Arm's event to manage. It's only reported at all if a
                // mapping already points at it — otherwise it's silently
                // dropped since it belongs to someone else's setup.
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
                // The marker must agree with both the mirror key recomputed
                // from its own source hash and whatever the local mapping
                // already recorded; any mismatch means the marker can't be
                // trusted even though it decoded successfully.
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
                    isProviderPreferredIdentity: snapshot.isProviderPreferredIdentity
                )
            }
        }.sorted {
            ($0.mirrorKey ?? "", $0.providerEventID)
                < ($1.mirrorKey ?? "", $1.providerEventID)
        }
    }
}
