import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Arm filters")
struct ArmFilterTests {
    private static let declined = ArmFilters(skipDeclined: true)
    private static let allDay = ArmFilters(skipAllDay: true)
    private static let tagged = ArmFilters(skipDontClone: true)

    @Test("Each filter leaves out its own events and nothing else", arguments: [
        (declined, event("declined", response: .declined), false),
        (declined, event("accepted", response: .accepted), true),
        (allDay, event("all-day", allDay: true), false),
        (allDay, event("timed"), true),
        (tagged, event("tagged-title", title: "Review #dontclone"), false),
        (tagged, event("tagged-notes", notes: "Private\n#dontclone"), false),
        (tagged, event("plain"), true),
        (ArmFilters(), event("declined", response: .declined), true),
        (ArmFilters(), event("all-day", allDay: true), true),
        (ArmFilters(), event("tagged-title", title: "Review #dontclone"), true),
    ])
    func copies(filters: ArmFilters, source: StoredNormalizedInstance, copied: Bool) throws {
        let items = try plan(filters, sources: [source]).items
        #expect(items.map(\.action) == (copied ? [.create] : []))
    }

    @Test("The tag matches in any case and only as written", arguments: [
        ("Lunch #dontclone", nil, true), ("Lunch #DontClone", nil, true),
        (nil, "see below\n#dontclone", true), ("Lunch dontclone", nil, false),
        ("Lunch #dont clone", "#dont-clone", false), (nil, nil, false),
    ] as [(String?, String?, Bool)])
    func tag(title: String?, notes: String?, matches: Bool) throws {
        let source = event("a", title: title, notes: notes)
        let items = try plan(Self.tagged, sources: [source]).items
        #expect(items.isEmpty == matches)
    }

    @Test("A copy is removed once its event matches a filter", arguments: [
        (declined, event("a", response: .declined)),
        (allDay, event("a", allDay: true)),
        (tagged, event("a", notes: "#dontclone")),
    ])
    func removesCopy(filters: ArmFilters, now: StoredNormalizedInstance) throws {
        let copy = Copy(of: event("a"))
        let item = try #require(
            plan(filters, sources: [now], copy: copy).items.first
        )
        #expect(item.action == .remove)
        #expect(item.reason == .filteredOut)
        #expect(item.mirrorKey == copy.mapping.mirrorKey)
    }

    @Test("A copy stays when the filter is off", arguments: [
        event("a", response: .declined), event("a", allDay: true), event("a", title: "#dontclone"),
    ])
    func keepsCopyWithoutFilter(now: StoredNormalizedInstance) throws {
        let copy = Copy(of: now)
        let items = try plan(ArmFilters(), sources: [now], copy: copy).items
        #expect(items.map(\.action) == [.noOp])
    }

    @Test("An event that moves back out of a filter gets a copy again")
    func movesBackIn() throws {
        let declined = event("a", response: .declined)
        #expect(try plan(Self.declined, sources: [declined]).items.isEmpty)
        let accepted = event("a", response: .accepted)
        #expect(try plan(Self.declined, sources: [accepted]).items.map(\.action) == [.create])
    }

    @Test("A copy Calopod cannot prove it made is left for repair, not removed", arguments: [
        TargetOwnershipStatus.missingMarker, .invalidMarker, .wrongTarget,
    ])
    func unprovenCopy(status: TargetOwnershipStatus) throws {
        let copy = Copy(of: event("a"), status: status)
        let items = try plan(
            Self.declined, sources: [event("a", response: .declined)], copy: copy
        ).items
        #expect(items.map(\.action) == [.repair])
    }

    @Test("Removal waits for a complete read of the sources")
    func incompleteSources() throws {
        let copy = Copy(of: event("a"))
        let items = try plan(
            Self.declined, sources: [event("a", response: .declined)], copy: copy, complete: false
        ).items
        #expect(items.map(\.action) == [.repair])
    }

    @Test("Recurring occurrences are judged one at a time")
    func occurrences() throws {
        let series = (0..<3).map {
            event(
                "a\($0)", start: 2_000 + Double($0) * 86_400, end: 3_000 + Double($0) * 86_400,
                response: $0 == 1 ? .declined : .accepted, series: "synthetic-series"
            )
        }
        let items = try plan(Self.declined, sources: series).items
        #expect(items.count == 2)
        #expect(Set(items.compactMap(\.sourceKeyHash)) == ["key-a0", "key-a2"])
    }

    @Test("A tag on the series leaves out every occurrence")
    func taggedSeries() throws {
        let series = (0..<3).map {
            event(
                "a\($0)", title: "Standup #dontclone", start: 2_000 + Double($0) * 86_400,
                end: 3_000 + Double($0) * 86_400, series: "synthetic-series"
            )
        }
        #expect(try plan(Self.tagged, sources: series).items.isEmpty)
        #expect(try plan(ArmFilters(), sources: series).items.count == 3)
    }

    @Test("Only changes still to make are waiting")
    func waiting() throws {
        let declined = event("a", response: .declined)
        #expect(try plan(Self.declined, sources: [declined]).waitingCount == 0)
        #expect(try plan(ArmFilters(), sources: [declined]).waitingCount == 1)
        #expect(try plan(ArmFilters(), sources: [declined], copy: Copy(of: declined)).waitingCount == 0)
        #expect(try plan(Self.declined, sources: [declined], copy: Copy(of: event("a"))).waitingCount == 1)
    }

    @Test("Filters persist and start off")
    func persists() throws {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = StoredConnection(
            id: "synthetic-connection", configurationID: "synthetic-configuration",
            provider: "eventkit", displayLabel: "Synthetic provider", isEnabled: true
        )
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(
            connectionID: connection.id,
            bindings: ["synthetic-source", "synthetic-target"].map {
                StoredCalendarBinding(
                    id: $0, connectionID: connection.id, providerCalendarID: "provider-\($0)",
                    displayLabel: $0, isSelected: true, isReadOnly: false
                )
            }
        )
        let service = ArmConfigurationService(repository: repository)
        let arm = try service.createArm(
            id: "synthetic-arm", sourceBindingIDs: ["synthetic-source"],
            targetBindingID: "synthetic-target"
        )
        #expect(arm.filters.isEmpty)
        let filters = ArmFilters(skipDeclined: true, skipDontClone: true)
        let updated = try service.updateFilters(armID: arm.id, filters: filters)
        #expect(updated.filters == filters)
        #expect(try repository.arm(id: arm.id) == updated)
        #expect(throws: ArmConfigurationError.armNotFound("missing")) {
            try service.updateFilters(armID: "missing", filters: filters)
        }
    }
}

