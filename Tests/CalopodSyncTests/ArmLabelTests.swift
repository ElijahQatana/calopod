import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Arm label")
struct ArmLabelTests {
    @Test("The copy has the source's time and the label, and none of the source's words", arguments: [
        "Client", "", "  ",
    ])
    func copyHasOnlyTheLabel(label: String) throws {
        let source = event(
            "a", title: "synthetic-source title", location: "synthetic-source place",
            notes: "synthetic-source notes",
            attendees: [EventParticipant(name: "Synthetic Person", emailAddress: "person@example.com")])
        let item = try #require(plan(label: label, sources: [source]).items.first)
        let payload = try #require(item.payload)
        #expect(item.action == .create)
        #expect(payload.title == (label == "Client" ? label : "Busy"))
        #expect(payload.startsAt == source.startsAt && payload.endsAt == source.endsAt)
        #expect(payload.location == nil && payload.notes == nil && payload.isPrivate == nil)
        let text = String(describing: payload).lowercased()
        #expect(!text.contains("synthetic-source") && !text.contains("example.com"))
    }

    @Test("A Private event is copied as plain Busy with no label", arguments: [true, false])
    func privateEvent(isPrivate: Bool) throws {
        let payload = try #require(
            plan(label: "Client", sources: [event("a", isPrivate: isPrivate)]).items.first?.payload)
        #expect(payload.title == (isPrivate ? "Busy" : "Client"))
    }

    @Test("Changing the Rule updates the existing copy in place", arguments: [
        (ArmRuleMode.busy, ArmRuleMode.label), (.label, .busy), (.fullDetails, .label), (.label, .fullDetails),
    ])
    func ruleChangeUpdates(from: ArmRuleMode, to: ArmRuleMode) throws {
        let source = event("a")
        let copy = Copy(of: source, rule: from, label: "Client")
        let items = plan(rule: to, label: "Client", sources: [source], copy: copy).items
        #expect(items.map(\.action) == [.update])
        #expect(items.first?.mirrorKey == copy.mapping.mirrorKey)
    }

    @Test("Changing the label updates the copy, and the same label leaves it alone")
    func labelChange() throws {
        let source = event("a")
        let copy = Copy(of: source, rule: .label, label: "Personal")
        #expect(plan(label: "Client", sources: [source], copy: copy).items.map(\.action) == [.update])
        #expect(plan(label: "Personal", sources: [source], copy: copy).items.map(\.action) == [.noOp])
    }

    @Test("The label and Rule persist and can change")
    func persists() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = StoredConnection(
            id: "synthetic-connection", configurationID: "synthetic-configuration",
            provider: "eventkit", displayLabel: "Synthetic provider", isEnabled: true)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(
            connectionID: connection.id,
            bindings: ["synthetic-source", "synthetic-target"].map {
                StoredCalendarBinding(
                    id: $0, connectionID: connection.id, providerCalendarID: "provider-\($0)",
                    displayLabel: $0, isSelected: true, isReadOnly: false)
            })
        let service = ArmConfigurationService(repository: repository)
        #expect(throws: ArmConfigurationError.labelRequired) {
            try service.createArm(
                sourceBindingIDs: ["synthetic-source"], targetBindingID: "synthetic-target",
                ruleMode: .label, label: "  ")
        }
        let arm = try service.createArm(
            id: "synthetic-arm", sourceBindingIDs: ["synthetic-source"],
            targetBindingID: "synthetic-target", ruleMode: .label, label: " Client ")
        #expect(arm.ruleMode == .label && arm.label == "Client")
        #expect(try repository.arm(id: arm.id) == arm)

        let busy = try service.updateRule(armID: arm.id, ruleMode: .busy)
        #expect(busy.ruleMode == .busy && busy.label == "Client")
        #expect(try service.updateRule(armID: arm.id, ruleMode: .label).ruleMode == .label)
        #expect(try service.updateRule(armID: arm.id, ruleMode: .label, label: "Personal").label == "Personal")
        #expect(throws: ArmConfigurationError.invalidLabel) {
            try service.updateRule(armID: arm.id, ruleMode: .label, label: String(repeating: "x", count: 61))
        }
    }
}

private struct Copy {
    let mapping: StoredMirrorMapping
    let observation: TargetEventObservation

    init(of source: StoredNormalizedInstance, rule: ArmRuleMode, label: String) {
        let arm = StoredArm(
            id: "synthetic-arm", configurationID: "config", sourceBindingIDs: ["source"],
            targetBindingID: "target", ruleMode: rule, label: label)
        let mirror = SyncPlanner.mirrorKey(armID: arm.id, sourceKeyHash: source.sourceKeyHash)
        let planned = SyncPlanner.plan(
            arm: arm, sources: [source], mappings: [], targetEvents: [], window: window,
            sourceSnapshotComplete: true)
        let fingerprint = planned.items.first?.desiredFingerprint
        mapping = StoredMirrorMapping(
            mirrorKey: mirror, armID: arm.id, sourceKeyHash: source.sourceKeyHash,
            providerEventID: "copy-id", providerVersion: "v1", desiredFingerprint: fingerprint ?? "",
            ownershipKeyID: "key", updatedAt: Date(timeIntervalSince1970: 0))
        observation = TargetEventObservation(
            calendarBindingID: "target", providerEventID: "copy-id", mirrorKey: mirror,
            contentFingerprint: fingerprint, ownershipStatus: .verified)
    }
}

private let window = try! SyncWindow(
    start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000_000))

private func plan(
    rule: ArmRuleMode = .label, label: String, sources: [StoredNormalizedInstance], copy: Copy? = nil
) -> SyncPlan {
    let arm = StoredArm(
        id: "synthetic-arm", configurationID: "config", sourceBindingIDs: ["source"],
        targetBindingID: "target", ruleMode: rule, label: label)
    return SyncPlanner.plan(
        arm: arm, sources: sources, mappings: copy.map { [$0.mapping] } ?? [],
        targetEvents: copy.map { [$0.observation] } ?? [], window: window, sourceSnapshotComplete: true)
}

private func event(
    _ key: String, title: String? = "Planning", location: String? = nil, notes: String? = nil,
    attendees: [EventParticipant] = [], isPrivate: Bool = false
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-\(key)", connectionID: "connection", calendarBindingID: "source",
        providerEventID: "id-\(key)", recurrenceID: nil, startsAt: Date(timeIntervalSince1970: 2_000),
        endsAt: Date(timeIntervalSince1970: 3_000), isAllDay: false, availability: "busy",
        isCancelled: false, isPrivate: isPrivate, title: title, contentFingerprint: "f-\(key)",
        providerUpdatedAt: nil, location: location, notes: notes, attendees: attendees)
}
