import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Deterministic sync planning")
struct SyncPlannerTests {
    @Test("Busy plans are stable and contain no protected detail")
    func busyRedaction() throws {
        let source = instance(
            id: "source-one",
            title: "Synthetic confidential session",
            isPrivate: true,
            location: "Synthetic private room",
            notes: "Synthetic private agenda",
            url: "https://calendar.example.test/private",
            organizer: EventParticipant(name: "Synthetic Organizer", emailAddress: "private@example.com"),
            attendees: [EventParticipant(name: "Synthetic Attendee", status: "accepted")]
        )
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
        #expect(item.payload?.location == nil)
        #expect(item.payload?.notes == nil)
        #expect(item.mirrorKey.count == 52)
        #expect(item.mirrorKey.allSatisfy { $0.isLowercase || $0.isNumber })
        #expect(!text.contains("Synthetic confidential session"))
        #expect(!text.contains("Synthetic private room"))
        #expect(!text.contains("Synthetic private agenda"))
        #expect(!text.contains("calendar.example.test"))
        #expect(!text.contains("private@example.com"))
        #expect(!text.contains("Synthetic Attendee"))
    }

    @Test("Main calendar plans retain supported source detail")
    func mainCalendarDetails() throws {
        let source = instance(
            id: "source-one",
            title: "Synthetic planning session",
            isPrivate: true,
            location: "Synthetic room",
            notes: "Synthetic agenda",
            url: "https://calendar.example.test/events/planning",
            organizer: EventParticipant(
                name: "Synthetic Organizer",
                emailAddress: "organizer@example.com"
            ),
            attendees: [
                EventParticipant(
                    name: "Synthetic Guest",
                    emailAddress: "guest@example.com",
                    status: "accepted"
                ),
            ]
        )
        let plan = SyncPlanner.plan(
            arm: storedArm(ruleMode: .fullDetails, isMain: true),
            sources: [source],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )

        #expect(plan.items.first?.payload?.title == "Synthetic planning session")
        #expect(plan.items.first?.payload?.isPrivate == true)
        #expect(plan.items.first?.payload?.location == "Synthetic room")
        #expect(
            plan.items.first?.payload?.notes
                == """
                Synthetic agenda

                Link: https://calendar.example.test/events/planning

                Organizer: Synthetic Organizer <organizer@example.com>

                Attendees:
                - Synthetic Guest <guest@example.com> (accepted)
                """
        )

