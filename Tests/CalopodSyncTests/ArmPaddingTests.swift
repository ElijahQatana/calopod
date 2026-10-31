import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Arm padding")
struct ArmPaddingTests {
    @Test("The copy starts early and ends late, and the source keeps its time", arguments: [
        // before, after, copy start, copy end, for a source from 36000 to 39600
        (15, 15, 35_100.0, 40_500.0),
        (30, 0, 34_200.0, 39_600.0),
        (0, 45, 36_000.0, 42_300.0),
        (0, 0, 36_000.0, 39_600.0),
    ] as [(Int, Int, Double, Double)])
    func paddedSpan(before: Int, after: Int, copyStart: Double, copyEnd: Double) throws {
        let source = event("a", start: 36_000, end: 39_600)
        let payload = try #require(plan(padding: pad(before, after), sources: [source]).items.first?.payload)
        #expect(payload.startsAt == Date(timeIntervalSince1970: copyStart))
        #expect(payload.endsAt == Date(timeIntervalSince1970: copyEnd))
        #expect(source.startsAt == Date(timeIntervalSince1970: 36_000))
    }

    @Test("Back-to-back events each get their own padded copy")
    func backToBack() throws {
        let first = event("a", start: 36_000, end: 39_600)
        let second = event("b", start: 39_600, end: 43_200)
        let items = plan(padding: pad(15, 15), sources: [first, second]).items
        let spans = items.compactMap(\.payload).map { [$0.startsAt.timeIntervalSince1970, $0.endsAt.timeIntervalSince1970] }
        #expect(items.map(\.action) == [.create, .create])
        #expect(spans.sorted { $0[0] < $1[0] } == [[35_100, 40_500], [38_700, 44_100]])
    }

    @Test("A copy can cross midnight")
    func midnight() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 23, minute: 30))!
        let source = event("a", start: start.timeIntervalSince1970, end: start.addingTimeInterval(1200).timeIntervalSince1970)
        let payload = try #require(plan(padding: pad(30, 30), sources: [source]).items.first?.payload)
        let end = calendar.dateComponents([.day, .hour, .minute], from: payload.endsAt)
        #expect(end.day == 11 && end.hour == 0 && end.minute == 20)
        #expect(calendar.component(.day, from: payload.startsAt) == 10)
    }

    @Test("Padding counts elapsed minutes across a clock change")
    func daylightSaving() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        // The clocks jump from 02:00 to 03:00 on 2026-03-08.
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3))!
        let source = event("a", start: start.timeIntervalSince1970, end: start.addingTimeInterval(3600).timeIntervalSince1970)
        let payload = try #require(plan(padding: pad(60, 0), sources: [source]).items.first?.payload)
        #expect(payload.startsAt == start.addingTimeInterval(-3600))
        #expect(calendar.component(.hour, from: payload.startsAt) == 1)
        #expect(payload.endsAt == source.endsAt)
    }

    @Test("An all-day event is left alone")
    func allDay() throws {
        let source = event("a", start: 0, end: 86_400, isAllDay: true)
        let payload = try #require(plan(padding: pad(30, 30), sources: [source]).items.first?.payload)
        #expect(payload.startsAt == source.startsAt && payload.endsAt == source.endsAt)
    }

    @Test("In-person only pads an event with a place and no meeting link", arguments: [
        // location, url, notes, padded
        ("synthetic-room", nil, nil, true),
        (nil, nil, nil, false),
        ("   ", nil, nil, false),
        ("synthetic-room", "https://example.zoom.us/j/123456789", nil, false),
        ("https://example.zoom.us/j/123456789", nil, nil, false),
        ("synthetic-room", nil, "Join https://example.zoom.us/j/123456789", false),
        ("synthetic-room", "https://example.com/agenda", nil, true),
    ] as [(String?, String?, String?, Bool)])
    func inPersonOnly(location: String?, url: String?, notes: String?, padded: Bool) throws {
        let source = event("a", location: location, url: url, notes: notes)
        let payload = try #require(plan(padding: pad(15, 15, inPersonOnly: true), sources: [source]).items.first?.payload)
        #expect((payload.startsAt != source.startsAt) == padded)
        #expect((payload.endsAt != source.endsAt) == padded)
    }

    @Test("Changing the padding updates the existing copy in place; the same padding leaves it alone")
    func paddingChangeUpdates() throws {
        let source = event("a")
        let copy = Copy(of: source, padding: pad(0, 0))
        let changed = plan(padding: pad(15, 15), sources: [source], copy: copy).items
        #expect(changed.map(\.action) == [.update])
        #expect(changed.first?.mirrorKey == copy.mapping.mirrorKey)
        #expect(changed.first?.desiredFingerprint != copy.mapping.desiredFingerprint)
        #expect(plan(padding: pad(0, 0), sources: [source], copy: copy).items.map(\.action) == [.noOp])
        let padded = Copy(of: source, padding: pad(15, 15))
        #expect(plan(padding: pad(15, 15), sources: [source], copy: padded).items.map(\.action) == [.noOp])
        #expect(plan(padding: pad(15, 30), sources: [source], copy: padded).items.map(\.action) == [.update])
    }

    @Test("Full details copies are not padded")
    func fullDetails() throws {
        let source = event("a")
        let arm = StoredArm(
            id: "synthetic-arm", configurationID: "config", sourceBindingIDs: ["source"],
            targetBindingID: "target", ruleMode: .fullDetails, padding: pad(15, 15))
        let payload = try #require(SyncPlanner.plan(
            arm: arm, sources: [source], mappings: [], targetEvents: [], window: window,
            sourceSnapshotComplete: true).items.first?.payload)
        #expect(payload.startsAt == source.startsAt && payload.endsAt == source.endsAt)
    }

    @Test("Availability counts the padded time as busy")
    func availability() {
        let first = event("a", start: 36_000, end: 39_600)
        let second = event("b", start: 39_600, end: 43_200)
        let allDay = event("c", start: 0, end: 86_400, isAllDay: true)
        let arm = StoredArm(
            id: "synthetic-arm", configurationID: "config", sourceBindingIDs: ["source"],
            targetBindingID: "target", ruleMode: .busy, padding: pad(15, 30))
        let disabled = StoredArm(
            id: "synthetic-off", configurationID: "config", sourceBindingIDs: ["source"],
            targetBindingID: "target", ruleMode: .busy, isEnabled: false, padding: pad(60, 60))
        let padded = AvailabilityCalculator.withPadding([first, second, allDay], arms: [arm, disabled])
        let result = AvailabilityCalculator.calculate(
            instances: padded.filter { !$0.isAllDay }, from: Date(timeIntervalSince1970: 0),
            through: Date(timeIntervalSince1970: 86_400), timeZone: TimeZone(identifier: "UTC")!)
        #expect(result.busy.map { [$0.start.timeIntervalSince1970, $0.end.timeIntervalSince1970] } == [[35_100, 45_000]])
        #expect(padded[2].startsAt == allDay.startsAt && padded[2].endsAt == allDay.endsAt)
    }

    @Test("Padding persists, changes and is checked")
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
        let arm = try service.createArm(
            id: "synthetic-arm", sourceBindingIDs: ["synthetic-source"],
            targetBindingID: "synthetic-target", padding: pad(10, 20))
        #expect(arm.padding == pad(10, 20))
        #expect(try repository.arm(id: arm.id) == arm)
        #expect(try service.updatePadding(armID: arm.id, padding: pad(0, 5, inPersonOnly: true)).padding == pad(0, 5, inPersonOnly: true))
        #expect(throws: ArmConfigurationError.invalidPadding) {
            try service.updatePadding(armID: arm.id, padding: pad(-1, 0))
        }
        #expect(throws: ArmConfigurationError.invalidPadding) {
            try service.updatePadding(armID: arm.id, padding: pad(0, ArmPadding.maxMinutes + 1))
        }
        #expect(throws: ArmConfigurationError.paddingNeedsCopies) {
            try service.createArm(
                sourceBindingIDs: ["synthetic-source"], targetBindingID: "synthetic-target",
                ruleMode: .fullDetails, padding: pad(5, 5))
        }
    }
}

