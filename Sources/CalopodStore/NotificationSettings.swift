import Foundation
import GRDB

public enum NotificationSettingsError: Error, Equatable, LocalizedError {
    case minutesOutOfRange
    case finalNotEarlier

    public var errorDescription: String? {
        switch self {
        case .minutesOutOfRange: "Reminder times must be between 1 and 120 minutes."
        case .finalNotEarlier: NotificationSettings.orderExplanation
        }
    }
}

/// Meeting reminders, kept in the local state so the Mac app and the command line share one copy.
/// Two reminders per event, each with its own switch and lead time.
public struct NotificationSettings: Equatable, Sendable {
    public static let minutes = 1...120
    public static let orderExplanation =
        "The final reminder has to come after the first one, so its time must be fewer minutes before the start."

    public let enabled: Bool
    public let firstEnabled: Bool
    public let firstMinutes: Int
    public let finalEnabled: Bool
    public let finalMinutes: Int
    public let hideTitles: Bool

    /// Throws for minutes outside 1 to 120, and when both reminders are on and the final is not
    /// closer to the start than the first. With one reminder off the order does not matter.
    public init(
        enabled: Bool = true, firstEnabled: Bool = true, firstMinutes: Int = 10,
        finalEnabled: Bool = true, finalMinutes: Int = 1, hideTitles: Bool = false
    ) throws {
        guard Self.minutes.contains(firstMinutes), Self.minutes.contains(finalMinutes) else {
            throw NotificationSettingsError.minutesOutOfRange
        }
        guard !(firstEnabled && finalEnabled) || finalMinutes < firstMinutes else {
            throw NotificationSettingsError.finalNotEarlier
        }
        self.enabled = enabled
        self.firstEnabled = firstEnabled
        self.firstMinutes = firstMinutes
        self.finalEnabled = finalEnabled
        self.finalMinutes = finalMinutes
        self.hideTitles = hideTitles
    }

    public static let standard = try! NotificationSettings()

    /// A copy with some values changed, checked the same way.
    public func changing(
        enabled: Bool? = nil, firstEnabled: Bool? = nil, firstMinutes: Int? = nil,
        finalEnabled: Bool? = nil, finalMinutes: Int? = nil, hideTitles: Bool? = nil
    ) throws -> NotificationSettings {
        try NotificationSettings(
            enabled: enabled ?? self.enabled, firstEnabled: firstEnabled ?? self.firstEnabled,
            firstMinutes: firstMinutes ?? self.firstMinutes, finalEnabled: finalEnabled ?? self.finalEnabled,
            finalMinutes: finalMinutes ?? self.finalMinutes, hideTitles: hideTitles ?? self.hideTitles)
    }

    /// The lead times of the reminders that are on, soonest to the start last.
    public var leads: [(kind: Kind, minutes: Int)] {
        guard enabled else { return [] }
        return (firstEnabled ? [(.first, firstMinutes)] : []) + (finalEnabled ? [(.final, finalMinutes)] : [])
    }

    public enum Kind: String, Sendable { case first, final }
}

extension LocalStateRepository {
    /// The saved settings, or the defaults when nothing was saved or the saved row cannot be used.
    public func notificationSettings() throws -> NotificationSettings {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT enabled, first_enabled, first_minutes, final_enabled, final_minutes, hide_titles
                FROM notification_settings WHERE id = 1
                """) else { return .standard }
            return (try? NotificationSettings(
                enabled: row["enabled"], firstEnabled: row["first_enabled"], firstMinutes: row["first_minutes"],
                finalEnabled: row["final_enabled"], finalMinutes: row["final_minutes"], hideTitles: row["hide_titles"]))
                ?? .standard
        }
    }

    public func saveNotificationSettings(_ settings: NotificationSettings) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO notification_settings
                    (id, enabled, first_enabled, first_minutes, final_enabled, final_minutes, hide_titles)
                VALUES (1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled, first_enabled = excluded.first_enabled,
                    first_minutes = excluded.first_minutes, final_enabled = excluded.final_enabled,
                    final_minutes = excluded.final_minutes, hide_titles = excluded.hide_titles
                """, arguments: [
                    settings.enabled, settings.firstEnabled, settings.firstMinutes,
                    settings.finalEnabled, settings.finalMinutes, settings.hideTitles,
                ])
        }
    }
}