        let changed = instance(
            id: "source-one",
            title: "Synthetic planning session",
            isPrivate: true,
            location: "Different synthetic room"
        )
        let changedPlan = SyncPlanner.plan(
            arm: storedArm(ruleMode: .fullDetails, isMain: true),
            sources: [changed],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )
        #expect(plan.items.first?.desiredFingerprint != changedPlan.items.first?.desiredFingerprint)
    }

    @Test("Main calendar notes stay readable without repeated context")
    func cleanMainCalendarNotes() throws {
        let link = "https://meet.example.com/synthetic-room"
        let source = instance(
            id: "source-one",
            notes: "\r\nSynthetic agenda  \r\n\r\n\r\nJoin: \(link)\r\n  - keep indentation  \r\n",
            url: link,
            organizer: EventParticipant(
                name: "Synthetic Organizer",
                emailAddress: "organizer@example.com"
            ),
            attendees: [
                EventParticipant(
                    name: "Synthetic Organizer",
                    emailAddress: "ORGANIZER@example.com",
                    status: "accepted"
                ),
                EventParticipant(
                    name: "Synthetic Guest",
                    emailAddress: "guest@example.com",
                    status: "notResponded"
                ),
                EventParticipant(status: "accepted"),
            ]
        )
        let plan = SyncPlanner.plan(
            arm: storedArm(ruleMode: .fullDetails, isMain: true),
            sources: [source],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )

        #expect(
            plan.items.first?.payload?.notes
                == """
                Synthetic agenda

                Join: https://meet.example.com/synthetic-room
                  - keep indentation

                Organizer: Synthetic Organizer <organizer@example.com>

                Attendees:
                - Synthetic Guest <guest@example.com> (no response)
                """
        )
    }

    @Test("Full details omit privacy when the target cannot write it")
    func targetPrivacyCapabilities() throws {
        let source = instance(id: "source-one", isPrivate: true)
        let arm = storedArm(ruleMode: .fullDetails, isMain: true)

        let eventKit = SyncPlanner.plan(
            arm: arm,
            targetProvider: .eventKit,
            sources: [source],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )
        let google = SyncPlanner.plan(
            arm: arm,
            targetProvider: .google,
            sources: [source],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true
        )

        #expect(eventKit.items.first?.payload?.isPrivate == nil)
        #expect(google.items.first?.payload?.isPrivate == true)
        #expect(
            eventKit.items.first?.desiredFingerprint
                != google.items.first?.desiredFingerprint
        )
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

    @Test("A missing target is recoverable only after a complete target read")
    func missingTargetRequiresCompleteRead() throws {
        let arm = storedArm(ruleMode: .busy)
        let source = instance(id: "missing-target")
        let desired = try #require(
            SyncPlanner.plan(
                arm: arm,
                sources: [source],
                mappings: [],
                targetEvents: [],
                window: try window(),
                sourceSnapshotComplete: true
            ).items.first
        )
        let mapping = StoredMirrorMapping(
            mirrorKey: desired.mirrorKey,
            armID: arm.id,
            sourceKeyHash: source.sourceKeyHash,
            providerEventID: "provider-missing",
            providerVersion: "v1",
            desiredFingerprint: desired.desiredFingerprint!,
            ownershipKeyID: "synthetic-key",
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        let complete = SyncPlanner.plan(
            arm: arm,
            sources: [source],
            mappings: [mapping],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true,
            targetSnapshotComplete: true
        )
        let incomplete = SyncPlanner.plan(
            arm: arm,
            sources: [source],
            mappings: [mapping],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true,
            targetSnapshotComplete: false
        )

        #expect(complete.items.map(\.reason) == [.targetMissing])
        #expect(incomplete.items.map(\.reason) == [.targetSnapshotIncomplete])
    }

    @Test(arguments: [true, false], [true, false])
    func unseenMappingsAreDeferred(sourceComplete: Bool, targetComplete: Bool) throws {
        let arm = storedArm(ruleMode: .busy)
        let mapping = StoredMirrorMapping(
            mirrorKey: "unseen-mirror", armID: arm.id, sourceKeyHash: "unseen-source",
            providerEventID: "unseen-target", providerVersion: "v1", desiredFingerprint: "previous",
            ownershipKeyID: "synthetic-key", updatedAt: Date(timeIntervalSince1970: 1)
        )
        let plan = SyncPlanner.plan(
            arm: arm, sources: [], mappings: [mapping], targetEvents: [], window: try window(),
            sourceSnapshotComplete: sourceComplete, targetSnapshotComplete: targetComplete
        )
        #expect(plan.items.isEmpty)
    }

    @Test("An incomplete target read cannot create an unmapped event")
    func incompleteTargetReadCannotCreate() throws {
        let plan = SyncPlanner.plan(
            arm: storedArm(ruleMode: .busy),
            sources: [instance(id: "unmapped-incomplete-target")],
            mappings: [],
            targetEvents: [],
            window: try window(),
            sourceSnapshotComplete: true,
            targetSnapshotComplete: false
        )

        #expect(plan.items.map(\.action) == [.repair])
        #expect(plan.items.map(\.reason) == [.targetSnapshotIncomplete])
    }

    @Test("An unverified duplicate blocks a verified target mutation")
    func unverifiedDuplicateBlocksMutation() throws {
        let arm = storedArm(ruleMode: .busy)
        let source = instance(id: "mixed-ownership")
        let initial = try #require(
            SyncPlanner.plan(
                arm: arm,
                sources: [source],
                mappings: [],
                targetEvents: [],
                window: try window(),
                sourceSnapshotComplete: true
            ).items.first
        )
        let mapping = StoredMirrorMapping(
            mirrorKey: initial.mirrorKey,
            armID: arm.id,
            sourceKeyHash: source.sourceKeyHash,
            providerEventID: "provider-mixed",
            providerVersion: "v1",
            desiredFingerprint: "previous",
            ownershipKeyID: "synthetic-key",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let plan = SyncPlanner.plan(
            arm: arm,
            sources: [source],
            mappings: [mapping],
            targetEvents: [
                TargetEventObservation(
                    calendarBindingID: arm.targetBindingID,
                    providerEventID: mapping.providerEventID,
                    mirrorKey: mapping.mirrorKey,
                    contentFingerprint: "previous",
                    ownershipStatus: .verified
                ),
                TargetEventObservation(
                    calendarBindingID: arm.targetBindingID,
                    providerEventID: "provider-unverified-duplicate",
                    mirrorKey: mapping.mirrorKey,
                    contentFingerprint: nil,
                    ownershipStatus: .missingMarker
                ),
            ],
            window: try window(),
            sourceSnapshotComplete: true
        )

        #expect(plan.items.map(\.action) == [.repair])
        #expect(plan.items.map(\.reason) == [.ownershipUnverified])
    }

    @Test("Changing a Rule updates the existing verified target")
    func ruleChange() throws {
        let source = instance(id: "rule-change", title: "Synthetic approved detail")
        let busyArm = storedArm(ruleMode: .busy)
        let busy = try #require(
            SyncPlanner.plan(
                arm: busyArm,
                sources: [source],
                mappings: [],
                targetEvents: [],
                window: try window(),
                sourceSnapshotComplete: true
            ).items.first
        )
        let mapping = StoredMirrorMapping(
            mirrorKey: busy.mirrorKey,
            armID: busyArm.id,
            sourceKeyHash: source.sourceKeyHash,
            providerEventID: "provider-rule-change",
            providerVersion: "v1",
            desiredFingerprint: busy.desiredFingerprint!,
            ownershipKeyID: "synthetic-key",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let fullDetailsArm = storedArm(ruleMode: .fullDetails)

        let plan = SyncPlanner.plan(
            arm: fullDetailsArm,
            sources: [source],
            mappings: [mapping],
            targetEvents: [
                TargetEventObservation(
                    calendarBindingID: busyArm.targetBindingID,
                    providerEventID: mapping.providerEventID,
                    providerVersion: mapping.providerVersion,
                    mirrorKey: mapping.mirrorKey,
                    contentFingerprint: busy.desiredFingerprint,
                    ownershipKeyID: mapping.ownershipKeyID,
                    ownershipStatus: .verified
                ),
            ],
            window: try window(),
            sourceSnapshotComplete: true
        )

        #expect(plan.items.map(\.action) == [.update])
        #expect(plan.items.first?.payload?.title == "Synthetic approved detail")
    }
}

private func storedArm(ruleMode: ArmRuleMode, isMain: Bool = false) -> StoredArm {
    StoredArm(
        id: "arm-one",
        configurationID: "synthetic-configuration",
        sourceBindingIDs: ["source-calendar"],
        targetBindingID: "target-calendar",
        ruleMode: ruleMode,
        isMain: isMain
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
    isPrivate: Bool = false,
    location: String? = nil,
    notes: String? = nil,
    url: String? = nil,
    organizer: EventParticipant? = nil,
    attendees: [EventParticipant] = []
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
        providerUpdatedAt: nil,
        location: location,
        notes: notes,
        url: url,
        organizer: organizer,
        attendees: attendees
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
