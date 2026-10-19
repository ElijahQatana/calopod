import CalopodDomain
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

    /// Copies choices an older version kept elsewhere into rows that lack them. A missing, empty or
    /// blank alias or color is filled, and so is a never-chosen ignore flag; a value already there is
    /// never replaced. Safe to repeat. Returns how many values were filled.
    @discardableResult
    public func importCalendarPreferences(
        aliases: [String: String], ignored: Set<String>, colors: [String: String]
    ) throws -> Int {
        try database.write { db in
            var filled = 0
            for id in Set(aliases.keys).union(ignored).union(colors.keys) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO calendar_preferences (calendar_id, connection_id)
                    VALUES (?1, (SELECT connection_id FROM calendar_bindings WHERE id = ?1))
                    """, arguments: [id])
                if let alias = aliases[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
                    try db.execute(sql: """
                        UPDATE calendar_preferences SET alias = ?
                        WHERE calendar_id = ? AND (alias IS NULL OR TRIM(alias) = '')
                        """, arguments: [alias, id])
                    filled += db.changesCount
                }
                if ignored.contains(id) {
                    try db.execute(sql: "UPDATE calendar_preferences SET is_ignored = 1 WHERE calendar_id = ? AND is_ignored IS NULL",
                                   arguments: [id])
                    filled += db.changesCount
                }
                if let color = colors[id], !color.isEmpty {
                    try db.execute(sql: """
                        UPDATE calendar_preferences SET color = ?
                        WHERE calendar_id = ? AND (color IS NULL OR TRIM(color) = '')
                        """, arguments: [color, id])
                    filled += db.changesCount
                }
            }
            return filled
        }
    }

    /// Preference rows for calendars with no binding and no connection, such as ones left by old test
    /// runs. A row for a calendar that exists, or whose connection exists, is never touched. With
    /// `dryRun` nothing is removed. Returns how many rows match.
    @discardableResult
    public func pruneCalendarPreferences(dryRun: Bool = false) throws -> Int {
        try database.write { db in
            let orphaned = """
                FROM calendar_preferences
                WHERE calendar_id NOT IN (SELECT id FROM calendar_bindings)
                  AND (connection_id IS NULL OR connection_id NOT IN (SELECT id FROM connections))
                """
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) " + orphaned) ?? 0
            if !dryRun, count > 0 { try db.execute(sql: "DELETE " + orphaned) }
            return count
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

// The palette itself lives in CalopodDomain so the iPhone app builds the same one.
public typealias CalendarPaletteEntry = CalopodDomain.CalendarPaletteEntry
public typealias CalendarPalette = CalopodDomain.CalendarPalette

/// The one rule for the name shown for a calendar, used by the app and the command line: the name
/// chosen on this Mac, unless it is blank or the same as the provider's.
public enum CalendarDisplayName {
    /// The chosen name when it differs from the real one, else nil.
    public static func alias(_ alias: String?, real: String?) -> String? {
        guard let text = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text != real else { return nil }
        return text
    }

    public static func shown(alias: String?, real: String?) -> String? { Self.alias(alias, real: real) ?? real }
}