private struct Copy {
    let mapping: StoredMirrorMapping
    let observation: TargetEventObservation

    init(of source: StoredNormalizedInstance, status: TargetOwnershipStatus = .verified) {
        let mirror = SyncPlanner.mirrorKey(armID: "synthetic-arm", sourceKeyHash: source.sourceKeyHash)
        let fingerprint = SyncPlanner.desiredFingerprint(
            payload: DesiredEventPayload(
                startsAt: source.startsAt, endsAt: source.endsAt, isAllDay: source.isAllDay,
                availability: source.availability, title: "Busy", isPrivate: nil,
                timeZoneIdentifier: source.isAllDay ? source.timeZoneIdentifier : nil),
            ruleMode: .busy)
        mapping = StoredMirrorMapping(
            mirrorKey: mirror, armID: "synthetic-arm", sourceKeyHash: source.sourceKeyHash,
            providerEventID: "copy-id", providerVersion: "v1", desiredFingerprint: fingerprint,
            ownershipKeyID: "key", updatedAt: Date(timeIntervalSince1970: 0)
        )
        observation = TargetEventObservation(
            calendarBindingID: "target", providerEventID: "copy-id", mirrorKey: mirror,
            contentFingerprint: fingerprint, ownershipStatus: status
        )
    }
}

private func plan(
    _ filters: ArmFilters, sources: [StoredNormalizedInstance], copy: Copy? = nil, complete: Bool = true
) throws -> SyncPlan {
    let arm = StoredArm(
        id: "synthetic-arm", configurationID: "config", sourceBindingIDs: ["source"],
        targetBindingID: "target", ruleMode: .busy, filters: filters)
    return SyncPlanner.plan(
        arm: arm, sources: sources, mappings: copy.map { [$0.mapping] } ?? [],
        targetEvents: copy.map { [$0.observation] } ?? [],
        window: try SyncWindow(
            start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_000_000)),
        sourceSnapshotComplete: complete)
}

private func event(
    _ key: String, title: String? = "Planning", notes: String? = nil, start: TimeInterval = 2_000,
    end: TimeInterval = 3_000, allDay: Bool = false, response: EventResponseState = .notApplicable,
    series: String? = nil
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-\(key)", connectionID: "connection", calendarBindingID: "source",
        providerEventID: series ?? "id-\(key)", recurrenceID: series.map { _ in "occurrence-\(key)" },
        startsAt: Date(timeIntervalSince1970: start), endsAt: Date(timeIntervalSince1970: end),
        isAllDay: allDay, availability: "busy", isCancelled: false, isPrivate: false, title: title,
        contentFingerprint: "f-\(key)", providerUpdatedAt: nil, notes: notes,
        currentUserResponse: EventResponse(state: response),
        providerSeriesID: series, timeZoneIdentifier: allDay ? "UTC" : nil)
}
