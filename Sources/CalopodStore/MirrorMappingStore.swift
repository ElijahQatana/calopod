import Foundation
import GRDB

public struct StoredMirrorMapping: Equatable, Sendable {
    public let mirrorKey: String
    public let armID: String
    public let sourceKeyHash: String
    public let providerEventID: String
    public let providerVersion: String?
    public let desiredFingerprint: String
    public let ownershipKeyID: String
    public let updatedAt: Date

    public init(
        mirrorKey: String,
        armID: String,
        sourceKeyHash: String,
        providerEventID: String,
        providerVersion: String?,
        desiredFingerprint: String,
        ownershipKeyID: String,
        updatedAt: Date
    ) {
        self.mirrorKey = mirrorKey
        self.armID = armID
        self.sourceKeyHash = sourceKeyHash
        self.providerEventID = providerEventID
        self.providerVersion = providerVersion
        self.desiredFingerprint = desiredFingerprint
        self.ownershipKeyID = ownershipKeyID
        self.updatedAt = updatedAt
    }
}

extension LocalStateRepository {
    public func saveMirrorMapping(_ mapping: StoredMirrorMapping) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO mirror_mappings
                        (mirror_key, arm_id, source_key_hash, provider_event_id,
                         provider_version, desired_fingerprint, ownership_key_id, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(mirror_key) DO UPDATE SET
                        arm_id = excluded.arm_id,
                        source_key_hash = excluded.source_key_hash,
                        provider_event_id = excluded.provider_event_id,
                        provider_version = excluded.provider_version,
                        desired_fingerprint = excluded.desired_fingerprint,
                        ownership_key_id = excluded.ownership_key_id,
                        updated_at = excluded.updated_at
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
                           provider_version, desired_fingerprint, ownership_key_id, updated_at
                    FROM mirror_mappings
                    WHERE arm_id = ?
                    ORDER BY mirror_key
                    """,
                arguments: [armID]
            ).map(storedMirrorMapping)
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
        updatedAt: row["updated_at"]
    )
}
