import CalopodDomain
import CalopodStore
import Foundation
import Testing

@testable import CalopodSync

@Suite("Skipped events")
struct SkippedEventPlanTests {
    @Test("A skip leaves out one event, a series or one occurrence, and undoing it copies them again", arguments: [
        (event("a"), false, ["key-b", "key-s1", "key-s2"]),
        (event("s1", series: "weekly"), true, ["key-a", "key-b"]),
        (event("s1", series: "weekly"), false, ["key-a", "key-b", "key-s2"]),
        (nil, false, ["key-a", "key-b", "key-s1", "key-s2"]),
    ] as [(StoredNormalizedInstance?, Bool, [String])])
    func copied(skipped: StoredNormalizedInstance?, series: Bool, copied: [String]) {
        let skips = skipped.map { [EventSkip($0, wholeSeries: series, isEventKit: false)] } ?? []
        let items = plan(skips: skips).items
        #expect(Set(items.compactMap(\.sourceKeyHash)) == Set(copied))
        #expect(items.allSatisfy { $0.action == .create })
    }

    @Test("A copy is removed for a skip only when Calopod can prove it made it", arguments: [
        (TargetOwnershipStatus.verified, SyncPlanAction.remove, SyncPlanReason.skipped),
        (.missingMarker, .repair, .ownershipUnverified),
        (.wrongTarget, .repair, .ownershipUnverified),
    ])
    func removal(status: TargetOwnershipStatus, action: SyncPlanAction, reason: SyncPlanReason) throws {
        let source = event("a")
        let made = try #require(plan(sources: [source]).items.first)
        let copy = (
            StoredMirrorMapping(
                mirrorKey: made.mirrorKey, armID: "arm", sourceKeyHash: source.sourceKeyHash, providerEventID: "copy-id",
                providerVersion: "v1", desiredFingerprint: made.desiredFingerprint ?? "", ownershipKeyID: "key",
                updatedAt: Date(timeIntervalSince1970: 0)),
            TargetEventObservation(
                calendarBindingID: "target", providerEventID: "copy-id", mirrorKey: made.mirrorKey,
                contentFingerprint: made.desiredFingerprint, ownershipStatus: status))
        let skips = [EventSkip(source, wholeSeries: false, isEventKit: false)]
        let item = try #require(plan(sources: [source], skips: skips, copy: copy).items.first)
        #expect(item.action == action && item.reason == reason)
    }
}

private func plan(
    sources: [StoredNormalizedInstance]? = nil, skips: [EventSkip] = [],
    copy: (StoredMirrorMapping, TargetEventObservation)? = nil
) -> SyncPlan {
    let arm = StoredArm(
        id: "arm", configurationID: "config", sourceBindingIDs: ["source"], targetBindingID: "target", ruleMode: .busy)
    return SyncPlanner.plan(
        arm: arm,
        sources: sources ?? [event("a"), event("b"), event("s1", series: "weekly"), event("s2", series: "weekly")],
        mappings: copy.map { [$0.0] } ?? [], targetEvents: copy.map { [$0.1] } ?? [],
        window: try! SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000_000)),
        sourceSnapshotComplete: true, skips: skips)
}

private func event(_ key: String, series: String? = nil) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-\(key)", connectionID: "connection", calendarBindingID: "source", providerEventID: "id-\(key)",
        recurrenceID: series.map { _ in "occurrence-\(key)" }, startsAt: Date(timeIntervalSince1970: 2_000),
        endsAt: Date(timeIntervalSince1970: 3_000), isAllDay: false, availability: "busy", isCancelled: false,
        isPrivate: false, title: "Review", contentFingerprint: "f-\(key)", providerUpdatedAt: nil, providerSeriesID: series)
}
