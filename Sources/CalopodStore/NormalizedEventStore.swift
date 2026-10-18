import CalopodDomain
import Foundation
import GRDB

public enum EventRefreshError: Error {
    case invalidScope
}

/// One source event as stored after normalization, independent of provider.
public struct StoredNormalizedInstance: Codable, Equatable, Sendable {
    public let sourceKeyHash: String
    public let connectionID: String
    public let calendarBindingID: String
    public let providerEventID: String
    public let recurrenceID: String?
    public let providerSeriesID: String?
    public let startsAt: Date
    public let endsAt: Date
    public let isAllDay: Bool
    public let timeZoneIdentifier: String?
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
    public let providerExternalID: String?

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
        currentUserResponse: EventResponse = .unavailable,
        providerSeriesID: String? = nil,
        timeZoneIdentifier: String? = nil,
        providerExternalID: String? = nil
    ) {
        self.sourceKeyHash = sourceKeyHash
        self.connectionID = connectionID
        self.calendarBindingID = calendarBindingID
        self.providerEventID = providerEventID
        self.recurrenceID = recurrenceID
        self.providerSeriesID = providerSeriesID
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
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
        self.providerExternalID = providerExternalID
    }
}

/// A provider cursor for one scope, read back on the next fetch.
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

/// The last known health of a Connection: whether the latest fetch worked and, if not, since when
/// and why. No calendar content.
public struct StoredConnectionHealth: Equatable, Sendable {
    public let connectionID: String
    public let status: String
    public let checkedAt: Date
    public let staleSince: Date?
    public let errorCode: String?
}

extension LocalStateRepository {
    /// Stores a page of events and, for a full refresh, removes what went missing, all in one
    /// transaction.
    public func applyEventRefresh(
        connectionID: String,
        calendarBindingID: String,
        windowStart: Date,
        windowEnd: Date,
        instances: [StoredNormalizedInstance],
        cancelledSourceKeyHashes: [String],
        isFullRefresh: Bool,
        cursorUpdates: [StoredCursorUpdate],
        now: Date = Date(),
        observationInstances: [StoredNormalizedInstance]? = nil,
        removedSourceKeyHashes: [String] = [],
        excludedSourceKeyHashes: [String] = [],
        unconfirmedSourceKeyHashes: [String] = []
    ) throws {
        guard windowStart < windowEnd,
              (observationInstances ?? instances).allSatisfy({
                  $0.connectionID == connectionID && $0.calendarBindingID == calendarBindingID
              }) else { throw EventRefreshError.invalidScope }
        try database.writeTransaction { database in
            try recordInboxObservations(
                database, connectionID: connectionID, calendarBindingID: calendarBindingID,
                instances: observationInstances ?? instances, cancelled: cancelledSourceKeyHashes,
                removed: removedSourceKeyHashes, excluded: excludedSourceKeyHashes,
                windowStart: windowStart, windowEnd: windowEnd, isFullRefresh: isFullRefresh, now: now
            )
            // Rows written in this refresh get a new generation number. On a full refresh, rows in
            // the window without it were absent from the page and are deleted.
            let previousGeneration = try Int64.fetchOne(
                database,
                sql: "SELECT MAX(seen_generation) FROM normalized_instances WHERE calendar_binding_id = ?",
                arguments: [calendarBindingID]
            ) ?? 0
            let generation = previousGeneration + 1

            let upsert = try database.makeStatement(
                sql: """
                    INSERT INTO normalized_instances
                        (source_key_hash, connection_id, calendar_binding_id,
                         provider_event_id, recurrence_id, starts_at, ends_at,
                         is_all_day, availability, is_cancelled, content_fingerprint,
                         seen_generation, title, is_private, provider_updated_at,
                         location, notes, url, organizer_json, attendees_json, response_json, provider_series_id, time_zone, last_seen_at,
                         provider_external_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        response_json = excluded.response_json,
                        provider_series_id = excluded.provider_series_id,
                        time_zone = excluded.time_zone,
                        last_seen_at = excluded.last_seen_at,
                        provider_external_id = excluded.provider_external_id
                    """
            )
            for instance in instances {
                try upsert.execute(arguments: [
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
                    instance.providerSeriesID,
                    instance.timeZoneIdentifier,
                    now,
                    instance.providerExternalID,
                ])
            }

            for sourceKeyHash in cancelledSourceKeyHashes + removedSourceKeyHashes + excludedSourceKeyHashes + unconfirmedSourceKeyHashes {
                try database.execute(
                    sql: "DELETE FROM normalized_instances WHERE source_key_hash = ?",
                    arguments: [sourceKeyHash]
                )
            }

            // Only a full refresh can infer deletions this way. An incremental page only lists
            // changes, so deletions there come from `cancelledSourceKeyHashes`.
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
                           location, notes, url, organizer_json, attendees_json, response_json, provider_series_id, time_zone,
                           provider_external_id
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

func normalizedInstance(_ row: Row) -> StoredNormalizedInstance {
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
        currentUserResponse: decodeEventDetails(row["response_json"]) ?? .unavailable,
        providerSeriesID: row["provider_series_id"],
        timeZoneIdentifier: row["time_zone"],
        providerExternalID: row["provider_external_id"]
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
