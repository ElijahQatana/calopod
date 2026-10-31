import Foundation
import GRDB

/// How an Arm's syncs have gone. Holds a failure category, never provider text.
public struct StoredArmSyncHealth: Equatable, Sendable {
    public let armID: String
    public let lastSuccessAt: Date?
    public let lastError: String?
    /// Changes the latest plan left to make. Nil when it is not known.
    public let waiting: Int?

    public init(armID: String, lastSuccessAt: Date?, lastError: String?, waiting: Int?) {
        self.armID = armID
        self.lastSuccessAt = lastSuccessAt
        self.lastError = lastError
        self.waiting = waiting
    }
}

extension LocalStateRepository {
    /// Records a run for one Arm. A nil `succeededAt` keeps the earlier success.
    public func recordArmSync(armID: String, succeededAt: Date?, error: String?, waiting: Int?) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO arm_sync_health (arm_id, last_success_at, last_error, waiting)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(arm_id) DO UPDATE SET
                        last_success_at = COALESCE(excluded.last_success_at, last_success_at),
                        last_error = excluded.last_error,
                        waiting = excluded.waiting
                    """,
                arguments: [armID, succeededAt, error, waiting]
            )
        }
    }

    /// A preview only learns what is waiting, so the Arm's history stays as it was.
    public func recordArmWaiting(armID: String, waiting: Int) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO arm_sync_health (arm_id, waiting) VALUES (?, ?)
                    ON CONFLICT(arm_id) DO UPDATE SET waiting = excluded.waiting
                    """,
                arguments: [armID, waiting]
            )
        }
    }

    public func armSyncHealth(armID: String) throws -> StoredArmSyncHealth? {
        try database.read { database in
            try Row.fetchOne(
                database, sql: "SELECT * FROM arm_sync_health WHERE arm_id = ?", arguments: [armID]
            ).map(Self.storedArmSyncHealth)
        }
    }

    public func armSyncHealths() throws -> [String: StoredArmSyncHealth] {
        try database.read { database in
            Dictionary(
                uniqueKeysWithValues: try Row.fetchAll(database, sql: "SELECT * FROM arm_sync_health")
                    .map { ($0["arm_id"], Self.storedArmSyncHealth($0)) })
        }
    }

    private static func storedArmSyncHealth(_ row: Row) -> StoredArmSyncHealth {
        StoredArmSyncHealth(
            armID: row["arm_id"], lastSuccessAt: row["last_success_at"],
            lastError: row["last_error"], waiting: row["waiting"])
    }
}
