import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Managed event lifecycle")
struct ManagedEventLifecycleTests {
    @Test
    func batchRefusesUnverifiedTargetsBeforeAnyWrites() async throws {
        let fixture = try LifecycleFixture()
        try fixture.repository.saveMirrorMapping(lifecycleMapping(id: "one"))
        await #expect(throws: ManagedEventLifecycleError.missingVerifiedTarget) {
            _ = try await ManagedEventLifecycleService(
                repository: fixture.repository, secretStore: fixture.secrets
            ).applyBatch(
                items: [lifecyclePlanItem(id: "two", action: .create),
                        lifecyclePlanItem(id: "one", action: .remove)],
                arm: fixture.arm, observations: []
            ) { _ in
                Issue.record("Unexpected batch write")
                return []
            }
        }
        #expect(try fixture.repository.mirrorMappings(armID: fixture.arm.id).count == 1)
    }

    @Test
    func batchFailureKeepsSuccessfulMappingsAndReportsEachFailedItem() async throws {
        let fixture = try LifecycleFixture()
        let items = (0..<4).map { lifecyclePlanItem(id: "batch-\($0)", action: .create) }
        do {
            _ = try await ManagedEventLifecycleService(
                repository: fixture.repository, secretStore: fixture.secrets
            ).applyBatch(items: items, arm: fixture.arm, observations: []) { batches in
                #expect(batches.count == 4)
                return batches.enumerated().map { index, batch in
                    batch.map { _ in
                        if index == 1 || index == 3 { return .failure(.httpStatus(412)) }
                        return .success(.written(ManagedEventWriteResult(
                            providerEventID: "created-\(index)", providerVersion: "v1"
                        )))
                    }
                }
            }
            Issue.record("Expected partial failure")
        } catch let error as ManagedEventBatchError {
            #expect(error.failedItemIndices == [1, 3])
        }
        let mappings = try fixture.repository.mirrorMappings(armID: fixture.arm.id)
        #expect(Set(mappings.map(\.providerEventID)) == ["created-0", "created-2"])
    }

    @Test("Target observations require a valid signed marker")
    func observesVerifiedOwnership() throws {
        let fixture = try LifecycleFixture()
        let key = try OwnershipKeyVault(secretStore: fixture.secrets)
            .loadOrCreate(configurationID: fixture.arm.configurationID)
        let item = lifecyclePlanItem(id: "one", action: .create)
        let marker = try OwnershipMarkerCodec.sign(
            configurationID: fixture.arm.configurationID,
            armID: fixture.arm.id,
            mirrorKey: item.mirrorKey,
            sourceKeyHash: item.sourceKeyHash!,
            ruleMode: fixture.arm.ruleMode,
            key: key
        )
        let snapshot = ManagedEventSnapshot(
            providerEventID: "provider-one",
            providerVersion: "v1",
            payload: item.payload,
            markerStatus: .parsed,
            provenance: marker
        )

        let observation = try #require(
            ManagedTargetObserver(secretStore: fixture.secrets)
                .observations(snapshots: [snapshot], arm: fixture.arm, mappings: [lifecycleMapping(id: "one")])
                .first
        )

        #expect(observation.ownershipStatus == .verified)
        #expect(observation.mirrorKey == item.mirrorKey)
        #expect(observation.providerVersion == "v1")
        #expect(observation.contentFingerprint == item.desiredFingerprint)
        #expect(observation.ownershipKeyID == key.id)
    }

    @Test("Copied EventKit markers block repair without provider writes", arguments: [1, 2])
    func copiedEventKitMarker(version: Int) async throws {
        let fixture = try LifecycleFixture()
        let mapping = lifecycleMapping(id: "one")
        try fixture.repository.saveMirrorMapping(mapping)
        let key = try OwnershipKeyVault(secretStore: fixture.secrets)
            .loadOrCreate(configurationID: fixture.arm.configurationID)
        let item = lifecyclePlanItem(id: "one", action: .create)
        let signed = try OwnershipMarkerCodec.sign(
            configurationID: fixture.arm.configurationID,
            armID: fixture.arm.id,
            mirrorKey: item.mirrorKey,
            sourceKeyHash: item.sourceKeyHash!,
            ruleMode: fixture.arm.ruleMode,
            key: key,
            targetBindingID: version == 2 ? fixture.arm.targetBindingID : nil
        )
        let marker = try OwnershipMarkerCodec.marker(from: OwnershipMarkerCodec.markerURL(signed))
        let snapshots = [mapping.providerEventID, "copied-event"].map {
            ManagedEventSnapshot(
                providerEventID: $0, providerVersion: "v1", payload: item.payload,
                markerStatus: .parsed, provenance: marker
            )
        }
        let observer = ManagedTargetObserver(secretStore: fixture.secrets)
        let window = try SyncWindow(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        let source = lifecycleSource(id: "one", startsAt: 2_000)
        let noOpRecorder = LifecycleMutationRecorder()
        let service = ManagedEventLifecycleService(repository: fixture.repository, secretStore: fixture.secrets)
        for _ in 0..<2 {
            let currentMappings = try fixture.repository.mirrorMappings(armID: fixture.arm.id)
            let current = try observer.observations(
                snapshots: [snapshots[0]], arm: fixture.arm, mappings: currentMappings
            )
            let plan = SyncPlanner.plan(
                arm: fixture.arm, targetProvider: .eventKit, sources: [source], mappings: currentMappings,
                targetEvents: current, window: window, sourceSnapshotComplete: true
            )
            #expect(plan.items.map(\.action) == [.noOp])
            let summary = try await service.apply(items: plan.items, arm: fixture.arm, observations: current) { mutation in
                await noOpRecorder.record(mutation)
                return .deleted
            }
            #expect(summary.providerWriteCount == 0)
        }
        #expect(await noOpRecorder.mutations.isEmpty)
        let currentMappings = try fixture.repository.mirrorMappings(armID: fixture.arm.id)
        for mapped in [[mapping], []] {
            let observations = try observer.observations(
                snapshots: snapshots, arm: fixture.arm, mappings: mapped
            )
            #expect(observations.first { $0.providerEventID == "copied-event" }?.ownershipStatus == .wrongTarget)
            let plan = SyncPlanner.plan(
                arm: fixture.arm, targetProvider: .eventKit, sources: [source], mappings: mapped,
                targetEvents: observations, window: window, sourceSnapshotComplete: true
            )
            #expect(plan.items.map(\.reason) == [.ownershipUnverified])
            let recorder = LifecycleMutationRecorder()
            await #expect(throws: ManagedEventLifecycleError.ambiguousRepair(.ownershipUnverified)) {
                try await ManagedEventLifecycleService(
                    repository: fixture.repository, secretStore: fixture.secrets
                ).apply(items: plan.items, arm: fixture.arm, observations: observations) { mutation in
                    await recorder.record(mutation)
                    return .deleted
                }
            }
            #expect(await recorder.mutations.isEmpty)
            #expect(try fixture.repository.mirrorMappings(armID: fixture.arm.id) == currentMappings)
        }
    }

    @Test("EventKit ownership rejects a marker for another target or mapped source")
    func mismatchedEventKitTarget() throws {
        let fixture = try LifecycleFixture()
        let mapping = lifecycleMapping(id: "one")
        let key = try OwnershipKeyVault(secretStore: fixture.secrets)
            .loadOrCreate(configurationID: fixture.arm.configurationID)
        let marker = try OwnershipMarkerCodec.sign(
            configurationID: fixture.arm.configurationID, armID: fixture.arm.id,
            mirrorKey: mapping.mirrorKey, sourceKeyHash: mapping.sourceKeyHash,
            ruleMode: fixture.arm.ruleMode, key: key, targetBindingID: "other-target"
        )
        let snapshot = ManagedEventSnapshot(
            providerEventID: mapping.providerEventID, providerVersion: "v1",
            payload: lifecyclePayload(), markerStatus: .parsed, provenance: marker
        )
        let observer = ManagedTargetObserver(secretStore: fixture.secrets)
        let observations = try observer.observations(snapshots: [snapshot], arm: fixture.arm, mappings: [mapping])
        #expect(observations.first?.ownershipStatus == .wrongTarget)
        let otherMapping = StoredMirrorMapping(
            mirrorKey: lifecycleMapping(id: "two").mirrorKey, armID: mapping.armID,
            sourceKeyHash: "source-two", providerEventID: mapping.providerEventID,
            providerVersion: "v1", desiredFingerprint: "old", ownershipKeyID: key.id,
            updatedAt: mapping.updatedAt
        )
        let mismatched = try observer.observations(snapshots: [snapshot], arm: fixture.arm, mappings: [otherMapping])
        #expect(mismatched.first?.ownershipStatus == .invalidMarker)
    }

    @Test("Missing markers on mapped targets are never treated as owned")
    func rejectsMissingMarker() throws {
        let fixture = try LifecycleFixture()
        let mapping = lifecycleMapping(id: "one")
        try fixture.repository.saveMirrorMapping(mapping)
        let snapshot = ManagedEventSnapshot(
            providerEventID: mapping.providerEventID,
            providerVersion: "v2",
            payload: lifecyclePayload(),
            markerStatus: .absent,
            provenance: nil
        )

        let observation = try #require(
            ManagedTargetObserver(secretStore: fixture.secrets)
                .observations(snapshots: [snapshot], arm: fixture.arm, mappings: [mapping])
                .first
        )

        #expect(observation.ownershipStatus == .missingMarker)
        #expect(observation.mirrorKey == mapping.mirrorKey)
    }

    @Test("A mapped event claiming another Arm is reported instead of replaced")
    func rejectsMismatchedArmMarker() throws {
        let fixture = try LifecycleFixture()
        let mapping = lifecycleMapping(id: "one")
        try fixture.repository.saveMirrorMapping(mapping)
        let key = try OwnershipKeyVault(secretStore: fixture.secrets)
            .loadOrCreate(configurationID: fixture.arm.configurationID)
        let marker = try OwnershipMarkerCodec.sign(
            configurationID: fixture.arm.configurationID,
            armID: "different-arm",
            mirrorKey: "different-mirror",
            sourceKeyHash: "different-source",
            ruleMode: .busy,
            key: key
        )
        let snapshot = ManagedEventSnapshot(
            providerEventID: mapping.providerEventID,
            providerVersion: "v2",
            payload: lifecyclePayload(),
            markerStatus: .parsed,
            provenance: marker
        )

        let observation = try #require(
            ManagedTargetObserver(secretStore: fixture.secrets)
                .observations(snapshots: [snapshot], arm: fixture.arm, mappings: [mapping])
                .first
        )

        #expect(observation.mirrorKey == mapping.mirrorKey)
        #expect(observation.ownershipStatus == .unknownArm)
    }

    @Test("Updates retain provider identity and removals require verified ownership")
    func updatesAndRemoves() async throws {
        let fixture = try LifecycleFixture()
        let mapping = lifecycleMapping(id: "one")
        try fixture.repository.saveMirrorMapping(mapping)
        let update = lifecyclePlanItem(id: "one", action: .update)
        let observation = lifecycleObservation(id: "one", fingerprint: "old")
        let recorder = LifecycleMutationRecorder()
        let service = ManagedEventLifecycleService(
            repository: fixture.repository,
            secretStore: fixture.secrets
        )

        let updateSummary = try await service.apply(
            items: [update],
            arm: fixture.arm,
            observations: [observation],
            now: { Date(timeIntervalSince1970: 20) }
        ) { mutation in
            await recorder.record(mutation)
            return .written(
                ManagedEventWriteResult(
                    providerEventID: mapping.providerEventID,
                    providerVersion: "v2"
                )
            )
        }
        let updated = try #require(fixture.repository.mirrorMappings(armID: fixture.arm.id).first)

        #expect(updateSummary.providerWriteCount == 1)
        #expect(updated.providerEventID == mapping.providerEventID)
        #expect(updated.providerVersion == "v2")
        #expect(updated.desiredFingerprint == update.desiredFingerprint)

        let remove = lifecyclePlanItem(id: "one", action: .remove, payload: nil)
        let refreshedObservation = TargetEventObservation(
            calendarBindingID: fixture.arm.targetBindingID,
            providerEventID: mapping.providerEventID,
            providerVersion: "v2",
            mirrorKey: mapping.mirrorKey,
            contentFingerprint: update.desiredFingerprint,
            ownershipKeyID: updated.ownershipKeyID,
            ownershipStatus: .verified
        )
        let removeSummary = try await service.apply(
            items: [remove],
            arm: fixture.arm,
            observations: [refreshedObservation]
        ) { mutation in
            await recorder.record(mutation)
            return .deleted
        }

        #expect(removeSummary.providerWriteCount == 1)
        #expect(try fixture.repository.mirrorMappings(armID: fixture.arm.id).isEmpty)
        let mutations = await recorder.mutations
        guard case let .update(providerEventID, expectedVersion, _) = mutations[0] else {
            Issue.record("Expected an update mutation")
            return
        }
        #expect(providerEventID == mapping.providerEventID)
        #expect(expectedVersion == "v1")
        guard case let .delete(deletedID, expectedVersion) = mutations[1] else {
            Issue.record("Expected a delete mutation")
            return
        }
        #expect(deletedID == mapping.providerEventID)
        #expect(expectedVersion == "v2")
    }

    @Test("A provider write interrupted before the batch ends resumes without duplicate creates")
    func resumesInterruptedBatch() async throws {
        let fixture = try LifecycleFixture()
        let firstSource = lifecycleSource(id: "one", startsAt: 2_000)
        let secondSource = lifecycleSource(id: "two", startsAt: 4_000)
        let window = try SyncWindow(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        let initial = SyncPlanner.plan(
            arm: fixture.arm,
            sources: [firstSource, secondSource],
            mappings: [],
            targetEvents: [],
            window: window,
            sourceSnapshotComplete: true
        )
        let recorder = InterruptedCreateRecorder()
        let service = ManagedEventLifecycleService(
            repository: fixture.repository,
            secretStore: fixture.secrets
        )

        await #expect(throws: LifecycleSyntheticFailure.self) {
            try await service.apply(
                items: initial.items,
                arm: fixture.arm,
                observations: []
            ) { mutation in
                try await recorder.perform(mutation)
            }
        }
        let persisted = try fixture.repository.mirrorMappings(armID: fixture.arm.id)
        let firstWrite = try #require(await recorder.firstWrite)
        #expect(persisted.count == 1)

        let snapshot = ManagedEventSnapshot(
            providerEventID: firstWrite.result.providerEventID,
            providerVersion: firstWrite.result.providerVersion,
            payload: firstWrite.request.payload,
            markerStatus: .parsed,
            provenance: firstWrite.request.provenance
        )
        let observations = try ManagedTargetObserver(secretStore: fixture.secrets).observations(
            snapshots: [snapshot],
            arm: fixture.arm,
            mappings: persisted
        )
        let resumed = SyncPlanner.plan(
            arm: fixture.arm,
            sources: [firstSource, secondSource],
            mappings: persisted,
            targetEvents: observations,
            window: window,
            sourceSnapshotComplete: true
        )

        #expect(resumed.items.map(\.action).filter { $0 == .noOp }.count == 1)
        #expect(resumed.items.map(\.action).filter { $0 == .create }.count == 1)
    }

    @Test("A verified orphan is adopted, while ambiguous ownership blocks the whole apply")
    func repairsOrRejects() async throws {
        let fixture = try LifecycleFixture()
        let item = lifecyclePlanItem(id: "one", action: .repair, reason: .mappingMissing)
        let observation = lifecycleObservation(id: "one", fingerprint: item.desiredFingerprint)
        let recorder = LifecycleMutationRecorder()
        let service = ManagedEventLifecycleService(
            repository: fixture.repository,
            secretStore: fixture.secrets
        )

        let summary = try await service.apply(
            items: [item],
            arm: fixture.arm,
            observations: [observation]
        ) { mutation in
            await recorder.record(mutation)
            return .deleted
        }

        #expect(summary.providerWriteCount == 0)
        #expect(summary.mappingReconciliationCount == 1)
        #expect(await recorder.mutations.isEmpty)
        #expect(try fixture.repository.mirrorMappings(armID: fixture.arm.id).count == 1)

        let ambiguous = lifecyclePlanItem(
            id: "two",
            action: .repair,
            reason: .ownershipUnverified
        )
        await #expect(throws: ManagedEventLifecycleError.ambiguousRepair(.ownershipUnverified)) {
            try await service.apply(
                items: [lifecyclePlanItem(id: "three", action: .create), ambiguous],
                arm: fixture.arm,
                observations: []
            ) { mutation in
                await recorder.record(mutation)
                return .written(
                    ManagedEventWriteResult(providerEventID: "unexpected", providerVersion: nil)
                )
            }
        }
        #expect(await recorder.mutations.isEmpty)
    }

    @Test("A confirmed missing target is recreated or cleared without guessing")
    func reconcilesMissingTarget() async throws {
        let fixture = try LifecycleFixture()
        let mapping = lifecycleMapping(id: "one")
        try fixture.repository.saveMirrorMapping(mapping)
        let service = ManagedEventLifecycleService(
            repository: fixture.repository,
            secretStore: fixture.secrets
        )
        let recreate = lifecyclePlanItem(
            id: "one",
            action: .repair,
            reason: .targetMissing
        )

        let recreated = try await service.apply(
            items: [recreate],
            arm: fixture.arm,
            observations: []
        ) { mutation in
            guard case .create = mutation else {
                throw LifecycleSyntheticFailure()
            }
            return .written(
                ManagedEventWriteResult(
                    providerEventID: "provider-recreated",
                    providerVersion: "v2"
                )
            )
        }
        let recreatedMapping = try #require(
            fixture.repository.mirrorMappings(armID: fixture.arm.id).first
        )

        #expect(recreated.providerWriteCount == 1)
        #expect(recreated.mappingReconciliationCount == 1)
        #expect(recreatedMapping.providerEventID == "provider-recreated")

        let clear = lifecyclePlanItem(
            id: "one",
            action: .repair,
            reason: .targetMissing,
            payload: nil
        )
        let cleared = try await service.apply(
            items: [clear],
            arm: fixture.arm,
            observations: []
        ) { _ in
            throw LifecycleSyntheticFailure()
        }

        #expect(cleared.providerWriteCount == 0)
        #expect(cleared.mappingReconciliationCount == 1)
        #expect(try fixture.repository.mirrorMappings(armID: fixture.arm.id).isEmpty)
    }

    @Test("Verified duplicates keep the deterministic survivor and delete the rest")
    func repairsVerifiedDuplicates() async throws {
        let fixture = try LifecycleFixture()
        let mapping = lifecycleMapping(id: "one")
        try fixture.repository.saveMirrorMapping(mapping)
        let item = lifecyclePlanItem(
            id: "one",
            action: .repair,
            reason: .verifiedDuplicates
        )
        let observations = [
            TargetEventObservation(
                calendarBindingID: fixture.arm.targetBindingID,
                providerEventID: mapping.providerEventID,
                providerVersion: "mapped-version",
                mirrorKey: item.mirrorKey,
                contentFingerprint: "old",
                ownershipKeyID: mapping.ownershipKeyID,
                ownershipStatus: .verified,
                createdAt: Date(timeIntervalSince1970: 10)
            ),
            TargetEventObservation(
                calendarBindingID: fixture.arm.targetBindingID,
                providerEventID: "provider-deterministic",
                providerVersion: "deterministic-version",
                mirrorKey: item.mirrorKey,
                contentFingerprint: "old",
                ownershipKeyID: mapping.ownershipKeyID,
                ownershipStatus: .verified,
                createdAt: Date(timeIntervalSince1970: 20),
                isProviderPreferredIdentity: true
            ),
            TargetEventObservation(
                calendarBindingID: fixture.arm.targetBindingID,
                providerEventID: "provider-later",
                providerVersion: "later-version",
                mirrorKey: item.mirrorKey,
                contentFingerprint: "old",
                ownershipKeyID: mapping.ownershipKeyID,
                ownershipStatus: .verified,
                createdAt: Date(timeIntervalSince1970: 30)
            ),
        ]
        let recorder = LifecycleMutationRecorder()
        let service = ManagedEventLifecycleService(
            repository: fixture.repository,
            secretStore: fixture.secrets
        )

        let summary = try await service.apply(
            items: [item],
            arm: fixture.arm,
            observations: observations
        ) { mutation in
            await recorder.record(mutation)
            switch mutation {
            case let .update(providerEventID, _, _):
                return .written(
                    ManagedEventWriteResult(
                        providerEventID: providerEventID,
                        providerVersion: "survivor-version"
                    )
                )
            case .delete:
                return .deleted
            case .create:
                throw LifecycleSyntheticFailure()
            }
        }

        #expect(summary.providerWriteCount == 3)
        let mutations = await recorder.mutations
        guard case let .update(survivorID, expectedVersion, _) = mutations[0] else {
            Issue.record("Expected the survivor update first")
            return
        }
        #expect(survivorID == "provider-deterministic")
        #expect(expectedVersion == "deterministic-version")
        let deletedIDs = mutations.dropFirst().compactMap { mutation -> String? in
            guard case let .delete(providerEventID, _) = mutation else { return nil }
            return providerEventID
        }
        #expect(deletedIDs == ["provider-later", mapping.providerEventID].sorted())
        let stored = try #require(
            fixture.repository.mirrorMappings(armID: fixture.arm.id).first
        )
        #expect(stored.providerEventID == "provider-deterministic")
        #expect(stored.providerVersion == "survivor-version")
    }

    @Test("Post-write reads repair a concurrent duplicate and converge", arguments: [false, true])
    func convergesAfterConcurrentCreate(useBatch: Bool) async throws {
        let fixture = try LifecycleFixture()
        let source = lifecycleSource(id: "one", startsAt: 2_000)
        let window = try SyncWindow(
            start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 8_000)
        )
        try fixture.repository.applyEventRefresh(
            connectionID: source.connectionID,
            calendarBindingID: source.calendarBindingID,
            windowStart: window.start,
            windowEnd: window.end,
            instances: [source],
            cancelledSourceKeyHashes: [],
            isFullRefresh: true,
            cursorUpdates: []
        )
        let initial = SyncPlanner.plan(
            arm: fixture.arm,
            sources: [source],
            mappings: [],
            targetEvents: [],
            window: window,
            sourceSnapshotComplete: true
        )
        let provider = DuplicateConvergenceProvider()
        let service = ManagedEventConvergenceService(
            repository: fixture.repository,
            secretStore: fixture.secrets
        )

        let batch: ManagedEventBatchPerformer = { batches in
            var results: [[Result<ManagedEventMutationResult, ProviderFailure>]] = []
            for batch in batches {
                var replies: [Result<ManagedEventMutationResult, ProviderFailure>] = []
                for mutation in batch {
                    replies.append(.success(try await provider.perform(mutation)))
                }
                results.append(replies)
            }
            return results
        }
        let summary = try await service.converge(
            initialItems: initial.items,
            arm: fixture.arm,
            targetProvider: .google,
            initialObservations: [],
            window: window,
            readSnapshots: { await provider.readSnapshots() },
            performBatch: useBatch ? batch : nil, perform: { mutation in
                try await provider.perform(mutation)
            }
        )

        #expect(summary.providerWriteCount == 3)
        #expect(await provider.readCount == 2)
        #expect(await provider.snapshotCount == 1)
        let mapping = try #require(
            fixture.repository.mirrorMappings(armID: fixture.arm.id).first
        )
        #expect(mapping.providerEventID == "provider-deterministic")
    }
}

