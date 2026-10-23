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

    /// The remote copy is gone, including any busy-only copy.
    public func recordIPhoneFeedRemoved() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE iphone_feed SET remove_pending = 0, failed_at = NULL, failure = NULL WHERE id = 1")
            try db.execute(sql: "UPDATE iphone_feed_zone SET busy_shared = 0 WHERE id = 1")
        }
    }
}

/// What names this Mac's iCloud zones. Made once.
extension LocalStateRepository {
    public struct IPhoneFeedZone: Equatable, Sendable {
        public var macID: String
        public var busyShared: Bool
        public var legacyRemoved: Bool
    }

    public func iPhoneFeedZone(proposedID: String = UUID().uuidString.lowercased()) throws -> IPhoneFeedZone {
        try database.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO iphone_feed_zone (id, mac_id) VALUES (1, ?)", arguments: [proposedID])
            let row = try Row.fetchOne(db, sql: "SELECT mac_id, busy_shared, legacy_removed FROM iphone_feed_zone WHERE id = 1")!
            return IPhoneFeedZone(macID: row["mac_id"], busyShared: row["busy_shared"], legacyRemoved: row["legacy_removed"])
        }
    }

    /// Turning it on makes the next run publish the busy-only copy.
    public func setIPhoneFeedBusyShared(_ on: Bool) throws {
        _ = try iPhoneFeedZone()
        try database.write { db in
            try db.execute(sql: "UPDATE iphone_feed_zone SET busy_shared = ? WHERE id = 1", arguments: [on])
            if on { try db.execute(sql: "UPDATE iphone_feed SET published_run_id = NULL WHERE id = 1") }
        }
    }

    public func recordIPhoneFeedLegacyRemoved() throws {
        _ = try iPhoneFeedZone()
        try database.write { db in try db.execute(sql: "UPDATE iphone_feed_zone SET legacy_removed = 1 WHERE id = 1") }
    }
}

extension LocalStateRepository {
    /// The calendars whose events the iPhone gets. None until someone chooses.
    public func iPhoneCalendarIDs() throws -> Set<String> {
        try database.read { Set(try String.fetchAll($0, sql: "SELECT calendar_id FROM iphone_calendars")) }
    }

    /// Changing the choice makes the next sync publish again, so removed events leave iCloud. The
    /// upload time stays, because something is still there to delete if the feed is turned off.
    public func setIPhoneCalendar(_ calendarID: String, chosen: Bool) throws {
        try database.write { db in
            if chosen {
                try db.execute(sql: "INSERT OR IGNORE INTO iphone_calendars (calendar_id) VALUES (?)", arguments: [calendarID])
            } else {
                try db.execute(sql: "DELETE FROM iphone_calendars WHERE calendar_id = ?", arguments: [calendarID])
            }
            if db.changesCount > 0 {
                try db.execute(sql: "UPDATE iphone_feed SET published_run_id = NULL WHERE id = 1")
            }
        }
    }
}
