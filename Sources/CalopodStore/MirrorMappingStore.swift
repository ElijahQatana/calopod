import Foundation
import GRDB

/// The stored link from a mirror key to the target event that represents it.
public struct StoredMirrorMapping: Equatable, Sendable {
    public let mirrorKey: String
    public let armID: String
    public let sourceKeyHash: String
    public let providerEventID: String
    public let providerVersion: String?
    public let desiredFingerprint: String
    public let ownershipKeyID: String
    public let updatedAt: Date
    /// The provider's server-assigned id for the copy. Unlike `providerEventID` it survives the
    /// calendar's own sync, so it recognizes the copy after the event id changes.
    public let providerExternalID: String?

    public init(
        mirrorKey: String,
        armID: String,
        sourceKeyHash: String,
        providerEventID: String,
        providerVersion: String?,
        desiredFingerprint: String,
        ownershipKeyID: String,
        updatedAt: Date,
        providerExternalID: String? = nil
    ) {
        self.mirrorKey = mirrorKey
        self.armID = armID
        self.sourceKeyHash = sourceKeyHash
        self.providerEventID = providerEventID
        self.providerVersion = providerVersion
        self.desiredFingerprint = desiredFingerprint
        self.ownershipKeyID = ownershipKeyID
        self.updatedAt = updatedAt
        self.providerExternalID = providerExternalID
    }
}

extension LocalStateRepository {
    // Upsert by mirror_key in one statement so concurrent saves can't race into a duplicate row.
    public func saveMirrorMapping(_ mapping: StoredMirrorMapping) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO mirror_mappings
                        (mirror_key, arm_id, source_key_hash, provider_event_id,
                         provider_version, desired_fingerprint, ownership_key_id, updated_at,
                         provider_external_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(mirror_key) DO UPDATE SET
                        arm_id = excluded.arm_id,
                        source_key_hash = excluded.source_key_hash,
                        provider_event_id = excluded.provider_event_id,
                        provider_version = excluded.provider_version,
                        desired_fingerprint = excluded.desired_fingerprint,
                        ownership_key_id = excluded.ownership_key_id,
                        updated_at = excluded.updated_at,
                        provider_external_id = excluded.provider_external_id
                    """,
                arguments: [
                    mapping.mirrorKey,
                    mapping.armID,
                    mapping.sourceKeyHash,
                    mapping.providerEventID,
                    mapping.providerVersion,
                    mapping.desiredFingerprint,
                    mapping.ownershipKeyID,
                    mapping.updatedAt,
                    mapping.providerExternalID,
                ]
            )
        }
    }

    public func mirrorMappings(armID: String) throws -> [StoredMirrorMapping] {
        try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT mirror_key, arm_id, source_key_hash, provider_event_id,
                           provider_version, desired_fingerprint, ownership_key_id, updated_at,
                           provider_external_id
                    FROM mirror_mappings
                    WHERE arm_id = ?
                    ORDER BY mirror_key
                    """,
                arguments: [armID]
            ).map(storedMirrorMapping)
        }
    }

    /// Known target copies stay excluded from ingestion even when another
    /// calendar client removes their ownership marker. This does not grant
    /// permission to mutate them; target ownership still requires verification.
    public func managedTargetEventIDs(calendarBindingID: String) throws -> Set<String> {
        try database.read { database in
            Set(try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT mirror_mappings.provider_event_id
                    FROM mirror_mappings
                    JOIN arms ON arms.id = mirror_mappings.arm_id
                    WHERE arms.target_binding_id = ?
                    """,
                arguments: [calendarBindingID]
            ))
        }
    }

    /// Server ids of known copies on this calendar, for the same exclusion by id.
    public func managedTargetExternalIDs(calendarBindingID: String) throws -> Set<String> {
        try database.read { database in
            Set(try String.fetchAll(
                database,
                sql: """
                    SELECT DISTINCT mirror_mappings.provider_external_id
                    FROM mirror_mappings
                    JOIN arms ON arms.id = mirror_mappings.arm_id
                    WHERE arms.target_binding_id = ? AND mirror_mappings.provider_external_id IS NOT NULL
                    """,
                arguments: [calendarBindingID]
            ))
        }
    }

    public func removeMirrorMapping(mirrorKey: String) throws {
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM mirror_mappings WHERE mirror_key = ?",
                arguments: [mirrorKey]
            )
        }
    }
}

private func storedMirrorMapping(_ row: Row) -> StoredMirrorMapping {
    StoredMirrorMapping(
        mirrorKey: row["mirror_key"],
        armID: row["arm_id"],
        sourceKeyHash: row["source_key_hash"],
        providerEventID: row["provider_event_id"],
        providerVersion: row["provider_version"],
        desiredFingerprint: row["desired_fingerprint"],
        ownershipKeyID: row["ownership_key_id"],
        updatedAt: row["updated_at"],
        providerExternalID: row["provider_external_id"]
    )
}
