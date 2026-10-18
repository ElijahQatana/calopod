import Foundation
import GRDB

/// What someone chose for one calendar on this Mac. Nothing here changes the calendar at the provider.
public struct CalendarPreference: Equatable, Sendable {
    public var alias: String?
    public var isIgnored: Bool
    public var color: String?

    public init(alias: String? = nil, isIgnored: Bool = false, color: String? = nil) {
        self.alias = alias
        self.isIgnored = isIgnored
        self.color = color
    }
}

extension LocalStateRepository {
    public func calendarPreferences() throws -> [String: CalendarPreference] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT calendar_id, alias, is_ignored, color FROM calendar_preferences")
                .reduce(into: [:]) { result, row in
                    result[row["calendar_id"]] = CalendarPreference(
                        alias: row["alias"], isIgnored: (row["is_ignored"] as Int?) == 1, color: row["color"])
                }
        }
    }

    /// An empty or blank alias clears it.
    public func setCalendarAlias(_ alias: String?, calendarID: String) throws {
        let text = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        try setPreference("alias", text?.isEmpty == false ? text : nil, calendarID: calendarID)
    }

    public func setCalendarIgnored(_ ignored: Bool, calendarID: String) throws {
        try setPreference("is_ignored", ignored ? 1 : 0, calendarID: calendarID)
    }

    public func setCalendarColor(_ color: String?, calendarID: String) throws {
        try setPreference("color", color, calendarID: calendarID)
    }

    /// Copies choices an older version kept elsewhere, once. Only fields never chosen are filled, so
    /// nothing already in the database is overwritten. Returns false when the import already ran.
    @discardableResult
    public func importCalendarPreferences(
        aliases: [String: String], ignored: Set<String>, colors: [String: String]
    ) throws -> Bool {
        try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendar_preferences_import") == 0 else { return false }
            try db.execute(sql: "INSERT INTO calendar_preferences_import (id) VALUES (1)")
            for id in Set(aliases.keys).union(ignored).union(colors.keys) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO calendar_preferences (calendar_id, connection_id)
                    VALUES (?1, (SELECT connection_id FROM calendar_bindings WHERE id = ?1))
                    """, arguments: [id])
                if let alias = aliases[id] {
                    try db.execute(sql: "UPDATE calendar_preferences SET alias = ? WHERE calendar_id = ? AND alias IS NULL",
                                   arguments: [alias, id])
                }
                if ignored.contains(id) {
                    try db.execute(sql: "UPDATE calendar_preferences SET is_ignored = 1 WHERE calendar_id = ? AND is_ignored IS NULL",
                                   arguments: [id])
                }
                if let color = colors[id] {
                    try db.execute(sql: "UPDATE calendar_preferences SET color = ? WHERE calendar_id = ? AND color IS NULL",
                                   arguments: [color, id])
                }
            }
            return true
        }
    }

    private func setPreference(_ column: String, _ value: (any DatabaseValueConvertible)?, calendarID: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO calendar_preferences (calendar_id, connection_id, \(column))
                VALUES (?1, (SELECT connection_id FROM calendar_bindings WHERE id = ?1), ?2)
                ON CONFLICT(calendar_id) DO UPDATE SET \(column) = excluded.\(column),
                    connection_id = COALESCE(excluded.connection_id, connection_id)
                """, arguments: [calendarID, value])
        }
    }
}
