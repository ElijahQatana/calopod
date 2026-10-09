import CalopodDomain
import Foundation
import GRDB

/// One source event as persisted after `EventNormalizer` has processed it —
/// the shape every other part of the sync engine (planning, Availability)
/// reads, so it never has to know which provider or connection an event
/// actually came from.
public struct StoredNormalizedInstance: Equatable, Sendable {
    public let sourceKeyHash: String
    public let connectionID: String
    public let calendarBindingID: String
    public let providerEventID: String
    public let recurrenceID: String?
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let availability: String
    public let isCancelled: Bool
    public let isPrivate: Bool
    public let title: String?
    public let contentFingerprint: String
    public let providerUpdatedAt: Date?
    public let location: String?
    public let notes: String?
    public let url: String?
    public let organizer: EventParticipant?
    public let attendees: [EventParticipant]
    public let currentUserResponse: EventResponse

    public init(
        sourceKeyHash: String,
        connectionID: String,
        calendarBindingID: String,
        providerEventID: String,
        recurrenceID: String?,
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool,
        availability: String,
        isCancelled: Bool,
        isPrivate: Bool,
        title: String?,
        contentFingerprint: String,
        providerUpdatedAt: Date?,
        location: String? = nil,
        notes: String? = nil,
        url: String? = nil,
        organizer: EventParticipant? = nil,
        attendees: [EventParticipant] = [],
        currentUserResponse: EventResponse = .unavailable
    ) {
        self.sourceKeyHash = sourceKeyHash
        self.connectionID = connectionID
        self.calendarBindingID = calendarBindingID
        self.providerEventID = providerEventID
        self.recurrenceID = recurrenceID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.availability = availability
        self.isCancelled = isCancelled
        self.isPrivate = isPrivate
        self.title = title
        self.contentFingerprint = contentFingerprint
        self.providerUpdatedAt = providerUpdatedAt
        self.location = location
        self.notes = notes
        self.url = url
        self.organizer = organizer
        self.attendees = attendees
        self.currentUserResponse = currentUserResponse
    }
}

/// Persisted form of a provider's incremental-sync cursor for one scope,
/// read back on the next fetch so it can resume instead of re-scanning.
public struct StoredCursorUpdate: Equatable, Sendable {
    public let scopeKey: String
    public let value: String
    public let scopeStart: Date?
    public let scopeEnd: Date?

    public init(
        scopeKey: String,
        value: String,
        scopeStart: Date?,
        scopeEnd: Date?
    ) {
        self.scopeKey = scopeKey
        self.value = value
        self.scopeStart = scopeStart
        self.scopeEnd = scopeEnd
    }
}

/// The last known health of a Connection: whether its most recent fetch
/// succeeded, and if not, since when and why — the data behind `doctor`-style
/// diagnostics without exposing anything about the calendar content itself.
public struct StoredConnectionHealth: Equatable, Sendable {
    public let connectionID: String
    public let status: String
    public let checkedAt: Date
    public let staleSince: Date?
    public let errorCode: String?
}

extension LocalStateRepository {
    /// Stores one page of normalized events and reconciles what a full
    /// refresh implies was deleted — all inside one transaction, so a crash
    /// mid-refresh can never leave stale and fresh event rows mixed
    /// together.
    public func applyEventRefresh(
        connectionID: String,
        calendarBindingID: String,
        windowStart: Date,
        windowEnd: Date,
        instances: [StoredNormalizedInstance],
        cancelledSourceKeyHashes: [String],
        isFullRefresh: Bool,
        cursorUpdates: [StoredCursorUpdate],
        now: Date = Date()
    ) throws {
        try database.writeTransaction { database in
            // Every instance written in this refresh is tagged with a new
            // generation number. On a full refresh, any existing row in the
            // window that *didn't* get this generation's tag was absent from
            // the provider's page and is therefore gone — the cleanup below
            // deletes exactly those rows instead of requiring the caller to
            // diff old and new event lists itself.
            let previousGeneration = try Int64.fetchOne(
                database,
                sql: "SELECT MAX(seen_generation) FROM normalized_instances WHERE calendar_binding_id = ?",
                arguments: [calendarBindingID]
            ) ?? 0
            let generation = previousGeneration + 1

            for instance in instances {
                try database.execute(
                    sql: """
                        INSERT INTO normalized_instances
                            (source_key_hash, connection_id, calendar_binding_id,
                             provider_event_id, recurrence_id, starts_at, ends_at,
                             is_all_day, availability, is_cancelled, content_fingerprint,
                             seen_generation, title, is_private, provider_updated_at,
                             location, notes, url, organizer_json, attendees_json, response_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(source_key_hash) DO UPDATE SET
                            connection_id = excluded.connection_id,
                            calendar_binding_id = excluded.calendar_binding_id,
                            provider_event_id = excluded.provider_event_id,
                            recurrence_id = excluded.recurrence_id,
                            starts_at = excluded.starts_at,
                            ends_at = excluded.ends_at,
                            is_all_day = excluded.is_all_day,
                            availability = excluded.availability,
                            is_cancelled = excluded.is_cancelled,
                            content_fingerprint = excluded.content_fingerprint,
                            seen_generation = excluded.seen_generation,
                            title = excluded.title,
                            is_private = excluded.is_private,
                            provider_updated_at = excluded.provider_updated_at,
                            location = excluded.location,
                            notes = excluded.notes,
                            url = excluded.url,
                            organizer_json = excluded.organizer_json,
                            attendees_json = excluded.attendees_json,
                            response_json = excluded.response_json
                        """,
                    arguments: [
                        instance.sourceKeyHash,
                        connectionID,
                        calendarBindingID,
                        instance.providerEventID,
                        instance.recurrenceID,
                        instance.startsAt,
                        instance.endsAt,
                        instance.isAllDay,
                        instance.availability,
                        instance.isCancelled,
                        instance.contentFingerprint,
                        generation,
                        instance.title,
                        instance.isPrivate,
                        instance.providerUpdatedAt,
                        instance.location,
                        instance.notes,
                        instance.url,
                        try encodeOptionalEventDetails(instance.organizer),
                        try encodeEventDetails(instance.attendees),
                        try encodeEventDetails(instance.currentUserResponse),
                    ]
                )
            }

            for sourceKeyHash in cancelledSourceKeyHashes {
                try database.execute(
                    sql: "DELETE FROM normalized_instances WHERE source_key_hash = ?",
                    arguments: [sourceKeyHash]
                )
            }

            // Only a full refresh can safely infer deletions this way — an
            // incremental page only ever reports what changed, so anything
            // it doesn't mention says nothing about whether older events in
            // the window still exist. Incremental deletions instead rely
            // entirely on the explicit `cancelledSourceKeyHashes` above.
            if isFullRefresh {
                try database.execute(
                    sql: """
                        DELETE FROM normalized_instances
                        WHERE calendar_binding_id = ?
                          AND ends_at > ?
                          AND starts_at < ?
                          AND seen_generation <> ?
                        """,
                    arguments: [calendarBindingID, windowStart, windowEnd, generation]
                )
            }

            for cursor in cursorUpdates {
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
                        cursor.scopeKey,
                        cursor.scopeStart,
                        cursor.scopeEnd,
                        cursor.value,
                        now,
                    ]
                )
            }