private struct LifecycleFixture {
    let repository: LocalStateRepository
    let arm: StoredArm
    let secrets = LifecycleMemorySecretStore()

    init() throws {
        repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        let connection = StoredConnection(
            id: "synthetic-connection",
            configurationID: "synthetic-configuration",
            provider: "eventkit",
            displayLabel: "Synthetic provider",
            isEnabled: true
        )
        try repository.saveConnection(connection)
        try repository.replaceCalendarBindings(
            connectionID: connection.id,
            bindings: [
                StoredCalendarBinding(
                    id: "source-calendar",
                    connectionID: connection.id,
                    providerCalendarID: "provider-source",
                    displayLabel: "Synthetic source",
                    isSelected: true,
                    isReadOnly: false
                ),
                StoredCalendarBinding(
                    id: "target-calendar",
                    connectionID: connection.id,
                    providerCalendarID: "provider-target",
                    displayLabel: "Synthetic target",
                    isSelected: false,
                    isReadOnly: false
                ),
            ]
        )
        arm = StoredArm(
            id: "synthetic-arm",
            configurationID: connection.configurationID,
            sourceBindingIDs: ["source-calendar"],
            targetBindingID: "target-calendar",
            ruleMode: .busy
        )
        try repository.saveArm(arm)
    }
}

