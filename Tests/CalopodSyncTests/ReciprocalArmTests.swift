import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Reciprocal Arms")
struct ReciprocalArmTests {
    @Test("Six routes converge without copying mirrors or changing originals", arguments: [ProviderKind.eventKit, .google, .microsoft])
    func converges(provider: ProviderKind) async throws {
        let fixture = try ReciprocalFixture(provider: provider)
        let originals = await fixture.calendars.originals()
        #expect(try await fixture.run() == 6)
        #expect(try await fixture.run() == 0)
        #expect(try await fixture.run() == 0)
        #expect(await fixture.calendars.originals() == originals)
        #expect(await fixture.calendars.copyCount() == 6)
        #expect(try fixture.repository.normalizedInstances(
            calendarBindingIDs: ["a", "b", "c"], from: fixture.window.start, through: fixture.window.end
        ).count == 3)

        let copies = await fixture.calendars.copies()
        #expect(copies.filter { $0.provenance?.ruleMode == .busy }.count == 3)
        for copy in copies where copy.provenance?.ruleMode == .busy {
            #expect(copy.payload?.title == "Busy")
            #expect(copy.payload?.location == nil)
            #expect(copy.payload?.notes == nil)
        }
        #expect(copies.filter { $0.provenance?.ruleMode == .fullDetails }.count == 3)

        // Updating an original affects only its direct outgoing routes.
        await fixture.calendars.editOriginal(in: "b", title: "Synthetic revised event")
        let edited = await fixture.calendars.originals()
        #expect(try await fixture.run() == 2)
        #expect(try await fixture.run() == 0)
        #expect(await fixture.calendars.originals() == edited)
        #expect(await fixture.calendars.copies().filter { $0.payload?.title == "Synthetic revised event" }.count == 2)

        // Both Busy Arms must remove their own copy without touching the
        // Full details Arm that shares the same target or any original.
        await fixture.calendars.deleteOriginal(in: "c")
        let remaining = await fixture.calendars.originals()
        #expect(try await fixture.run() == 2)
        #expect(try await fixture.run() == 0)
        #expect(await fixture.calendars.copyCount() == 4)
        #expect(await fixture.calendars.originals() == remaining)
    }

    @Test("A mapped copy with a missing marker cannot become a source on incremental refresh")
    func missingMarker() async throws {
        let fixture = try ReciprocalFixture(provider: .eventKit)
        _ = try await fixture.run()
        let damagedID = try #require(await fixture.calendars.removeCopyMarker(in: "a"))
        try await fixture.refresh(mode: .incremental)
        let sources = try fixture.repository.normalizedInstances(
            calendarBindingIDs: ["a", "b", "c"], from: fixture.window.start, through: fixture.window.end
        )
        #expect(sources.count == 3)
        #expect(!sources.contains { $0.providerEventID == damagedID })
        let plan = try await fixture.plan(arm: fixture.arms[1])
        #expect(plan.items.contains { $0.action == .repair && $0.reason == .ownershipUnverified })
        #expect(await fixture.calendars.copyCount() == 6)
    }

    @Test("An incremental event that acquires a managed marker is evicted from cached sources")
    func evictsPreviousSource() async throws {
        let fixture = try ReciprocalFixture(provider: .eventKit)
        try await fixture.refresh()
        #expect(try fixture.repository.normalizedInstances(
            calendarBindingIDs: ["c"], from: fixture.window.start, through: fixture.window.end
        ).count == 1)
        await fixture.calendars.markOriginalAsManaged(in: "c")
        try await fixture.refresh(mode: .incremental)
        #expect(try fixture.repository.normalizedInstances(
            calendarBindingIDs: ["c"], from: fixture.window.start, through: fixture.window.end
        ).isEmpty)
    }

}

