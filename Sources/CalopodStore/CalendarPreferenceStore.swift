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

/// The twelve colors a calendar can be given on this Mac. The app draws them; the command line
/// refers to them by id. Dark values are lifted to hold up on dark surfaces.
public struct CalendarPaletteEntry: Equatable, Sendable {
    public let id: String
    public let name: String
    public let light: UInt32
    public let dark: UInt32
}

public enum CalendarPalette {
    public static let entries: [CalendarPaletteEntry] = [
        CalendarPaletteEntry(id: "blue", name: "Blue", light: 0x3a5fcd, dark: 0x7b9af0),
        CalendarPaletteEntry(id: "orange", name: "Orange", light: 0xd9731a, dark: 0xf2a04a),
        CalendarPaletteEntry(id: "green", name: "Green", light: 0x2f9e5f, dark: 0x5cc88b),
        CalendarPaletteEntry(id: "purple", name: "Purple", light: 0x9a4fc0, dark: 0xc58be8),
        CalendarPaletteEntry(id: "red", name: "Red", light: 0xc8453b, dark: 0xef7b6f),
        CalendarPaletteEntry(id: "teal", name: "Teal", light: 0x12908e, dark: 0x4cc3c0),
        CalendarPaletteEntry(id: "pink", name: "Pink", light: 0xcc4a8f, dark: 0xef82bb),
        CalendarPaletteEntry(id: "amber", name: "Amber", light: 0xb8860b, dark: 0xe5b83a),
        CalendarPaletteEntry(id: "sky", name: "Sky", light: 0x1f8ac4, dark: 0x5db4ec),
        CalendarPaletteEntry(id: "lime", name: "Lime", light: 0x6f9a1f, dark: 0xa3c94f),
        CalendarPaletteEntry(id: "indigo", name: "Indigo", light: 0x5b4bc4, dark: 0x9a8cf0),
        CalendarPaletteEntry(id: "gray", name: "Gray", light: 0x6b7280, dark: 0xa1a8b3),
    ]

    public static func entry(id: String) -> CalendarPaletteEntry? { entries.first { $0.id == id } }
}