private func lifecyclePayload(startsAt: TimeInterval = 2_000) -> DesiredEventPayload {
    DesiredEventPayload(
        startsAt: Date(timeIntervalSince1970: startsAt),
        endsAt: Date(timeIntervalSince1970: startsAt + 600),
        isAllDay: false,
        availability: "busy",
        title: "Busy",
        isPrivate: nil
    )
}

private func lifecyclePlanItem(
    id: String,
    action: SyncPlanAction,
    reason: SyncPlanReason? = nil,
    payload: DesiredEventPayload? = lifecyclePayload()
) -> SyncPlanItem {
    let sourceKey = "source-\(id)"
    let mirror = SyncPlanner.mirrorKey(armID: "synthetic-arm", sourceKeyHash: sourceKey)
    return SyncPlanItem(
        id: "operation-\(id)-\(action.rawValue)",
        armID: "synthetic-arm",
        mirrorKey: mirror,
        sourceKeyHash: sourceKey,
        action: action,
        reason: reason ?? {
            switch action {
            case .create: .targetMissing
            case .update: .targetDiffers
            case .remove: .sourceMissing
            case .repair: .ownershipUnverified
            case .noOp: .targetMatches
            }
        }(),
        desiredFingerprint: payload.map {
            SyncPlanner.desiredFingerprint(payload: $0, ruleMode: .busy)
        },
        payload: payload
    )
}