private struct ReciprocalFixture {
    let repository: LocalStateRepository
    let connection: StoredConnection
    let bindings: [StoredCalendarBinding]
    let arms: [StoredArm]
    let window: SyncWindow
    let calendars = ReciprocalCalendars()
    let secrets = ReciprocalSecrets()
    let provider: ProviderKind

    init(provider: ProviderKind) throws {
        self.provider = provider
        repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        connection = StoredConnection(id: "connection", configurationID: "default", provider: provider.rawValue, displayLabel: "Synthetic", isEnabled: true)
        try repository.saveConnection(connection)
        bindings = ["a", "b", "c"].map {
            StoredCalendarBinding(id: $0, connectionID: "connection", providerCalendarID: $0, displayLabel: "Synthetic \($0)", isSelected: true, isReadOnly: false)
        }
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: bindings)
        let service = ArmConfigurationService(repository: repository)
        arms = [
            try service.createArm(id: "busy-to-b", sourceBindingIDs: ["a", "c"], targetBindingID: "b"),
            try service.createArm(id: "full-to-a", sourceBindingIDs: ["b"], targetBindingID: "a", ruleMode: .fullDetails),
            try service.createArm(id: "busy-to-a", sourceBindingIDs: ["c"], targetBindingID: "a"),
            try service.createArm(id: "full-to-c", sourceBindingIDs: ["a", "b"], targetBindingID: "c", ruleMode: .fullDetails),
        ]
        window = try SyncWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100))
    }

    func refresh(mode: ProviderRefreshMode = .full) async throws {
        for binding in bindings {
            let events = await calendars.events(in: binding.id, provider: provider)
            try EventCache(repository: repository).apply(
                ProviderEventPage(events: events, nextSyncToken: nil, refreshMode: mode), connection: connection, calendar: binding,
                from: window.start, through: window.end
            )
        }
    }

    func plan(arm: StoredArm) async throws -> SyncPlan {
        let mappings = try repository.mirrorMappings(armID: arm.id)
        let observations = try ManagedTargetObserver(secretStore: secrets).observations(
            snapshots: await calendars.snapshots(in: arm.targetBindingID), arm: arm, mappings: mappings
        )
        return SyncPlanner.plan(
            arm: arm, targetProvider: provider,
            sources: try repository.normalizedInstances(calendarBindingIDs: arm.sourceBindingIDs, from: window.start, through: window.end),
            mappings: mappings, targetEvents: observations, window: window, sourceSnapshotComplete: true
        )
    }

    func run() async throws -> Int {
        try await refresh()
        var writes = 0
        for arm in arms {
            let plan = try await plan(arm: arm)
            let observations = try ManagedTargetObserver(secretStore: secrets).observations(
                snapshots: await calendars.snapshots(in: arm.targetBindingID), arm: arm,
                mappings: try repository.mirrorMappings(armID: arm.id)
            )
            let summary = try await ManagedEventConvergenceService(repository: repository, secretStore: secrets).converge(
                initialItems: plan.items, arm: arm, targetProvider: provider,
                initialObservations: observations, window: window
            ) {
                await calendars.snapshots(in: arm.targetBindingID)
            } perform: { mutation in
                try await calendars.perform(mutation, in: arm.targetBindingID)
            }
            writes += summary.providerWriteCount
        }
        return writes
    }
}

