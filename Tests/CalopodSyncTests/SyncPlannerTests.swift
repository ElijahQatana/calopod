import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Deterministic sync planning")
struct SyncPlannerTests {
    @Test("Busy plans are stable and contain no protected detail")
    func busyRedaction() throws {
        let source = instance(id: "source-one", title: "Synthetic confidential session", isPrivate: true)
        let arm = storedArm(ruleMode: .busy)
        let first = SyncPlanner.plan(
            arm: arm,
            sources: [source],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )
        let second = SyncPlanner.plan(
            arm: arm,
            sources: [source],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )
        let item = try #require(first.items.first)
        let encoded = try JSONEncoder().encode(first)
        let text = try #require(String(data: encoded, encoding: .utf8))

        #expect(first == second)
        #expect(item.action == .create)
        #expect(item.reason == .targetMissing)
        #expect(item.payload?.title == "Busy")
        #expect(item.payload?.isPrivate == nil)
        #expect(item.mirrorKey.count == 52)
        #expect(item.mirrorKey.allSatisfy { $0.isLowercase || $0.isNumber })
        #expect(!text.contains("Synthetic confidential session"))
    }

    @Test("Full details plans retain supported source detail")
    func fullDetails() throws {
        let source = instance(id: "source-one", title: "Synthetic planning session", isPrivate: true)
        let plan = SyncPlanner.plan(
            arm: storedArm(ruleMode: .fullDetails),
            sources: [source],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )

        #expect(plan.items.first?.payload?.title == "Synthetic planning session")
        #expect(plan.items.first?.payload?.isPrivate == true)
    }

