import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Recurring EventKit occurrences")
struct RecurringEventTests {
    @Test("Shared event IDs retain every bounded occurrence")
    func storesEveryOccurrence() throws {
        let fixture = try RecurringCacheFixture()
        let events = [60.0, 120.0, 180.0].map { fixture.event(at: $0) }
        try fixture.refresh(events)
        let instances = try fixture.instances()
        #expect(instances.count == 3)
        #expect(Set(instances.map(\.sourceKeyHash)).count == 3)
        #expect(instances.map(\.startsAt) == events.map { $0.start! })
        #expect(Set(instances.map(\.providerEventID)) == ["synthetic-series"])

        try fixture.refresh(Array(events.reversed()))
        #expect(try fixture.instances() == instances)
        #expect(EventNormalizer.normalize(
            events, connection: fixture.connection, calendar: fixture.calendar,
            from: Date(timeIntervalSince1970: 100), through: Date(timeIntervalSince1970: 150)
        ).instances.count == 1)
    }

    @Test("Moved and cancelled occurrences do not replace their siblings")
    func editsAndCancelsOneOccurrence() throws {
        let fixture = try RecurringCacheFixture()
        try fixture.refresh([60.0, 120.0, 180.0].map { fixture.event(at: $0) })
        let before = try fixture.instances()
        try #require(before.count == 3)
        try fixture.refresh([fixture.event(at: 120, movedTo: 140)], mode: .incremental)
        let moved = try fixture.instances()
        #expect(Set(moved.map(\.sourceKeyHash)) == Set(before.map(\.sourceKeyHash)))
        #expect(moved.map(\.startsAt) == [60.0, 140.0, 180.0].map(Date.init(timeIntervalSince1970:)))
        try fixture.refresh([fixture.event(at: 120, cancelled: true)], mode: .incremental)
        #expect(try fixture.instances().map(\.sourceKeyHash) == [before[0].sourceKeyHash, before[2].sourceKeyHash])
    }

    @Test(arguments: ["eventkit", "google", "microsoft"])
    func preservesUnrelatedIdentities(provider: String) throws {
        let fixture = try RecurringCacheFixture(provider: provider)
        let plain = fixture.event(at: 60, recurring: false)
        let recurring = fixture.event(at: 60)
        let normalize: (ProviderEvent) -> StoredNormalizedInstance = { event in
            EventNormalizer.normalize(
                [event], connection: fixture.connection, calendar: fixture.calendar,
                from: fixture.start, through: fixture.end
            ).instances[0]
        }
        #expect((normalize(plain).sourceKeyHash == normalize(recurring).sourceKeyHash) == (provider != "eventkit"))
    }

    @Test(arguments: ["eventkit", "google", "microsoft"])
    func reviewDoesNotGuessRecurrence(provider: String) throws {
        let cache = try RecurringCacheFixture(provider: provider)
        try cache.refresh([cache.event(at: 60, recurring: provider != "eventkit")])
        let arm = StoredArm(id: "arm", configurationID: "default", sourceBindingIDs: ["source"], targetBindingID: "target", ruleMode: .busy)
        let window = try SyncWindow(start: cache.start, end: cache.end)
        let plan = SyncPlanner.plan(arm: arm, sources: try cache.instances(), mappings: [], targetEvents: [], window: window, sourceSnapshotComplete: true)
        #expect(plan.items.count == 1)
        #expect(SyncPlanReview.summarize(plan: plan, sources: try cache.instances(), sourceProviders: ["source": provider]).recurringOccurrenceCreateCount == 0)
    }

    @Test("Review distinguishes missing target recreation from stale mapping cleanup")
    func missingTargetReview() async throws {
        let fixture = try RecurringLifecycleFixture()
        try fixture.cache.refresh([fixture.cache.event(at: 60)])
        _ = try await fixture.run()
        await fixture.targets.removeCopies("busy")
        let arm = fixture.arms[0]
        let before = try fixture.cache.repository.mirrorMappings(armID: arm.id)
        let recreationPlan = try await fixture.plan(arm)
        #expect(SyncPlanReview.summarize(plan: recreationPlan, sources: try fixture.cache.instances(), sourceProviders: ["source": "eventkit"]) == SyncReviewSummary(targetRecreationCount: 1))
        try fixture.cache.refresh([])
        let cleanupPlan = try await fixture.plan(arm)
        #expect(SyncPlanReview.summarize(plan: cleanupPlan, sources: [], sourceProviders: ["source": "eventkit"]) == SyncReviewSummary(staleMappingCleanupCount: 1))
        #expect(try fixture.cache.repository.mirrorMappings(armID: arm.id) == before)
        let fullPlan = try await fixture.plan(fixture.arms[1])
        #expect(SyncPlanReview.summarize(plan: fullPlan, sources: [], sourceProviders: ["source": "eventkit"]) == SyncReviewSummary(otherSourceMissingRemovalCount: 1))
    }

    @Test("Occurrence evidence outside the plan window cannot label legacy removals")
    func boundedReview() async throws {
        let fixture = try RecurringLifecycleFixture()
        try fixture.cache.refresh([fixture.cache.event(at: 180, recurring: false)])
        _ = try await fixture.run()
        try fixture.cache.refresh([fixture.cache.event(at: 180)])
        let full = try await fixture.plan(fixture.arms[0])
        let narrow = SyncPlan(window: try SyncWindow(start: fixture.cache.start, end: Date(timeIntervalSince1970: 100)), items: full.items)
        let review = SyncPlanReview.summarize(plan: narrow, sources: try fixture.cache.instances(), sourceProviders: ["source": "eventkit"])
        #expect(review.recurringOccurrenceCreateCount == 0)
        #expect(review.legacyRecurringRemovalCandidateCount == 0)
        #expect(review.otherSourceMissingRemovalCount == 1)
    }

    @Test("Busy and Full copies converge independently through occurrence changes")
    func convergesOccurrenceCopies() async throws {
        let fixture = try RecurringLifecycleFixture()
        try fixture.cache.refresh([60.0, 120.0, 180.0].map { fixture.cache.event(at: $0) })
        #expect(try await fixture.run() == 6)
        #expect(try await fixture.run() == 0)
        for arm in fixture.arms {
            let copies = await fixture.targets.snapshots(arm.targetBindingID).filter { $0.provenance != nil }
            #expect(copies.count == 3)
            #expect(Set(copies.compactMap { $0.payload?.startsAt }).count == 3)
            if arm.ruleMode == .busy {
                #expect(copies.allSatisfy { $0.payload?.title == "Busy" && $0.payload?.notes == nil && $0.payload?.location == nil })
            } else {
                #expect(copies.allSatisfy { $0.payload?.title == "Synthetic recurring event" })
            }
        }
        try fixture.cache.refresh([fixture.cache.event(at: 120, movedTo: 140)], mode: .incremental)
        #expect(try await fixture.run() == 2)
        #expect(try await fixture.run() == 0)
        try fixture.cache.refresh([fixture.cache.event(at: 120, cancelled: true)], mode: .incremental)
        #expect(try await fixture.run() == 2)
        #expect(try await fixture.run() == 0)
        for arm in fixture.arms {
            let snapshots = await fixture.targets.snapshots(arm.targetBindingID)
            #expect(snapshots.filter { $0.provenance != nil }.count == 2)
            #expect(snapshots.filter { $0.providerEventID == "unmanaged-original" } == [RecurringTargets.original])
        }
    }

    @Test("Existing owned series copies reconcile without resetting state or keys")
    func reconcilesLegacySeriesCopies() async throws {
        let fixture = try RecurringLifecycleFixture()
        // The previous key used only the shared event ID. Seed its collapsed
        // source and signed copies before refreshing with distinct occurrences.
        try fixture.cache.refresh([fixture.cache.event(at: 180, recurring: false)])
        #expect(try await fixture.run() == 2)
        try fixture.cache.refresh([60.0, 120.0, 180.0].map { fixture.cache.event(at: $0) })
        for arm in fixture.arms {
            let plan = try await fixture.plan(arm)
            #expect(plan.items.filter { $0.action == .create }.count == 3)
            #expect(plan.items.filter { $0.action == .remove }.count == 1)
            #expect(plan.items.allSatisfy { $0.action != .repair })
            let review = SyncPlanReview.summarize(
                plan: plan, sources: try fixture.cache.instances(), sourceProviders: ["source": "eventkit"]
            )
            #expect(review == SyncReviewSummary(recurringOccurrenceCreateCount: 3, legacyRecurringRemovalCandidateCount: 1))
            #expect(try await fixture.plan(arm) == plan)

        }
        #expect(try await fixture.run() == 8)
        #expect(try await fixture.run() == 0)
        for arm in fixture.arms {
            #expect(try fixture.cache.repository.mirrorMappings(armID: arm.id).count == 3)
            let snapshots = await fixture.targets.snapshots(arm.targetBindingID)
            #expect(snapshots.filter { $0.provenance != nil }.count == 3)
            #expect(snapshots.filter { $0.providerEventID == "unmanaged-original" } == [RecurringTargets.original])
        }
    }

    @Test("Unverified legacy copies block reconciliation before any writes")
    func stopsForUnverifiedLegacyCopies() async throws {
        let fixture = try RecurringLifecycleFixture()
        try fixture.cache.refresh([fixture.cache.event(at: 180, recurring: false)])
        _ = try await fixture.run()
        await fixture.targets.removeCopyMarkers("busy")
        let before = await fixture.targets.snapshots("busy")
        try fixture.cache.refresh([60.0, 120.0, 180.0].map { fixture.cache.event(at: $0) })
        let plan = try await fixture.plan(fixture.arms[0])
        #expect(plan.items.contains { $0.action == .repair && $0.reason == .ownershipUnverified })
        let review = SyncPlanReview.summarize(
            plan: plan, sources: try fixture.cache.instances(), sourceProviders: ["source": "eventkit"]
        )
        #expect(review.legacyRecurringRemovalCandidateCount == 0)
        #expect(review.otherRepairCount == 1)

        await #expect(throws: ManagedEventLifecycleError.ambiguousRepair(.ownershipUnverified)) {
            try await fixture.run()
        }
        #expect(await fixture.targets.snapshots("busy") == before)
    }
}

