import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Private events")
struct PrivateEventTests {
    @Test("Only a Full details Arm with the setting on keeps the words of a private event", arguments: [
        (ArmRuleMode.busy, true, false, "Busy", nil),
        (.busy, true, true, "Busy", nil),
        (.label, true, false, "Busy", nil),
        (.label, true, true, "Busy", nil),
        (.label, false, false, "Client", nil),
        (.fullDetails, true, false, "Busy", nil),
        (.fullDetails, true, true, "Review", "Room 4"),
        (.fullDetails, false, false, "Review", "Room 4"),
        (.fullDetails, false, true, "Review", "Room 4"),
    ] as [(ArmRuleMode, Bool, Bool, String, String?)])
    func words(rule: ArmRuleMode, isPrivate: Bool, include: Bool, title: String, location: String?) throws {
        let item = try #require(plan(rule, include, [event(isPrivate: isPrivate)]).items.first)
        #expect(item.payload?.title == title)
        #expect(item.payload?.location == location)
        #expect(item.reason == (rule == .fullDetails && isPrivate && !include ? .privateEvent : .targetMissing))
    }

    @Test("A copy follows the setting on the next sync")
    func settingChanges() throws {
        let source = event(isPrivate: true)
        let full = try copy(of: source, include: true)
        let hidden = try #require(plan(.fullDetails, false, [source], copy: full).items.first)
        #expect(hidden.action == .update && hidden.reason == .privateEvent)
        #expect(hidden.payload?.location == nil)
        let busy = try copy(of: source, include: false)
        #expect(try plan(.fullDetails, false, [source], copy: busy).items.first?.action == .noOp)
        let shown = try #require(plan(.fullDetails, true, [source], copy: busy).items.first)
        #expect(shown.action == .update && shown.reason == .targetDiffers)
        #expect(shown.payload?.location == "Room 4")
    }

    @Test("A hidden copy is read back with the private flag off", arguments: [
        (ProviderKind.google, false as Bool?), (.microsoft, false), (.eventKit, nil),
    ])
    func flagOnTarget(target: ProviderKind, isPrivate: Bool?) throws {
        let arm = StoredArm(id: "arm", configurationID: "config", sourceBindingIDs: ["source"], targetBindingID: "target", ruleMode: .fullDetails)
        let item = try #require(SyncPlanner.plan(
            arm: arm, targetProvider: target, sources: [event(isPrivate: true)], mappings: [], targetEvents: [],
            window: try SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000_000)),
            sourceSnapshotComplete: true).items.first)
        #expect(item.payload?.isPrivate == isPrivate)
    }
}

private struct Copy {
    let mapping: StoredMirrorMapping
    let observation: TargetEventObservation
}

private func copy(of source: StoredNormalizedInstance, include: Bool) throws -> Copy {
    let create = try #require(plan(.fullDetails, include, [source]).items.first)
    return Copy(
        mapping: StoredMirrorMapping(
            mirrorKey: create.mirrorKey, armID: "arm", sourceKeyHash: source.sourceKeyHash, providerEventID: "copy-id",
            providerVersion: "v1", desiredFingerprint: create.desiredFingerprint ?? "", ownershipKeyID: "key",
            updatedAt: Date(timeIntervalSince1970: 0)),
        observation: TargetEventObservation(
            calendarBindingID: "target", providerEventID: "copy-id", mirrorKey: create.mirrorKey,
            contentFingerprint: create.desiredFingerprint, ownershipStatus: .verified))
}

private func plan(
    _ rule: ArmRuleMode, _ include: Bool, _ sources: [StoredNormalizedInstance], copy: Copy? = nil
) -> SyncPlan {
    let arm = StoredArm(
        id: "arm", configurationID: "config", sourceBindingIDs: ["source"], targetBindingID: "target",
        ruleMode: rule, label: "Client", includePrivate: include)
    return SyncPlanner.plan(
        arm: arm, sources: sources, mappings: copy.map { [$0.mapping] } ?? [],
        targetEvents: copy.map { [$0.observation] } ?? [],
        window: try! SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000_000)),
        sourceSnapshotComplete: true)
}

private func event(isPrivate: Bool) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-a", connectionID: "connection", calendarBindingID: "source", providerEventID: "id-a", recurrenceID: nil,
        startsAt: Date(timeIntervalSince1970: 2_000), endsAt: Date(timeIntervalSince1970: 3_000), isAllDay: false,
        availability: "busy", isCancelled: false, isPrivate: isPrivate, title: "Review", contentFingerprint: "f-a",
        providerUpdatedAt: nil, location: "Room 4")
}
