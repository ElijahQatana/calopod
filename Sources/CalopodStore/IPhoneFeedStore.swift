import Foundation
import GRDB

/// The iPhone feed setting and how the last upload went. Kept in the shared state database so the
/// app and the command line see the same thing.
public struct StoredIPhoneFeed: Equatable, Sendable {
    public var isEnabled = false
    /// Turned off, but the uploaded copy has not been deleted yet. The app does that when it next runs.
    public var removePending = false
    /// The sync run the last upload was built from.
    public var publishedRunID: String?
    public var publishedAt: Date?
    public var failedAt: Date?
    public var failure: String?

    public init() {}
}

extension LocalStateRepository {
    public func iPhoneFeed() throws -> StoredIPhoneFeed {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM iphone_feed WHERE id = 1") else {
                return StoredIPhoneFeed()
            }
            var feed = StoredIPhoneFeed()
            feed.isEnabled = row["is_enabled"]
            feed.removePending = row["remove_pending"]
            feed.publishedRunID = row["published_run_id"]
            feed.publishedAt = row["published_at"]
            feed.failedAt = row["failed_at"]
            feed.failure = row["failure"]
            return feed
        }
    }

    /// Turning it on forgets the earlier upload, so the next sync publishes from scratch. Turning it
    /// off marks an uploaded copy for removal.
    public func setIPhoneFeedEnabled(_ enabled: Bool) throws {
        try database.write { db in
            let row = try Row.fetchOne(db, sql: "SELECT is_enabled, published_at FROM iphone_feed WHERE id = 1")
            let was: Bool = row?["is_enabled"] ?? false
            if enabled == was, row != nil { return }
            // Only something that was uploaded needs deleting.
            let uploaded = was && (row?["published_at"] as Date?) != nil
            try db.execute(sql: """
                INSERT INTO iphone_feed (id, is_enabled, remove_pending) VALUES (1, ?1, ?2)
                ON CONFLICT(id) DO UPDATE SET
                    is_enabled = ?1, remove_pending = ?2, published_run_id = NULL, published_at = NULL,
                    failed_at = NULL, failure = NULL
                """, arguments: [enabled, !enabled && uploaded])
        }
    }

    public func recordIPhoneFeedPublished(runID: String?, at date: Date) throws {
        try database.write { db in
            try db.execute(sql: """
                UPDATE iphone_feed SET published_run_id = ?, published_at = ?, failed_at = NULL, failure = NULL
                WHERE id = 1 AND is_enabled = 1
                """, arguments: [runID ?? "", date])
        }
    }

    public func recordIPhoneFeedFailure(_ message: String, at date: Date) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE iphone_feed SET failed_at = ?, failure = ? WHERE id = 1", arguments: [date, message])
        }
    }

    /// The remote copy is gone.
    public func recordIPhoneFeedRemoved() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE iphone_feed SET remove_pending = 0, failed_at = NULL, failure = NULL WHERE id = 1")
        }
    }
}