private struct RecurringCacheFixture {
    let repository: LocalStateRepository
    let connection: StoredConnection
    let calendar: StoredCalendarBinding
    let start = Date(timeIntervalSince1970: 0)
    let end = Date(timeIntervalSince1970: 300)

    init(provider: String = "eventkit") throws {
        repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        connection = StoredConnection(id: "connection", configurationID: "default", provider: provider, displayLabel: "Synthetic", isEnabled: true)
        calendar = StoredCalendarBinding(id: "source", connectionID: "connection", providerCalendarID: "source", displayLabel: "Synthetic source", isSelected: true, isReadOnly: false)
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(connectionID: connection.id, bindings: [calendar])
    }

    func event(at original: Double, movedTo: Double? = nil, cancelled: Bool = false, recurring: Bool = true) -> ProviderEvent {
        ProviderEvent(
            provider: connection.provider, connectionID: connection.id, calendarID: calendar.providerCalendarID,
            eventID: "synthetic-series", seriesID: recurring && movedTo == nil ? "synthetic-series" : nil,
            originalStart: recurring ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: original)) : nil,
            start: cancelled ? nil : Date(timeIntervalSince1970: movedTo ?? original),
            end: cancelled ? nil : Date(timeIntervalSince1970: (movedTo ?? original) + 30),
            isAllDay: false, availability: .busy, isCancelled: cancelled, isPrivate: false,
            title: "Synthetic recurring event", updatedAt: nil,
            notes: "Synthetic agenda", url: "https://example.com/meeting"
        )
    }

    func refresh(_ events: [ProviderEvent], mode: ProviderRefreshMode = .full) throws {
        try EventCache(repository: repository).apply(
            ProviderEventPage(events: events, nextSyncToken: nil, refreshMode: mode),
            connection: connection, calendar: calendar, from: start, through: end
        )
    }

    func instances() throws -> [StoredNormalizedInstance] {
        try repository.normalizedInstances(calendarBindingIDs: [calendar.id], from: start, through: end)
    }
}

