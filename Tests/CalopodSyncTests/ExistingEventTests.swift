import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Events already on the target")
struct ExistingEventTests {
    private func plan(
        sources: [StoredNormalizedInstance],
        targetOriginals: [StoredNormalizedInstance],
        mappings: [StoredMirrorMapping] = [],
        targetEvents: [TargetEventObservation] = []
    ) throws -> SyncPlan {
        let window = try SyncWindow(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 1_000_000)
        )
        return SyncPlanner.plan(
            arm: arm,
            sources: sources,
            mappings: mappings,
            targetEvents: targetEvents,
            window: window,
            sourceSnapshotComplete: true,
            targetOriginals: targetOriginals
        )
    }

    private func actions(
        sources: [StoredNormalizedInstance],
        targetOriginals: [StoredNormalizedInstance]
    ) throws -> [SyncPlanAction] {
        try plan(sources: sources, targetOriginals: targetOriginals).items.map(\.action)
    }

    @Test("A timed event already on the target is not copied")
    func timed() throws {
        #expect(try actions(sources: [event("a")], targetOriginals: [event("b")]) == [.noOp])
    }

    @Test("An all-day event already on the target is not copied, even across zones")
    func allDay() throws {
        let tokyo = event(
            "a", start: 86_400 * 10 - 32_400, end: 86_400 * 11 - 32_400, allDay: true, zone: "Asia/Tokyo"
        )
        let utc = event("b", start: 86_400 * 10, end: 86_400 * 11, allDay: true, zone: "UTC")
        #expect(try actions(sources: [tokyo], targetOriginals: [utc]) == [.noOp])
    }

    @Test("Look-alikes still get a copy", arguments: [
        event("b", title: "Other"), event("b", start: 2_100), event("b", end: 3_100), event("b", title: nil),
        event("b", start: 0, end: 86_400, allDay: true, zone: "UTC"),
    ])
    func different(other: StoredNormalizedInstance) throws {
        #expect(try actions(sources: [event("a")], targetOriginals: [other]) == [.create])
    }

    @Test("An all-day event on another day still gets a copy")
    func otherDay() throws {
        let day = event("a", start: 86_400 * 10, end: 86_400 * 11, allDay: true, zone: "UTC")
        let next = event("b", start: 86_400 * 11, end: 86_400 * 12, allDay: true, zone: "UTC")
        #expect(try actions(sources: [day], targetOriginals: [next]) == [.create])
    }

    @Test("The same server UID matches even when titles differ")
    func externalID() throws {
        let source = event("a", title: "Source title", externalID: "uid-shared")
        let target = event("b", title: "Target title", externalID: "uid-shared")
        #expect(try actions(sources: [source], targetOriginals: [target]) == [.noOp])
    }

    @Test("Title and time still match when server UIDs differ")
    func titleTimeDespiteDifferentUID() throws {
        let source = event("a", externalID: "uid-a")
        let target = event("b", externalID: "uid-b")
        #expect(try actions(sources: [source], targetOriginals: [target]) == [.noOp])
    }

    @Test("Without target originals the source is still copied")
    func unreadTarget() throws {
        #expect(try actions(sources: [event("a")], targetOriginals: []) == [.create])
    }

    @Test("A declined event on the target does not stand in for the source")
    func declinedOriginal() throws {
        let declined = event("b", response: .declined)
        #expect(try actions(sources: [event("a")], targetOriginals: [declined]) == [.create])
    }

    @Test("A verified copy is removed when the target already holds the original", arguments: [
        (EventResponseState.needsResponse, SyncPlanAction.remove, SyncPlanReason.targetHasOriginal),
        (EventResponseState.declined, SyncPlanAction.noOp, SyncPlanReason.targetMatches),
    ])
    func removesExistingCopy(
        response: EventResponseState, action: SyncPlanAction, reason: SyncPlanReason
    ) throws {
        let source = event("a")
        let original = event("b", response: response)
        let mirror = SyncPlanner.mirrorKey(armID: arm.id, sourceKeyHash: source.sourceKeyHash)
        let payload = DesiredEventPayload(
            startsAt: source.startsAt,
            endsAt: source.endsAt,
            isAllDay: false,
            availability: "busy",
            title: source.title,
            isPrivate: false
        )
        let fingerprint = SyncPlanner.desiredFingerprint(payload: payload, ruleMode: .fullDetails)
        let mapping = StoredMirrorMapping(
            mirrorKey: mirror,
            armID: arm.id,
            sourceKeyHash: source.sourceKeyHash,
            providerEventID: "copy-id",
            providerVersion: "v1",
            desiredFingerprint: fingerprint,
            ownershipKeyID: "key",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let observation = TargetEventObservation(
            calendarBindingID: arm.targetBindingID,
            providerEventID: "copy-id",
            mirrorKey: mirror,
            contentFingerprint: fingerprint,
            ownershipStatus: .verified
        )
        let result = try plan(
            sources: [source],
            targetOriginals: [original],
            mappings: [mapping],
            targetEvents: [observation]
        )
        let item = try #require(result.items.first)
        #expect(item.action == action)
        #expect(item.reason == reason)
    }
}

private let arm = StoredArm(
    id: "arm", configurationID: "config", sourceBindingIDs: ["a"], targetBindingID: "b",
    ruleMode: .fullDetails, isMain: false)

private func event(
    _ calendar: String, title: String? = "Planning", start: TimeInterval = 2_000, end: TimeInterval = 3_000,
    allDay: Bool = false, zone: String? = nil, externalID: String? = nil,
    response: EventResponseState = .notApplicable
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-\(calendar)", connectionID: "c-\(calendar)", calendarBindingID: calendar,
        providerEventID: "id-\(calendar)", recurrenceID: nil, startsAt: Date(timeIntervalSince1970: start),
        endsAt: Date(timeIntervalSince1970: end), isAllDay: allDay, availability: "busy", isCancelled: false,
        isPrivate: false, title: title, contentFingerprint: "f-\(calendar)", providerUpdatedAt: nil,
        currentUserResponse: EventResponse(state: response),
        timeZoneIdentifier: zone, providerExternalID: externalID)
}