private func lifecycleMapping(id: String) -> StoredMirrorMapping {
    let item = lifecyclePlanItem(id: id, action: .update)
    return StoredMirrorMapping(
        mirrorKey: item.mirrorKey,
        armID: item.armID,
        sourceKeyHash: item.sourceKeyHash!,
        providerEventID: "provider-\(id)",
        providerVersion: "v1",
        desiredFingerprint: "old",
        ownershipKeyID: "synthetic-key",
        updatedAt: Date(timeIntervalSince1970: 1)
    )
}

private func lifecycleObservation(id: String, fingerprint: String?) -> TargetEventObservation {
    let mapping = lifecycleMapping(id: id)
    return TargetEventObservation(
        calendarBindingID: "target-calendar",
        providerEventID: mapping.providerEventID,
        providerVersion: mapping.providerVersion,
        mirrorKey: mapping.mirrorKey,
        contentFingerprint: fingerprint,
        ownershipKeyID: mapping.ownershipKeyID,
        ownershipStatus: .verified
    )
}

private func lifecycleSource(id: String, startsAt: TimeInterval) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: "source-\(id)",
        connectionID: "synthetic-connection",
        calendarBindingID: "source-calendar",
        providerEventID: "provider-source-\(id)",
        recurrenceID: nil,
        startsAt: Date(timeIntervalSince1970: startsAt),
        endsAt: Date(timeIntervalSince1970: startsAt + 600),
        isAllDay: false,
        availability: "busy",
        isCancelled: false,
        isPrivate: false,
        title: "Synthetic source event",
        contentFingerprint: "source-fingerprint-\(id)",
        providerUpdatedAt: nil
    )
}