private struct RecurringLifecycleFixture {
    let cache: RecurringCacheFixture
    let arms: [StoredArm]
    let targets = RecurringTargets()
    let secrets = RecurringSecrets()
    let window: SyncWindow

    init() throws {
        let cache = try RecurringCacheFixture()
        self.cache = cache
        let bindings = ["busy", "full"].map {
            StoredCalendarBinding(id: $0, connectionID: cache.connection.id, providerCalendarID: $0, displayLabel: "Synthetic \($0)", isSelected: false, isReadOnly: false)
        }
        try cache.repository.replaceCalendarBindings(connectionID: cache.connection.id, bindings: [cache.calendar] + bindings)
        let service = ArmConfigurationService(repository: cache.repository)
        arms = [
            try service.createArm(id: "busy-arm", sourceBindingIDs: [cache.calendar.id], targetBindingID: "busy"),
            try service.createArm(id: "full-arm", sourceBindingIDs: [cache.calendar.id], targetBindingID: "full", ruleMode: .fullDetails),
        ]
        window = try SyncWindow(start: cache.start, end: cache.end)
    }

    func observations(_ arm: StoredArm) async throws -> [TargetEventObservation] {
        try ManagedTargetObserver(secretStore: secrets).observations(
            snapshots: await targets.snapshots(arm.targetBindingID), arm: arm,
            mappings: try cache.repository.mirrorMappings(armID: arm.id)
        )
    }