private actor ReciprocalCalendars {
    private var storage: [String: [ManagedEventSnapshot]] = Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map { calendar in
        (calendar, [ManagedEventSnapshot(
            providerEventID: "original", providerVersion: "v1",
            payload: DesiredEventPayload(startsAt: Date(timeIntervalSince1970: 10), endsAt: Date(timeIntervalSince1970: 20), isAllDay: false, availability: "busy", title: "Synthetic \(calendar)", isPrivate: false, location: "Example room", notes: "Synthetic notes"),
            markerStatus: .absent, provenance: nil
        )])
    })
    private var nextID = 0
    func snapshots(in calendar: String) -> [ManagedEventSnapshot] { storage[calendar] ?? [] }
    func originals() -> [ManagedEventSnapshot] { storage.keys.sorted().flatMap { storage[$0]!.filter { $0.providerEventID == "original" } } }
    func copies() -> [ManagedEventSnapshot] { storage.values.flatMap { $0.filter { $0.providerEventID != "original" } } }
    func copyCount() -> Int { copies().count }
    func events(in calendar: String, provider: ProviderKind) -> [ProviderEvent] {
        snapshots(in: calendar).map {
            ProviderEvent(provider: provider.rawValue, connectionID: "connection", calendarID: calendar,
                          eventID: $0.providerEventID, seriesID: nil, originalStart: nil, start: $0.payload?.startsAt, end: $0.payload?.endsAt,
                          isAllDay: $0.payload?.isAllDay ?? false, availability: .busy, isCancelled: false, isPrivate: false,
                          title: $0.payload?.title, updatedAt: nil, isManagedMirror: $0.markerStatus != .absent,
                          location: $0.payload?.location, notes: $0.payload?.notes)
        }
    }
    func editOriginal(in calendar: String, title: String) {
        let old = storage[calendar]![0]
        let payload = old.payload!
        storage[calendar]![0] = ManagedEventSnapshot(providerEventID: old.providerEventID, providerVersion: "v2",
            payload: DesiredEventPayload(startsAt: payload.startsAt, endsAt: payload.endsAt, isAllDay: false, availability: "busy", title: title, isPrivate: false, location: payload.location, notes: payload.notes),
            markerStatus: .absent, provenance: nil)
    }
    func markOriginalAsManaged(in calendar: String) {
        let old = storage[calendar]![0]
        storage[calendar]![0] = ManagedEventSnapshot(providerEventID: old.providerEventID,
            providerVersion: old.providerVersion, payload: old.payload, markerStatus: .invalid, provenance: nil)
    }
    func deleteOriginal(in calendar: String) { storage[calendar]!.removeAll { $0.providerEventID == "original" } }
    func removeCopyMarker(in calendar: String) -> String? {
        guard let index = storage[calendar]!.firstIndex(where: { $0.provenance != nil }) else { return nil }
        let old = storage[calendar]![index]
        storage[calendar]![index] = ManagedEventSnapshot(providerEventID: old.providerEventID, providerVersion: old.providerVersion, payload: old.payload, markerStatus: .absent, provenance: nil)
        return old.providerEventID
    }
    func perform(_ mutation: ManagedEventMutation, in calendar: String) throws -> ManagedEventMutationResult {
        switch mutation {
        case let .create(request):
            nextID += 1
            let id = "copy-\(nextID)"
            storage[calendar]!.append(ManagedEventSnapshot(providerEventID: id, providerVersion: "v1", payload: request.payload, markerStatus: .parsed, provenance: request.provenance))
            return .written(ManagedEventWriteResult(providerEventID: id, providerVersion: "v1"))
        case let .update(id, _, request):
            let index = try #require(storage[calendar]!.firstIndex { $0.providerEventID == id && $0.provenance != nil })
            storage[calendar]![index] = ManagedEventSnapshot(providerEventID: id, providerVersion: "v2", payload: request.payload, markerStatus: .parsed, provenance: request.provenance)
            return .written(ManagedEventWriteResult(providerEventID: id, providerVersion: "v2"))
        case let .delete(id, _):
            #expect(id != "original")
            storage[calendar]!.removeAll { $0.providerEventID == id }
            return .deleted
        }
    }
}

private final class ReciprocalSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretReference: Data] = [:]
    func save(_ value: Data, for reference: SecretReference) throws { lock.withLock { values[reference] = value } }
    func value(for reference: SecretReference) throws -> Data? { lock.withLock { values[reference] } }
    func removeValue(for reference: SecretReference) throws { _ = lock.withLock { values.removeValue(forKey: reference) } }
}
