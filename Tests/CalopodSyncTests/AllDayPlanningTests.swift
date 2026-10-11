import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("All-day planning across time zones")
struct AllDayPlanningTests {
    @Test("A mirror read back in another zone matches until its day changes")
    func readBackInTargetZone() throws {
        let arm = StoredArm(
            id: "arm-one", configurationID: "synthetic-configuration",
            sourceBindingIDs: ["source-calendar"], targetBindingID: "target-calendar",
            ruleMode: .busy, isMain: false
        )
        let source = allDayInstance(zone: "Asia/Tokyo", day: (2026, 10, 5))
        let first = try plan(arm, source, observed: nil)
        let item = try #require(first.items.first)
        #expect(item.action == .create)
        #expect(item.payload?.timeZoneIdentifier == "Asia/Tokyo")

        let sameDay = try plan(arm, source, observed: readBack(zone: "America/Los_Angeles", day: (2026, 10, 5), item: item))
        #expect(sameDay.items.map(\.action) == [.noOp])

        let earlierDay = try plan(arm, source, observed: readBack(zone: "America/Los_Angeles", day: (2026, 10, 4), item: item))
        #expect(earlierDay.items.map(\.action) == [.update])
    }

    @Test("Timed events keep their fingerprint")
    func timedFingerprint() {
        let payload = DesiredEventPayload(
            startsAt: Date(timeIntervalSince1970: 2_000), endsAt: Date(timeIntervalSince1970: 3_000),
            isAllDay: false, availability: "busy", title: "Busy", isPrivate: nil
        )
        let zoned = DesiredEventPayload(
            startsAt: payload.startsAt, endsAt: payload.endsAt, isAllDay: false,
            availability: "busy", title: "Busy", isPrivate: nil, timeZoneIdentifier: "Asia/Tokyo"
        )
        #expect(SyncPlanner.desiredFingerprint(payload: payload, ruleMode: .busy)
            == SyncPlanner.desiredFingerprint(payload: zoned, ruleMode: .busy))
    }
}

private func plan(
    _ arm: StoredArm, _ source: StoredNormalizedInstance, observed: (DesiredEventPayload, String)?
) throws -> SyncPlan {
    let window = try SyncWindow(
        start: Date(timeIntervalSince1970: 1_790_000_000), end: Date(timeIntervalSince1970: 1_800_000_000)
    )
    var mappings: [StoredMirrorMapping] = []
    var targets: [TargetEventObservation] = []
    if let (payload, mirrorKey) = observed {
        mappings = [StoredMirrorMapping(
            mirrorKey: mirrorKey, armID: arm.id, sourceKeyHash: source.sourceKeyHash,
            providerEventID: "provider-target", providerVersion: "v1", desiredFingerprint: "previous",
            ownershipKeyID: "synthetic-key", updatedAt: Date(timeIntervalSince1970: 1)
        )]
        targets = [TargetEventObservation(
            calendarBindingID: arm.targetBindingID, providerEventID: "provider-target", mirrorKey: mirrorKey,
            contentFingerprint: SyncPlanner.desiredFingerprint(payload: payload, ruleMode: .busy),
            ownershipStatus: .verified
        )]
    }
    return SyncPlanner.plan(
        arm: arm, sources: [source], mappings: mappings, targetEvents: targets,
        window: window, sourceSnapshotComplete: true
    )
}

private func readBack(zone: String, day: (Int, Int, Int), item: SyncPlanItem) -> (DesiredEventPayload, String) {
    let (start, end) = midnights(zone: zone, day: day)
    return (
        DesiredEventPayload(
            startsAt: start, endsAt: end, isAllDay: true, availability: "busy",
            title: "Busy", isPrivate: nil, timeZoneIdentifier: zone
        ),
        item.mirrorKey
    )
}

private func allDayInstance(zone: String, day: (Int, Int, Int)) -> StoredNormalizedInstance {
    let (start, end) = midnights(zone: zone, day: day)
    return StoredNormalizedInstance(
        sourceKeyHash: "source-one", connectionID: "source-connection", calendarBindingID: "source-calendar",
        providerEventID: "provider-one", recurrenceID: nil, startsAt: start, endsAt: end, isAllDay: true,
        availability: "busy", isCancelled: false, isPrivate: false, title: "Synthetic event",
        contentFingerprint: "source-fingerprint", providerUpdatedAt: nil, timeZoneIdentifier: zone
    )
}

private func midnights(zone: String, day: (Int, Int, Int)) -> (Date, Date) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    let start = calendar.date(from: DateComponents(year: day.0, month: day.1, day: day.2))!
    return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
}
