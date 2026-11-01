import Foundation
import GRDB

public enum InboxDigestSettingsError: Error, Equatable, LocalizedError {
    case minuteOutOfRange

    public var errorDescription: String? { "The digest time must be within one day." }
}

/// The daily Inbox digest, kept in the local state so the Mac app and the command line share one copy.
public struct InboxDigestSettings: Equatable, Sendable {
    /// Used when no working day is set and no time was chosen.
    public static let fallbackMinute = 9 * 60

    public let enabled: Bool
    /// Minutes after midnight, or nil to follow the start of the working day.
    public let minute: Int?

    public init(enabled: Bool = false, minute: Int? = nil) throws {
        if let minute, !(0..<1440).contains(minute) { throw InboxDigestSettingsError.minuteOutOfRange }
        self.enabled = enabled
        self.minute = minute
    }

    public static let standard = try! InboxDigestSettings()

    /// The chosen time, else the earliest start among the working days.
    public func minute(workingHours: WorkingHours) -> Int {
        minute ?? workingHours.days.values.map(\.startMinute).min() ?? Self.fallbackMinute
    }
}

extension LocalStateRepository {
    /// The saved digest settings, or off when nothing was saved or the saved row cannot be used.
    public func inboxDigestSettings() throws -> InboxDigestSettings {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT enabled, minute FROM inbox_digest_settings WHERE id = 1")
            else { return .standard }
            return (try? InboxDigestSettings(enabled: row["enabled"], minute: row["minute"])) ?? .standard
        }
    }

    public func saveInboxDigestSettings(_ settings: InboxDigestSettings) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO inbox_digest_settings (id, enabled, minute) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled, minute = excluded.minute
                """, arguments: [settings.enabled, settings.minute])
        }
    }
}