    func plan(_ arm: StoredArm) async throws -> SyncPlan {
        SyncPlanner.plan(
            arm: arm, targetProvider: .eventKit, sources: try cache.instances(),
            mappings: try cache.repository.mirrorMappings(armID: arm.id),
            targetEvents: try await observations(arm), window: window, sourceSnapshotComplete: true
        )
    }

    func run() async throws -> Int {
        var writes = 0
        for arm in arms {
            let summary = try await ManagedEventConvergenceService(repository: cache.repository, secretStore: secrets).converge(
                initialItems: try await plan(arm).items, arm: arm, targetProvider: .eventKit,
                initialObservations: try await observations(arm), window: window
            ) {
                await targets.snapshots(arm.targetBindingID)
            } perform: { mutation in
                try await targets.perform(mutation, calendar: arm.targetBindingID)
            }
            writes += summary.providerWriteCount
        }
        return writes
    }
}

private actor RecurringTargets {
    static let original = ManagedEventSnapshot(providerEventID: "unmanaged-original", providerVersion: "v1", payload: nil, markerStatus: .absent, provenance: nil)
    private var storage: [String: [ManagedEventSnapshot]] = ["busy": [original], "full": [original]]
    private var nextID = 0

    func snapshots(_ calendar: String) -> [ManagedEventSnapshot] { storage[calendar]! }

    func removeCopies(_ calendar: String) {
        storage[calendar] = [Self.original]
    }

    func removeCopyMarkers(_ calendar: String) {
        storage[calendar] = storage[calendar]!.map {
            ManagedEventSnapshot(providerEventID: $0.providerEventID, providerVersion: $0.providerVersion, payload: $0.payload, markerStatus: .absent, provenance: nil)
        }
    }

    func perform(_ mutation: ManagedEventMutation, calendar: String) throws -> ManagedEventMutationResult {
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
            _ = try #require(storage[calendar]!.first { $0.providerEventID == id && $0.provenance != nil })
            storage[calendar]!.removeAll { $0.providerEventID == id }
            return .deleted
        }
    }
}

private final class RecurringSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretReference: Data] = [:]
    func save(_ value: Data, for reference: SecretReference) throws { lock.withLock { values[reference] = value } }
    func value(for reference: SecretReference) throws -> Data? { lock.withLock { values[reference] } }
    func removeValue(for reference: SecretReference) throws { _ = lock.withLock { values.removeValue(forKey: reference) } }
}
