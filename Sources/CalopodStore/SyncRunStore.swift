import Foundation
import GRDB

public struct StoredSyncRun: Equatable, Sendable {
    public let id: String
    public let mode: String
    public let trigger: String
    public let status: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let errorCode: String?
    public let plannedCount: Int
    public let appliedCount: Int
    public let reconciledCount: Int
    public let noOpCount: Int
    public let warningCount: Int
}

extension LocalStateRepository {
    @discardableResult
    public func beginSyncRun(
        mode: String,
        trigger: String,
        id: String = UUID().uuidString.lowercased(),
        now: Date = Date()
    ) throws -> String {
        try database.writeTransaction { database in
            try pruneSyncHistory(database, now: now)
            try database.execute(
                sql: """
                    UPDATE sync_runs
                    SET status = 'interrupted', finished_at = ?, error_code = 'interrupted'
                    WHERE status = 'running'
                    """,
                arguments: [now]
            )
            try database.execute(
                sql: """
                    INSERT INTO sync_runs
                        (id, mode, trigger, status, started_at)
                    VALUES (?, ?, ?, 'running', ?)
                    """,
                arguments: [id, mode, trigger, now]
            )
        }
        return id
    }

    public func finishSyncRun(
        id: String,
        status: String,
        errorCode: String? = nil,
        plannedCount: Int = 0,
        appliedCount: Int = 0,
        reconciledCount: Int = 0,
        noOpCount: Int = 0,
        warningCount: Int = 0,
        now: Date = Date()
    ) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    UPDATE sync_runs
                    SET status = ?, finished_at = ?, error_code = ?,
                        planned_count = ?, applied_count = ?, reconciled_count = ?,
                        no_op_count = ?, warning_count = ?
                    WHERE id = ?
                    """,
                arguments: [
                    status,
                    now,
                    errorCode,
                    plannedCount,
                    appliedCount,
                    reconciledCount,
                    noOpCount,
                    warningCount,
                    id,
                ]
            )
        }
    }

    public func latestSyncRun(trigger: String? = nil) throws -> StoredSyncRun? {
        try database.read { database in
            let row: Row?
            if let trigger {
                row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT * FROM sync_runs
                        WHERE trigger = ?
                        ORDER BY started_at DESC, id DESC
                        LIMIT 1
                        """,
                    arguments: [trigger]
                )
            } else {
                row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT * FROM sync_runs
                        ORDER BY started_at DESC, id DESC
                        LIMIT 1
                        """
                )
            }
            return row.map(Self.storedSyncRun)
        }
    }

    public func latestSuccessfulSyncRun(trigger: String? = nil) throws -> StoredSyncRun? {
        try database.read { database in
            let row: Row?
            if let trigger {
                row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT * FROM sync_runs
                        WHERE trigger = ? AND status = 'succeeded'
                        ORDER BY started_at DESC, id DESC
                        LIMIT 1
                        """,
                    arguments: [trigger]
                )
            } else {
                row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT * FROM sync_runs
                        WHERE status = 'succeeded'
                        ORDER BY started_at DESC, id DESC
                        LIMIT 1
                        """
                )
            }
            return row.map(Self.storedSyncRun)
        }
    }

    /// The latest finished runs of one mode, newest first.
    public func recentSyncRuns(mode: String = "apply", limit: Int) throws -> [StoredSyncRun] {
        try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM sync_runs
                    WHERE mode = ? AND status != 'running'
                    ORDER BY started_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: [mode, limit]
            ).map(Self.storedSyncRun)
        }
    }

    private static func storedSyncRun(_ row: Row) -> StoredSyncRun {
        StoredSyncRun(
            id: row["id"],
            mode: row["mode"],
            trigger: row["trigger"],
            status: row["status"],
            startedAt: row["started_at"],
            finishedAt: row["finished_at"],
            errorCode: row["error_code"],
            plannedCount: row["planned_count"],
            appliedCount: row["applied_count"],
            reconciledCount: row["reconciled_count"],
            noOpCount: row["no_op_count"],
            warningCount: row["warning_count"]
        )
    }
}
