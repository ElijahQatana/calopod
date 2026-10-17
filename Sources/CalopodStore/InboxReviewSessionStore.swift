import Foundation
import GRDB

public enum InboxReviewSessionStoreError: Error, Equatable {
    case changed, missing
}

/// The shared review model owns the encoded private snapshot.
public struct StoredInboxReviewSession: Sendable {
    public let id: String
    public let generation: Int64
    public let snapshot: Data
}

public struct InboxReviewSessionUpdate: Sendable {
    public let id: String
    public let expectedGeneration: Int64
    public let snapshot: Data
    public let completed: Bool
    public let hasUnresolvedActions: Bool
    public let updatedAt: Date
    public let connectionIDs: Set<String>

    public init(id: String, expectedGeneration: Int64, snapshot: Data, completed: Bool,
                hasUnresolvedActions: Bool, updatedAt: Date = Date(), connectionIDs: Set<String> = []) {
        self.id = id
        self.expectedGeneration = expectedGeneration
        self.snapshot = snapshot
        self.completed = completed
        self.hasUnresolvedActions = hasUnresolvedActions
        self.updatedAt = updatedAt
        self.connectionIDs = connectionIDs
    }
}

extension LocalStateRepository {
    public func createInboxReviewSession(_ update: InboxReviewSessionUpdate, connectionIDs: Set<String>) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_review_sessions VALUES (?, 0, ?, ?, ?, ?)
                """, arguments: [update.id, update.updatedAt, update.completed, update.hasUnresolvedActions, update.snapshot])
            for id in connectionIDs {
                try db.execute(sql: "INSERT INTO inbox_review_session_connections VALUES (?, ?)", arguments: [update.id, id])
            }
        }
    }

    public func inboxReviewSession(id: String? = nil) throws -> StoredInboxReviewSession? {
        try database.read { db in
            let row: Row?
            if let id {
                row = try Row.fetchOne(db, sql: "SELECT * FROM inbox_review_sessions WHERE id = ?", arguments: [id])
            } else {
                row = try Row.fetchOne(db, sql: """
                    SELECT * FROM inbox_review_sessions WHERE completed = 0 OR has_unresolved_actions = 1
                    ORDER BY has_unresolved_actions DESC, updated_at DESC, id DESC LIMIT 1
                    """)
            }
            return row.map { StoredInboxReviewSession(id: $0["id"], generation: $0["generation"], snapshot: $0["snapshot"]) }
        }
    }

    public func saveInboxReviewSession(_ update: InboxReviewSessionUpdate) throws {
        try database.write { try writeInboxReviewSession($0, update: update) }
    }

    /// Removes a session that has nothing unresolved, such as the one behind a single quick reply.
    public func discardInboxReviewSession(id: String) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM inbox_review_sessions WHERE id = ? AND has_unresolved_actions = 0", arguments: [id])
        }
    }

    /// Keep unfinished and uncertain sessions until explicitly resolved.
    public func pruneInboxReviewSessions(completedBefore cutoff: Date) throws {
        try database.write { db in
            try db.execute(sql: """
                DELETE FROM inbox_review_sessions
                WHERE completed = 1 AND has_unresolved_actions = 0 AND updated_at < ?
                """, arguments: [cutoff])
        }
    }
}

func writeInboxReviewSession(_ db: Database, update: InboxReviewSessionUpdate) throws {
    try db.execute(sql: """
        UPDATE inbox_review_sessions SET generation = generation + 1, updated_at = ?, completed = ?,
            has_unresolved_actions = ?, snapshot = ? WHERE id = ? AND generation = ?
        """, arguments: [update.updatedAt, update.completed, update.hasUnresolvedActions,
                           update.snapshot, update.id, update.expectedGeneration])
    guard db.changesCount == 1 else { throw InboxReviewSessionStoreError.changed }
    for id in update.connectionIDs {
        try db.execute(sql: "INSERT OR IGNORE INTO inbox_review_session_connections VALUES (?, ?)", arguments: [update.id, id])
    }
}
