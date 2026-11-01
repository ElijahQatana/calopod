import Foundation
import GRDB

/// An Inbox item put away until `until`. Only this Mac knows; nothing goes to a calendar.
public struct InboxSnooze: Codable, Equatable, Sendable {
    public let sourceKeyHash: String
    public let until: Date
    /// The revision the person saw. A newer one brings the item back.
    public let revision: Int64
    /// The events it overlapped. An overlap with any other event brings it back.
    public let conflictKeys: Set<String>

    public init(sourceKeyHash: String, until: Date, revision: Int64, conflictKeys: Set<String>) {
        self.sourceKeyHash = sourceKeyHash
        self.until = until
        self.revision = revision
        self.conflictKeys = conflictKeys
    }

    /// False once it is due, the event has started, or the event has changed or gained an overlap.
    public func isActive(revision latest: Int64?, conflictKeys overlaps: Set<String>, startsAt: Date, now: Date) -> Bool {
        until > now && startsAt > now && (latest ?? 0) <= revision && overlaps.isSubset(of: conflictKeys)
    }
}

extension LocalStateRepository {
    public func inboxSnoozes() throws -> [String: InboxSnooze] {
        try database.read { try loadInboxSnoozes($0) }
    }

    public func snoozeInboxItem(_ snooze: InboxSnooze, now: Date = Date()) throws {
        let keys = String(decoding: try JSONEncoder().encode(snooze.conflictKeys.sorted()), as: UTF8.self)
        try database.write { db in
            try db.execute(sql: "DELETE FROM inbox_snoozes WHERE until <= ?", arguments: [now])
            try db.execute(sql: """
                INSERT INTO inbox_snoozes (source_key_hash, until, revision, conflict_keys) VALUES (?, ?, ?, ?)
                ON CONFLICT(source_key_hash) DO UPDATE SET until = excluded.until, revision = excluded.revision,
                    conflict_keys = excluded.conflict_keys
                """, arguments: [snooze.sourceKeyHash, snooze.until, snooze.revision, keys])
        }
    }

    public func unsnoozeInboxItem(sourceKeyHash: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM inbox_snoozes WHERE source_key_hash = ?", arguments: [sourceKeyHash])
        }
    }
}

func loadInboxSnoozes(_ db: Database) throws -> [String: InboxSnooze] {
    Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT * FROM inbox_snoozes").map { row in
        let keys = (try? JSONDecoder().decode([String].self, from: Data((row["conflict_keys"] as String).utf8))) ?? []
        let key: String = row["source_key_hash"]
        return (key, InboxSnooze(sourceKeyHash: key, until: row["until"], revision: row["revision"], conflictKeys: Set(keys)))
    })
}
