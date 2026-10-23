import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Events already on the target")
struct ExistingEventTests {
    private func actions(_ events: [StoredNormalizedInstance]) throws -> [SyncPlanAction] {
        let window = try SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000_000))
        return SyncPlanner.plan(
            arm: arm, sources: events, mappings: [], targetEvents: [], window: window, sourceSnapshotComplete: true
        ).items.map(\.action)
    }

    @Test("A timed event already on the target is not copied")
    func timed() throws {
        #expect(try actions([event("a"), event("b")]) == [.noOp])
    }

    @Test("An all-day event already on the target is not copied, even across zones")
    func allDay() throws {
        let tokyo = event("a", start: 86_400 * 10 - 32_400, end: 86_400 * 11 - 32_400, allDay: true, zone: "Asia/Tokyo")
        let utc = event("b", start: 86_400 * 10, end: 86_400 * 11, allDay: true, zone: "UTC")
        #expect(try actions([tokyo, utc]) == [.noOp])
    }

    @Test("Look-alikes still get a copy", arguments: [
        event("b", title: "Other"), event("b", start: 2_100), event("b", end: 3_100), event("b", title: nil),
        event("b", start: 0, end: 86_400, allDay: true, zone: "UTC"),
    ])
    func different(other: StoredNormalizedInstance) throws {
        #expect(try actions([event("a"), other]) == [.create])
    }

    @Test("An all-day event on another day still gets a copy")
    func otherDay() throws {
        let day = event("a", start: 86_400 * 10, end: 86_400 * 11, allDay: true, zone: "UTC")
        let next = event("b", start: 86_400 * 11, end: 86_400 * 12, allDay: true, zone: "UTC")
        #expect(try actions([day, next]) == [.create])
    }
}

private let arm = StoredArm(
    id: "arm", configurationID: "config", sourceBindingIDs: ["a"], targetBindingID: "b",
    ruleMode: .fullDetails, isMain: false)

private func event(
    _ calendar: String, title: String? = "Planning", start: TimeInterval = 2_000, end: TimeInterval = 3_000,
    allDay: Bool = false, zone: String? = nil
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-\(calendar)", connectionID: "c-\(calendar)", calendarBindingID: calendar,
        providerEventID: "id-\(calendar)", recurrenceID: nil, startsAt: Date(timeIntervalSince1970: start),
        endsAt: Date(timeIntervalSince1970: end), isAllDay: allDay, availability: "busy", isCancelled: false,
        isPrivate: false, title: title, contentFingerprint: "f-\(calendar)", providerUpdatedAt: nil,
        timeZoneIdentifier: zone)
}
