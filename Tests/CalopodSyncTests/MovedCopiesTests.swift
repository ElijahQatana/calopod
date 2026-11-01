import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import CalopodTestSupport
import Foundation
import Testing

@Suite("Copies from another Mac")
struct MovedCopiesTests {
    enum NewMac: CaseIterable {
        case noKeyYet
        case ownKey
        case newArmID
    }

    @Test("Copies signed by another Mac's key are reported, and a new Arm ID duplicates them",
          arguments: NewMac.allCases, [ProviderKind.eventKit, .google])
    func firstPlan(newMac: NewMac, targetProvider: ProviderKind) throws {
        let oldArm = movedArm(id: "synthetic-arm")
        let oldKey = try OwnershipKeyVault(secretStore: MemorySecretStore())
            .loadOrCreate(configurationID: oldArm.configurationID)
        let mirror = SyncPlanner.mirrorKey(armID: oldArm.id, sourceKeyHash: "source-one")
        let signed = try OwnershipMarkerCodec.sign(
            configurationID: oldArm.configurationID, armID: oldArm.id, mirrorKey: mirror,
            sourceKeyHash: "source-one", ruleMode: .busy, key: oldKey, targetBindingID: oldArm.targetBindingID
        )
        let marker = try OwnershipMarkerCodec.marker(from: OwnershipMarkerCodec.markerURL(signed))
        let copy = ManagedEventSnapshot(
            providerEventID: "provider-copy", providerVersion: "v1", payload: nil,
            markerStatus: .parsed, provenance: marker
        )

        let secrets = MemorySecretStore()
        if newMac == .ownKey {
            _ = try OwnershipKeyVault(secretStore: secrets).loadOrCreate(configurationID: oldArm.configurationID)
        }
        let arm = newMac == .newArmID ? movedArm(id: "synthetic-new-arm") : oldArm
        let observations = try ManagedTargetObserver(secretStore: secrets)
            .observations(snapshots: [copy], arm: arm, mappings: [])
        let source = StoredNormalizedInstance(
            sourceKeyHash: "source-one", connectionID: "synthetic-connection",
            calendarBindingID: "source-calendar", providerEventID: "provider-source",
            recurrenceID: nil, startsAt: Date(timeIntervalSince1970: 2_000),
            endsAt: Date(timeIntervalSince1970: 2_600), isAllDay: false, availability: "busy",
            isCancelled: false, isPrivate: false, title: "Synthetic source event",
            contentFingerprint: "source-fingerprint", providerUpdatedAt: nil
        )
        let plan = SyncPlanner.plan(
            arm: arm, targetProvider: targetProvider, sources: [source], mappings: [],
            targetEvents: observations, window: try SyncWindow(
                start: Date(timeIntervalSince1970: 1_000), end: Date(timeIntervalSince1970: 8_000)
            ), sourceSnapshotComplete: true
        )

        let actions = plan.items.map(\.action)
        if newMac == .newArmID {
            #expect(actions == [.create])
        } else {
            #expect(actions == [.repair])
            #expect(plan.items.map(\.reason) == [.ownershipUnverified])
        }
    }
}

private func movedArm(id: String) -> StoredArm {
    StoredArm(
        id: id, configurationID: "default", sourceBindingIDs: ["source-calendar"],
        targetBindingID: "target-calendar", ruleMode: .busy
    )
}
