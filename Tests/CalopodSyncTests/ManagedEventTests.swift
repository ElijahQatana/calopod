import CalopodDomain
import CalopodProviders
import CalopodStore
import CalopodSync
import Foundation
import Testing

@Suite("Managed event ownership")
struct ManagedEventOwnershipTests {
    @Test("Signed provenance survives EventKit URL encoding and rejects changes")
    func signedMarker() throws {
        let key = OwnershipKeyMaterial(
            id: "synthetic-key",
            bytes: Data(repeating: 7, count: 32)
        )
        let marker = try OwnershipMarkerCodec.sign(
            configurationID: "synthetic-configuration",
            armID: "synthetic-arm",
            mirrorKey: "synthetic-mirror",
            sourceKeyHash: "synthetic-source",
            ruleMode: .busy,
            key: key
        )
        let decoded = try OwnershipMarkerCodec.marker(
            from: OwnershipMarkerCodec.markerURL(marker)
        )

        try OwnershipMarkerCodec.verify(decoded, key: key)
        #expect(decoded == marker)
        #expect(marker.schemaVersion == 1)
        #expect(marker.authenticationTag == "6s5Y92qncxvb2RSURs5QvHJmlSiU6wThsC_jVVr5hwA")

        let changed = ManagedEventProvenance(
            configurationID: marker.configurationID,
            armID: marker.armID,
            mirrorKey: marker.mirrorKey,
            sourceKeyHash: marker.sourceKeyHash,
            ruleMode: .fullDetails,
            ownershipKeyID: marker.ownershipKeyID,
            authenticationTag: marker.authenticationTag
        )
        #expect(throws: OwnershipMarkerError.signatureMismatch) {
            try OwnershipMarkerCodec.verify(changed, key: key)
        }
    }

    @Test("Versioned EventKit markers sign the target binding")
    func targetBoundMarker() throws {
        let key = OwnershipKeyMaterial(id: "synthetic-key", bytes: Data(repeating: 7, count: 32))
        let marker = try OwnershipMarkerCodec.sign(
            configurationID: "synthetic-configuration", armID: "synthetic-arm",
            mirrorKey: "synthetic-mirror", sourceKeyHash: "synthetic-source",
            ruleMode: .busy, key: key, targetBindingID: "synthetic-target"
        )
        let url = try OwnershipMarkerCodec.markerURL(marker)
        #expect(url.pathComponents[1] == "v2")
        let decoded = try OwnershipMarkerCodec.marker(from: url)
        #expect(decoded == marker)
        try OwnershipMarkerCodec.verify(decoded, key: key)
        let changed = ManagedEventProvenance(
            schemaVersion: marker.schemaVersion, configurationID: marker.configurationID,
            armID: marker.armID, mirrorKey: marker.mirrorKey, sourceKeyHash: marker.sourceKeyHash,
            ruleMode: marker.ruleMode, ownershipKeyID: marker.ownershipKeyID,
            authenticationTag: marker.authenticationTag, targetBindingID: "other-target"
        )
        #expect(throws: OwnershipMarkerError.signatureMismatch) {
            try OwnershipMarkerCodec.verify(changed, key: key)
        }
    }

    @Test("Ownership keys persist outside SQLite")
    func ownershipKeyVault() throws {
        let secrets = ManagedEventMemorySecretStore()
        let vault = OwnershipKeyVault(secretStore: secrets)

        let first = try vault.loadOrCreate(configurationID: "synthetic-configuration")
        let second = try vault.loadOrCreate(configurationID: "synthetic-configuration")

        #expect(first == second)
        #expect(first.bytes.count == 32)
    }

    @Test("A successful create stores recoverable provider identity and signed provenance")
    func createService() async throws {
        let database = try CalopodDatabase.inMemory()
        let repository = LocalStateRepository(database: database)
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
                    id: "source",
                    connectionID: connection.id,
                    providerCalendarID: "provider-source",
                    displayLabel: "Synthetic source",
                    isSelected: true,
                    isReadOnly: false
                ),
                StoredCalendarBinding(
                    id: "target",
                    connectionID: connection.id,
                    providerCalendarID: "provider-target",
                    displayLabel: "Synthetic target",
                    isSelected: false,
                    isReadOnly: false
                ),
            ]
        )
        let arm = StoredArm(
            id: "synthetic-arm",
            configurationID: connection.configurationID,
            sourceBindingIDs: ["source"],
            targetBindingID: "target",
            ruleMode: .busy
        )
        try repository.saveArm(arm)
        let start = Date(timeIntervalSince1970: 1_000)
        let window = try SyncWindow(start: start, end: start.addingTimeInterval(3_600))
        let source = StoredNormalizedInstance(
            sourceKeyHash: "synthetic-source-key",
            connectionID: connection.id,
            calendarBindingID: "source",
            providerEventID: "provider-source-event",
            recurrenceID: nil,
            startsAt: start.addingTimeInterval(600),
            endsAt: start.addingTimeInterval(1_200),
            isAllDay: false,
            availability: "busy",
            isCancelled: false,
            isPrivate: true,
            title: "Synthetic confidential session",
            contentFingerprint: "source-fingerprint",
            providerUpdatedAt: nil
        )
        let item = try #require(
            SyncPlanner.plan(
                arm: arm,
                sources: [source],
                mappings: [],
                targetEvents: [],
                window: window,
                sourceSnapshotComplete: true
            ).items.first
        )
        let secrets = ManagedEventMemorySecretStore()
        let recorder = ManagedRequestRecorder()
        let service = ManagedEventCreateService(repository: repository, secretStore: secrets)

        let mapping = try await service.applyCreate(
            item,
            arm: arm,
            now: Date(timeIntervalSince1970: 2_000)
        ) { request in
            await recorder.record(request)
            return ManagedEventWriteResult(
                providerEventID: "provider-created",
                providerVersion: "provider-version"
            )
        }
        let request = try #require(await recorder.request)
        let key = try OwnershipKeyVault(secretStore: secrets).loadOrCreate(
            configurationID: arm.configurationID
        )

        try OwnershipMarkerCodec.verify(request.provenance, key: key)
        #expect(request.provenance.schemaVersion == 2)
        #expect(request.provenance.targetBindingID == arm.targetBindingID)
        #expect(request.payload.title == "Busy")
        #expect(request.payload.isPrivate == nil)
        #expect(mapping.providerEventID == "provider-created")
        #expect(mapping.providerVersion == "provider-version")
        #expect(try repository.mirrorMappings(armID: arm.id) == [mapping])
    }
}

private actor ManagedRequestRecorder {
    private(set) var request: ManagedEventWriteRequest?

    func record(_ request: ManagedEventWriteRequest) {
        self.request = request
    }
}

private final class ManagedEventMemorySecretStore: SecretStore, @unchecked Sendable {
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