    @Test("Calculates creates, updates, removals, repairs, and no-ops")
    func everyAction() throws {
        let arm = storedArm(ruleMode: .busy)
        let sources = [
            instance(id: "create"),
            instance(id: "update"),
            instance(id: "no-op"),
            instance(id: "duplicate"),
        ]
        let initial = SyncPlanner.plan(
            arm: arm,
            sources: sources,
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )
        let desired = Dictionary(
            uniqueKeysWithValues: initial.items.compactMap { item in
                item.sourceKeyHash.map { ($0, item) }
            }
        )
        let removalMirror = SyncPlanner.mirrorKey(
            armID: arm.id,
            sourceKeyHash: "source-removed"
        )
        let mappedSourceIDs = ["source-update", "source-no-op", "source-duplicate"]
        var mappings = mappedSourceIDs.map { sourceID in
            StoredMirrorMapping(
                mirrorKey: desired[sourceID]!.mirrorKey,
                armID: arm.id,
                sourceKeyHash: sourceID,
                providerEventID: "provider-\(sourceID)",
                providerVersion: "v1",
                desiredFingerprint: "previous",
                ownershipKeyID: "synthetic-key",
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        }
        mappings.append(
            StoredMirrorMapping(
                mirrorKey: removalMirror,
                armID: arm.id,
                sourceKeyHash: "source-removed",
                providerEventID: "provider-removed",
                providerVersion: "v1",
                desiredFingerprint: "previous",
                ownershipKeyID: "synthetic-key",
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        )
        let observations = [
            observation(
                sourceID: "source-update",
                desired: desired,
                fingerprint: "outdated"
            ),
            observation(
                sourceID: "source-no-op",
                desired: desired,
                fingerprint: desired["source-no-op"]!.desiredFingerprint
            ),
            observation(
                sourceID: "source-duplicate",
                desired: desired,
                fingerprint: "outdated",
                suffix: "one"
            ),
            observation(
                sourceID: "source-duplicate",
                desired: desired,
                fingerprint: "outdated",
                suffix: "two"
            ),
            TargetEventObservation(
                calendarBindingID: arm.targetBindingID,
                providerEventID: "provider-removed",
                mirrorKey: removalMirror,
                contentFingerprint: "previous",
                ownershipStatus: .verified
            ),
            TargetEventObservation(
                calendarBindingID: arm.targetBindingID,
                providerEventID: "unmanaged-target",
                mirrorKey: nil,
                contentFingerprint: nil,
                ownershipStatus: .unmanaged
            ),
        ]

        let plan = SyncPlanner.plan(
            arm: arm,
            sources: sources.reversed(),
            mappings: mappings.reversed(),
            targetEvents: observations.reversed(),
            window: try window(),
            sourceSnapshotComplete: true
        )

        #expect(plan.items.map(\.action).filter { $0 == .create }.count == 1)
        #expect(plan.items.map(\.action).filter { $0 == .update }.count == 1)
        #expect(plan.items.map(\.action).filter { $0 == .remove }.count == 1)
        #expect(plan.items.map(\.action).filter { $0 == .repair }.count == 1)
        #expect(plan.items.map(\.action).filter { $0 == .noOp }.count == 1)
        #expect(plan.items.contains { $0.reason == .verifiedDuplicates })
        #expect(!plan.items.contains { $0.id == "unmanaged-target" })
    }

    @Test("Unverified ownership and incomplete sources never propose mutations")
    func uncertainState() throws {
        let arm = storedArm(ruleMode: .busy)
        let source = instance(id: "uncertain")
        let mirror = SyncPlanner.mirrorKey(armID: arm.id, sourceKeyHash: source.sourceKeyHash)
        let mapping = StoredMirrorMapping(
            mirrorKey: mirror,
            armID: arm.id,
            sourceKeyHash: source.sourceKeyHash,
            providerEventID: "provider-uncertain",
            providerVersion: "v1",
            desiredFingerprint: "previous",
            ownershipKeyID: "synthetic-key",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let missingMarker = TargetEventObservation(
            calendarBindingID: arm.targetBindingID,
            providerEventID: mapping.providerEventID,
            mirrorKey: mirror,
            contentFingerprint: "previous",
            ownershipStatus: .missingMarker
        )

        let desiredPlan = SyncPlanner.plan(
            arm: arm,
            sources: [source],
            mappings: [mapping],
            targetEvents: [missingMarker],
            window: try window(),
            sourceSnapshotComplete: true
        )
        let incompletePlan = SyncPlanner.plan(
            arm: arm,
            sources: [],
            mappings: [mapping],
            targetEvents: [
                TargetEventObservation(
                    calendarBindingID: arm.targetBindingID,
                    providerEventID: mapping.providerEventID,
                    mirrorKey: mirror,
                    contentFingerprint: "previous",
                    ownershipStatus: .verified
                ),
            ],
            window: try window(),
            sourceSnapshotComplete: false
        )

        #expect(desiredPlan.items.map(\.action) == [.repair])
        #expect(desiredPlan.items.map(\.reason) == [.ownershipUnverified])
        #expect(incompletePlan.items.map(\.action) == [.repair])
        #expect(incompletePlan.items.map(\.reason) == [.sourceSnapshotIncomplete])
    }
}

private func storedArm(ruleMode: ArmRuleMode) -> StoredArm {
    StoredArm(
        id: "arm-one",
        configurationID: "synthetic-configuration",
        sourceBindingIDs: ["source-calendar"],
        targetBindingID: "target-calendar",
        ruleMode: ruleMode
    )
}

private func window() throws -> SyncWindow {
    try SyncWindow(
        start: Date(timeIntervalSince1970: 1_000),
        end: Date(timeIntervalSince1970: 10_000)
    )
}

private func instance(
    id: String,
    title: String? = "Synthetic event",
    isPrivate: Bool = false
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "source-\(id)",
        connectionID: "source-connection",
        calendarBindingID: "source-calendar",
        providerEventID: "provider-\(id)",
        recurrenceID: nil,
        startsAt: Date(timeIntervalSince1970: 2_000),
        endsAt: Date(timeIntervalSince1970: 3_000),
        isAllDay: false,
        availability: "busy",
        isCancelled: false,
        isPrivate: isPrivate,
        title: title,
        contentFingerprint: "source-fingerprint-\(id)",
        providerUpdatedAt: nil
    )
}

private func observation(
    sourceID: String,
    desired: [String: SyncPlanItem],
    fingerprint: String?,
    suffix: String? = nil
) -> TargetEventObservation {
    TargetEventObservation(
        calendarBindingID: "target-calendar",
        providerEventID: "provider-\(sourceID)\(suffix.map { "-\($0)" } ?? "")",
        mirrorKey: desired[sourceID]!.mirrorKey,
        contentFingerprint: fingerprint,
        ownershipStatus: .verified
    )
}
