import Foundation
import GRDB

public struct StoredConnection: Equatable, Sendable {
    public let id: String
    public let configurationID: String
    public let provider: String
    public let displayLabel: String?
    public let isEnabled: Bool

    public init(
        id: String,
        configurationID: String,
        provider: String,
        displayLabel: String?,
        isEnabled: Bool
    ) {
        self.id = id
        self.configurationID = configurationID
        self.provider = provider
        self.displayLabel = displayLabel
        self.isEnabled = isEnabled
    }
}

public struct StoredCalendarBinding: Equatable, Sendable {
    public let id: String
    public let connectionID: String
    public let providerCalendarID: String
    public let displayLabel: String?
    public let isSelected: Bool
    public let isReadOnly: Bool
    public let providerSourceID: String?
    public let providerSourceType: String?
    public let providerSourceLabel: String?

    public init(
        id: String,
        connectionID: String,
        providerCalendarID: String,
        displayLabel: String?,
        isSelected: Bool,
        isReadOnly: Bool,
        providerSourceID: String? = nil,
        providerSourceType: String? = nil,
        providerSourceLabel: String? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.providerCalendarID = providerCalendarID
        self.displayLabel = displayLabel
        self.isSelected = isSelected
        self.isReadOnly = isReadOnly
        self.providerSourceID = providerSourceID
        self.providerSourceType = providerSourceType
        self.providerSourceLabel = providerSourceLabel
    }
}

public final class LocalStateRepository: @unchecked Sendable {
    private let database: CalopodDatabase

    public init(database: CalopodDatabase) {
        self.database = database
    }