            try database.execute(
                sql: """
                    INSERT INTO connection_health
                        (connection_id, status, checked_at, stale_since, error_code)
                    VALUES (?, 'healthy', ?, NULL, NULL)
                    ON CONFLICT(connection_id) DO UPDATE SET
                        status = excluded.status,
                        checked_at = excluded.checked_at,
                        stale_since = NULL,
                        error_code = NULL
                    """,
                arguments: [connectionID, now]
            )
        }
    }

    public func normalizedInstances(
        calendarBindingIDs: [String],
        from start: Date,
        through end: Date
    ) throws -> [StoredNormalizedInstance] {
        guard !calendarBindingIDs.isEmpty else { return [] }
        return try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT source_key_hash, connection_id, calendar_binding_id,
                           provider_event_id, recurrence_id, starts_at, ends_at,
                           is_all_day, availability, is_cancelled, content_fingerprint,
                           title, is_private, provider_updated_at,
                           location, notes, url, organizer_json, attendees_json, response_json
                    FROM normalized_instances
                    WHERE calendar_binding_id IN (\(normalizedEventQuestionMarks(count: calendarBindingIDs.count)))
                      AND ends_at > ?
                      AND starts_at < ?
                      AND is_cancelled = 0
                    ORDER BY starts_at, ends_at, source_key_hash
                    """,
                arguments: StatementArguments(calendarBindingIDs) + [start, end]
            ).map(normalizedInstance)
        }
    }

    public func markConnectionStale(
        connectionID: String,
        errorCode: String,
        now: Date = Date()
    ) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO connection_health
                        (connection_id, status, checked_at, stale_since, error_code)
                    VALUES (?, 'stale', ?, ?, ?)
                    ON CONFLICT(connection_id) DO UPDATE SET
                        status = excluded.status,
                        checked_at = excluded.checked_at,
                        stale_since = COALESCE(connection_health.stale_since, excluded.stale_since),
                        error_code = excluded.error_code
                    """,
                arguments: [connectionID, now, now, errorCode]
            )
        }
    }

    public func connectionHealth(connectionID: String) throws -> StoredConnectionHealth? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT connection_id, status, checked_at, stale_since, error_code
                    FROM connection_health
                    WHERE connection_id = ?
                    """,
                arguments: [connectionID]
            ) else {
                return nil
            }
            return StoredConnectionHealth(
                connectionID: row["connection_id"],
                status: row["status"],
                checkedAt: row["checked_at"],
                staleSince: row["stale_since"],
                errorCode: row["error_code"]
            )
        }
    }
}

private func normalizedEventQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

private func normalizedInstance(_ row: Row) -> StoredNormalizedInstance {
    StoredNormalizedInstance(
        sourceKeyHash: row["source_key_hash"],
        connectionID: row["connection_id"],
        calendarBindingID: row["calendar_binding_id"],
        providerEventID: row["provider_event_id"],
        recurrenceID: row["recurrence_id"],
        startsAt: row["starts_at"],
        endsAt: row["ends_at"],
        isAllDay: row["is_all_day"],
        availability: row["availability"],
        isCancelled: row["is_cancelled"],
        isPrivate: row["is_private"],
        title: row["title"],
        contentFingerprint: row["content_fingerprint"],
        providerUpdatedAt: row["provider_updated_at"],
        location: row["location"],
        notes: row["notes"],
        url: row["url"],
        organizer: decodeEventDetails(row["organizer_json"]),
        attendees: decodeEventDetails(row["attendees_json"]) ?? [],
        currentUserResponse: decodeEventDetails(row["response_json"]) ?? .unavailable
    )
}

private func encodeEventDetails<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func encodeOptionalEventDetails<Value: Encodable>(_ value: Value?) throws -> Data? {
    guard let value else { return nil }
    return try encodeEventDetails(value)
}

private func decodeEventDetails<Value: Decodable>(_ data: Data?) -> Value? {
    guard let data else { return nil }
    return try? JSONDecoder().decode(Value.self, from: data)
}
