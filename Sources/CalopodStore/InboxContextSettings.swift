import Foundation
import GRDB

public enum InboxContextSettingsError: Error, Equatable {
    case invalidMargin
}

/// Local display margins, independent of conflict detection and sync coverage.
public struct InboxContextSettings: Equatable, Sendable {
    public let beforeMinutes: Int
    public let afterMinutes: Int

    public init(beforeMinutes: Int = 90, afterMinutes: Int = 90) throws {
        guard (0...10_080).contains(beforeMinutes), (0...10_080).contains(afterMinutes),
              beforeMinutes + afterMinutes > 0 else { throw InboxContextSettingsError.invalidMargin }
        self.beforeMinutes = beforeMinutes
        self.afterMinutes = afterMinutes
    }

    /// Overrides affect one review session; saving remains a separate operation.
    public func overriding(beforeMinutes: Int? = nil, afterMinutes: Int? = nil) throws -> Self {
        try Self(beforeMinutes: beforeMinutes ?? self.beforeMinutes, afterMinutes: afterMinutes ?? self.afterMinutes)
    }
}

extension LocalStateRepository {
    public func inboxContextSettings() throws -> InboxContextSettings {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT before_minutes, after_minutes FROM inbox_context_settings WHERE id = 1") else {
                return try InboxContextSettings()
            }
            return try InboxContextSettings(beforeMinutes: row["before_minutes"], afterMinutes: row["after_minutes"])
        }
    }

    public func saveInboxContextSettings(_ settings: InboxContextSettings) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_context_settings (id, before_minutes, after_minutes) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET before_minutes = excluded.before_minutes, after_minutes = excluded.after_minutes
                """, arguments: [settings.beforeMinutes, settings.afterMinutes])
        }
    }
}