    public func saveConnection(_ connection: StoredConnection, now: Date = Date()) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO configurations (id, created_at, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at
                    """,
                arguments: [connection.configurationID, now, now]
            )
            try database.execute(
                sql: """
                    INSERT INTO connections
                        (id, configuration_id, provider, display_label, is_enabled, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_label = excluded.display_label,
                        is_enabled = excluded.is_enabled,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    connection.id,
                    connection.configurationID,
                    connection.provider,
                    connection.displayLabel,
                    connection.isEnabled,
                    now,
                    now,
                ]
            )
        }
    }

    public func connections(provider: String? = nil) throws -> [StoredConnection] {
        try database.read { database in
            let rows: [Row]
            if let provider {
                rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, configuration_id, provider, display_label, is_enabled
                        FROM connections
                        WHERE provider = ?
                        ORDER BY created_at, id
                        """,
                    arguments: [provider]
                )
            } else {
                rows = try Row.fetchAll(
                    database,
                    sql: """
                        SELECT id, configuration_id, provider, display_label, is_enabled
                        FROM connections
                        ORDER BY created_at, id
                        """
                )
            }

            return rows.map {
                StoredConnection(
                    id: $0["id"],
                    configurationID: $0["configuration_id"],
                    provider: $0["provider"],
                    displayLabel: $0["display_label"],
                    isEnabled: $0["is_enabled"]
                )
            }
        }
    }

    public func connection(id: String) throws -> StoredConnection? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, configuration_id, provider, display_label, is_enabled
                    FROM connections
                    WHERE id = ?
                    """,
                arguments: [id]
            ) else {
                return nil
            }
            return StoredConnection(
                id: row["id"],
                configurationID: row["configuration_id"],
                provider: row["provider"],
                displayLabel: row["display_label"],
                isEnabled: row["is_enabled"]
            )
        }
    }

    public func removeConnection(id: String) throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM connections WHERE id = ?", arguments: [id])
        }
    }

    public func replaceCalendarBindings(
        connectionID: String,
        bindings: [StoredCalendarBinding],
        now: Date = Date()
    ) throws {
        try database.writeTransaction { database in
            let existingSelections = try Row.fetchAll(
                database,
                sql: "SELECT provider_calendar_id, is_selected FROM calendar_bindings WHERE connection_id = ?",
                arguments: [connectionID]
            ).reduce(into: [String: Bool]()) { result, row in
                result[row["provider_calendar_id"]] = row["is_selected"]
            }

            try database.execute(
                sql: "DELETE FROM calendar_bindings WHERE connection_id = ?",
                arguments: [connectionID]
            )

            for binding in bindings {
                try database.execute(
                    sql: """
                        INSERT INTO calendar_bindings
                            (id, connection_id, provider_calendar_id, display_label,
                             is_selected, is_read_only, provider_source_id,
                             provider_source_type, provider_source_label, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        binding.id,
                        connectionID,
                        binding.providerCalendarID,
                        binding.displayLabel,
                        existingSelections[binding.providerCalendarID] ?? binding.isSelected,
                        binding.isReadOnly,
                        binding.providerSourceID,
                        binding.providerSourceType,
                        binding.providerSourceLabel,
                        now,
                    ]
                )
            }
        }
    }

    public func calendarBindings(connectionID: String) throws -> [StoredCalendarBinding] {
        try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT id, connection_id, provider_calendar_id, display_label,
                           is_selected, is_read_only, provider_source_id,
                           provider_source_type, provider_source_label
                    FROM calendar_bindings
                    WHERE connection_id = ?
                    ORDER BY display_label, id
                    """,
                arguments: [connectionID]
            ).map {
                StoredCalendarBinding(
                    id: $0["id"],
                    connectionID: $0["connection_id"],
                    providerCalendarID: $0["provider_calendar_id"],
                    displayLabel: $0["display_label"],
                    isSelected: $0["is_selected"],
                    isReadOnly: $0["is_read_only"],
                    providerSourceID: $0["provider_source_id"],
                    providerSourceType: $0["provider_source_type"],
                    providerSourceLabel: $0["provider_source_label"]
                )
            }
        }
    }

    public func calendarBinding(id: String) throws -> StoredCalendarBinding? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, connection_id, provider_calendar_id, display_label,
                           is_selected, is_read_only, provider_source_id,
                           provider_source_type, provider_source_label
                    FROM calendar_bindings
                    WHERE id = ?
                    """,
                arguments: [id]
            ) else {
                return nil
            }
            return StoredCalendarBinding(
                id: row["id"],
                connectionID: row["connection_id"],
                providerCalendarID: row["provider_calendar_id"],
                displayLabel: row["display_label"],
                isSelected: row["is_selected"],
                isReadOnly: row["is_read_only"],
                providerSourceID: row["provider_source_id"],
                providerSourceType: row["provider_source_type"],
                providerSourceLabel: row["provider_source_label"]
            )
        }
    }

    @discardableResult
    public func setCalendarSelection(
        id: String,
        isSelected: Bool
    ) throws -> StoredCalendarBinding? {
        try database.write { database in
            try database.execute(
                sql: "UPDATE calendar_bindings SET is_selected = ? WHERE id = ?",
                arguments: [isSelected, id]
            )
        }
        return try calendarBinding(id: id)
    }

    public func saveCursor(
        connectionID: String,
        calendarBindingID: String,
        scopeKey: String,
        value: String,
        scopeStart: Date? = nil,
        scopeEnd: Date? = nil,
        now: Date = Date()
    ) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO provider_cursors
                        (connection_id, calendar_binding_id, scope_key, scope_start,
                         scope_end, cursor_value, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(connection_id, calendar_binding_id, scope_key) DO UPDATE SET
                        scope_start = excluded.scope_start,
                        scope_end = excluded.scope_end,
                        cursor_value = excluded.cursor_value,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    connectionID,
                    calendarBindingID,
                    scopeKey,
                    scopeStart,
                    scopeEnd,
                    value,
                    now,
                ]
            )
        }
    }

    public func cursor(
        connectionID: String,
        calendarBindingID: String,
        scopeKey: String
    ) throws -> String? {
        try database.read { database in
            try String.fetchOne(
                database,
                sql: """
                    SELECT cursor_value FROM provider_cursors
                    WHERE connection_id = ? AND calendar_binding_id = ? AND scope_key = ?
                    """,
                arguments: [connectionID, calendarBindingID, scopeKey]
            )
        }
    }

    public func cursorValues(
        connectionID: String,
        calendarBindingID: String
    ) throws -> [String: String] {
        try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT scope_key, cursor_value FROM provider_cursors
                    WHERE connection_id = ? AND calendar_binding_id = ?
                    """,
                arguments: [connectionID, calendarBindingID]
            ).reduce(into: [String: String]()) { result, row in
                result[row["scope_key"]] = row["cursor_value"]
            }
        }
    }
}
