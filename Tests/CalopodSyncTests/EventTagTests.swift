import CalopodDomain
import CalopodStore
import Foundation
import Testing

@testable import CalopodSync

@Suite("Event tags")
struct EventTagTests {
    @Test("A tag is read whole, in any case, from the notes first and then the title", arguments: [
        ("Lunch #dontclone", nil, [.dontClone]), ("Lunch #DontClone", nil, [.dontClone]),
        ("Lunch", "call back\n#justbusy", [.justBusy]), ("(#JUSTBUSY)", "", [.justBusy]),
        ("Lunch #dontclone.", nil, [.dontClone]),
        ("#dontclone", "#justbusy", [.justBusy]),
        (nil, "#dontclone #justbusy", [.dontClone, .justBusy]),
        ("Lunch #dontcloned", nil, []), ("Lunch dontclone", nil, []), ("Lunch #dont-clone", nil, []),
        ("Lunch #dont clone", "x#justbusy", []), ("Lunch ##justbusy", nil, []),
        ("Lunch #justbusy-later", nil, []), (nil, nil, []),
    ] as [(String?, String?, Set<EventTag>)])
    func reads(title: String?, notes: String?, tags: Set<EventTag>) {
        #expect(EventTag.read(event(title: title, notes: notes)) == tags)
    }

    @Test("A Full details copy of a #justbusy event carries no words", arguments: [
        event(title: "Review #justbusy", notes: "agenda", location: "Room 4"),
        event(title: "Review", notes: "agenda\n#JustBusy", location: "Room 4"),
        event(title: "Review #justbusy", isPrivate: true),
    ])
    func busyPayload(source: StoredNormalizedInstance) throws {
        let item = try #require(plan(.fullDetails, [source]).items.first)
        let payload = try #require(item.payload)
        #expect(item.action == .create)
        #expect(payload.title == "Busy")
        #expect(payload.location == nil && payload.notes == nil && payload.isPrivate == nil)
        #expect(payload.startsAt == source.startsAt && payload.endsAt == source.endsAt)
    }

    @Test("Other events and other Rules are copied as before", arguments: [
        (ArmRuleMode.fullDetails, event(title: "Review #justbusyish", location: "Room 4"), "Review #justbusyish"),
        (.busy, event(title: "Review #justbusy"), "Busy"),
        (.label, event(title: "Review #justbusy"), "Client"),
    ])
    func unchanged(rule: ArmRuleMode, source: StoredNormalizedInstance, title: String) throws {
        let item = try #require(plan(rule, [source]).items.first)
        #expect(item.payload?.title == title)
    }

    @Test("Gaining the tag reduces a copy to Busy and losing it brings the details back")
    func gainAndLose() throws {
        let plain = event(title: "Review", location: "Room 4")
        let tagged = event(title: "Review", notes: "#justbusy", location: "Room 4")
        let full = try copy(of: plain)
        let busy = try copy(of: tagged)

        let gained = try #require(plan(.fullDetails, [tagged], copy: full).items.first)
        #expect(gained.action == .update)
        #expect(gained.payload?.location == nil)
        let lost = try #require(plan(.fullDetails, [plain], copy: busy).items.first)
        #expect(lost.action == .update)
        #expect(lost.payload?.location == "Room 4")
        #expect(try plan(.fullDetails, [tagged], copy: busy).items.first?.action == .noOp)
    }
}

private func copy(of source: StoredNormalizedInstance, status: TargetOwnershipStatus = .verified) throws -> Copy {
    let create = try #require(plan(.fullDetails, [source]).items.first)
    let mirror = create.mirrorKey
    return Copy(
        mapping: StoredMirrorMapping(
            mirrorKey: mirror, armID: "arm", sourceKeyHash: source.sourceKeyHash, providerEventID: "copy-id",
            providerVersion: "v1", desiredFingerprint: create.desiredFingerprint ?? "", ownershipKeyID: "key",
            updatedAt: Date(timeIntervalSince1970: 0)),
        observation: TargetEventObservation(
            calendarBindingID: "target", providerEventID: "copy-id", mirrorKey: mirror,
            contentFingerprint: create.desiredFingerprint, ownershipStatus: status))
}

private struct Copy {
    let mapping: StoredMirrorMapping
    let observation: TargetEventObservation
}

private func plan(
    _ rule: ArmRuleMode, _ sources: [StoredNormalizedInstance], copy: Copy? = nil, filters: ArmFilters = ArmFilters()
) -> SyncPlan {
    let arm = StoredArm(
        id: "arm", configurationID: "config", sourceBindingIDs: ["source"], targetBindingID: "target",
        ruleMode: rule, filters: filters, label: "Client")
    return SyncPlanner.plan(
        arm: arm, sources: sources, mappings: copy.map { [$0.mapping] } ?? [],
        targetEvents: copy.map { [$0.observation] } ?? [],
        window: try! SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000_000)),
        sourceSnapshotComplete: true)
}

private func event(
    title: String? = "Review", notes: String? = nil, location: String? = nil, isPrivate: Bool = false,
    response: EventResponseState = .notApplicable
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-a", connectionID: "connection", calendarBindingID: "source", providerEventID: "id-a", recurrenceID: nil,
        startsAt: Date(timeIntervalSince1970: 2_000), endsAt: Date(timeIntervalSince1970: 3_000), isAllDay: false,
        availability: "busy", isCancelled: false, isPrivate: isPrivate, title: title, contentFingerprint: "f-a",
        providerUpdatedAt: nil, location: location, notes: notes, currentUserResponse: EventResponse(state: response))
}