private actor LifecycleMutationRecorder {
    private(set) var mutations: [ManagedEventMutation] = []

    func record(_ mutation: ManagedEventMutation) {
        mutations.append(mutation)
    }
}

private struct LifecycleSyntheticFailure: Error {}

private actor InterruptedCreateRecorder {
    struct FirstWrite: Sendable {
        let request: ManagedEventWriteRequest
        let result: ManagedEventWriteResult
    }

    private var count = 0
    private(set) var firstWrite: FirstWrite?

    func perform(_ mutation: ManagedEventMutation) throws -> ManagedEventMutationResult {
        count += 1
        guard count == 1, case let .create(request) = mutation else {
            throw LifecycleSyntheticFailure()
        }
        let result = ManagedEventWriteResult(
            providerEventID: "provider-created-first",
            providerVersion: "v1"
        )
        firstWrite = FirstWrite(request: request, result: result)
        return .written(result)
    }
}

private actor DuplicateConvergenceProvider {
    private var snapshots: [ManagedEventSnapshot] = []
    private(set) var readCount = 0

    var snapshotCount: Int { snapshots.count }

    func readSnapshots() -> [ManagedEventSnapshot] {
        readCount += 1
        return snapshots
    }

    func perform(_ mutation: ManagedEventMutation) throws -> ManagedEventMutationResult {
        switch mutation {
        case let .create(request):
            snapshots = [
                ManagedEventSnapshot(
                    providerEventID: "provider-deterministic",
                    providerVersion: "deterministic-v1",
                    payload: request.payload,
                    markerStatus: .parsed,
                    provenance: request.provenance,
                    createdAt: Date(timeIntervalSince1970: 2),
                    isProviderPreferredIdentity: true
                ),
                ManagedEventSnapshot(
                    providerEventID: "provider-duplicate",
                    providerVersion: "duplicate-v1",
                    payload: request.payload,
                    markerStatus: .parsed,
                    provenance: request.provenance,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
            ]
            return .written(
                ManagedEventWriteResult(
                    providerEventID: "provider-duplicate",
                    providerVersion: "duplicate-v1"
                )
            )
        case let .update(providerEventID, _, request):
            guard let index = snapshots.firstIndex(where: {
                $0.providerEventID == providerEventID
            }) else {
                throw LifecycleSyntheticFailure()
            }
            let existing = snapshots[index]
            snapshots[index] = ManagedEventSnapshot(
                providerEventID: existing.providerEventID,
                providerVersion: "survivor-v2",
                payload: request.payload,
                markerStatus: .parsed,
                provenance: request.provenance,
                createdAt: existing.createdAt,
                isProviderPreferredIdentity: existing.isProviderPreferredIdentity
            )
            return .written(
                ManagedEventWriteResult(
                    providerEventID: providerEventID,
                    providerVersion: "survivor-v2"
                )
            )
        case let .delete(providerEventID, _):
            snapshots.removeAll { $0.providerEventID == providerEventID }
            return .deleted
        }
    }
}

private final class LifecycleMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretReference: Data] = [:]

    func save(_ value: Data, for reference: SecretReference) throws {
        lock.withLock { values[reference] = value }
    }

    func value(for reference: SecretReference) throws -> Data? {
        lock.withLock { values[reference] }
    }

    func removeValue(for reference: SecretReference) throws {
        lock.withLock { _ = values.removeValue(forKey: reference) }
    }
}