private func pad(_ before: Int, _ after: Int, inPersonOnly: Bool = false) -> ArmPadding {
    ArmPadding(beforeMinutes: before, afterMinutes: after, inPersonOnly: inPersonOnly)
}

private struct Copy {
    let mapping: StoredMirrorMapping
    let observation: TargetEventObservation

    init(of source: StoredNormalizedInstance, padding: ArmPadding) {
        let arm = StoredArm(
            id: "synthetic-arm", configurationID: "config", sourceBindingIDs: ["source"],
            targetBindingID: "target", ruleMode: .busy, padding: padding)
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
    start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2_000_000_000))

private func plan(padding: ArmPadding, sources: [StoredNormalizedInstance], copy: Copy? = nil) -> SyncPlan {
    let arm = StoredArm(
        id: "synthetic-arm", configurationID: "config", sourceBindingIDs: ["source"],
        targetBindingID: "target", ruleMode: .busy, padding: padding)
    return SyncPlanner.plan(
        arm: arm, sources: sources, mappings: copy.map { [$0.mapping] } ?? [],
        targetEvents: copy.map { [$0.observation] } ?? [], window: window, sourceSnapshotComplete: true)
}

private func event(
    _ key: String, start: Double = 36_000, end: Double = 39_600, isAllDay: Bool = false,
    location: String? = nil, url: String? = nil, notes: String? = nil
) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "key-\(key)", connectionID: "connection", calendarBindingID: "source",
        providerEventID: "id-\(key)", recurrenceID: nil, startsAt: Date(timeIntervalSince1970: start),
        endsAt: Date(timeIntervalSince1970: end), isAllDay: isAllDay, availability: "busy",
        isCancelled: false, isPrivate: false, title: "synthetic-source", contentFingerprint: "f-\(key)",
        providerUpdatedAt: nil, location: location, notes: notes, url: url)
}
