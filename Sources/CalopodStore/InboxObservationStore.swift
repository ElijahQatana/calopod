import CalopodDomain
import Foundation
import GRDB

extension LocalStateRepository {
    public func inboxObservation(sourceKeyHash: String) throws -> InboxObservation? {
        try database.read { db in
            try loadInboxObservation(db, sourceKeyHash: sourceKeyHash)
        }
    }

    public func inboxCoverage(connectionID: String, calendarBindingID: String) throws -> InboxCoverage? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT starts_at, ends_at, observed_at FROM inbox_coverage
                WHERE connection_id = ? AND calendar_binding_id = ?
                """, arguments: [connectionID, calendarBindingID]) else { return nil }
            return InboxCoverage(startsAt: row["starts_at"], endsAt: row["ends_at"], observedAt: row["observed_at"])
        }
    }

    public func inboxActivity(connectionID: String, includeAcknowledged: Bool = false) throws -> [InboxActivity] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.snapshot, a.acknowledged_at FROM inbox_activity a
                JOIN inbox_observations o USING (source_key_hash)
                WHERE o.connection_id = ? AND (? OR a.acknowledged_at IS NULL)
                ORDER BY a.observed_at DESC, a.source_key_hash, a.revision DESC
                """, arguments: [connectionID, includeAcknowledged]).map { row in
                let activity: InboxActivity = try inboxDecode(row["snapshot"])
                return InboxActivity(
                    sourceKeyHash: activity.sourceKeyHash, revision: activity.revision,
                    observedAt: activity.observedAt, types: activity.types,
                    changedFields: activity.changedFields, previousEvent: activity.previousEvent,
                    event: activity.event, responseTiming: activity.responseTiming,
                    acknowledgedAt: row["acknowledged_at"]
                )
            }
        }
    }

    /// Reviewing one revision never reviews a concurrent or later edit.
    @discardableResult
    public func acknowledgeInboxRevision(sourceKeyHash: String, revision: Int64, now: Date = Date()) throws -> Bool {
        try database.write { db in
            guard let observation = try loadInboxObservation(db, sourceKeyHash: sourceKeyHash),
                  revision > 0, revision <= observation.revision else { return false }
            try db.execute(sql: """
                UPDATE inbox_activity SET acknowledged_at = COALESCE(acknowledged_at, ?)
                WHERE source_key_hash = ? AND revision = ?
                """, arguments: [now, sourceKeyHash, revision])
            // Acknowledgement survives pruning; it is not inferred from which
            // activity rows happen to remain in retained history.
            try saveInboxObservation(db, observation: InboxObservation(
                event: observation.event, revision: observation.revision,
                firstObservedAt: observation.firstObservedAt, lastObservedAt: observation.lastObservedAt,
                responseBaseline: observation.responseBaseline, responseTiming: observation.responseTiming,
                tombstone: observation.tombstone,
                acknowledgedRevision: max(observation.acknowledgedRevision ?? 0, revision),
                previousInterval: observation.previousInterval
            ))
            return true
        }
    }

    /// Explicit history reset keeps observed baselines and revision counters.
    /// Removing the Connection is the operation that also removes private detail.
    public func clearInboxHistory(connectionID: String) throws {
        try database.write { db in
            let keys = try String.fetchAll(db, sql: "SELECT source_key_hash FROM inbox_observations WHERE connection_id = ?",
                                           arguments: [connectionID])
            for key in keys {
                guard let observation = try loadInboxObservation(db, sourceKeyHash: key) else { continue }
                try saveInboxObservation(db, observation: InboxObservation(
                    event: observation.event, revision: observation.revision,
                    firstObservedAt: observation.firstObservedAt, lastObservedAt: observation.lastObservedAt,
                    responseBaseline: observation.responseBaseline, responseTiming: observation.responseTiming,
                    tombstone: observation.tombstone, acknowledgedRevision: observation.revision,
                    previousInterval: observation.previousInterval
                ))
            }
            try db.execute(sql: """
                DELETE FROM inbox_activity WHERE source_key_hash IN
                (SELECT source_key_hash FROM inbox_observations WHERE connection_id = ?)
                """, arguments: [connectionID])
        }
    }
}

func loadInboxObservation(_ db: Database, sourceKeyHash: String) throws -> InboxObservation? {
    guard let data = try Data.fetchOne(db, sql: "SELECT snapshot FROM inbox_observations WHERE source_key_hash = ?",
                                      arguments: [sourceKeyHash]) else { return nil }
    let observation: InboxObservation = try inboxDecode(data)
    guard observation.previousInterval == nil else { return observation }
    // Older snapshots predate durable move intervals. Recover the latest move
    // from retained activity when available, without inventing missing history.
    for data in try Data.fetchAll(db, sql: """
        SELECT snapshot FROM inbox_activity WHERE source_key_hash = ? ORDER BY revision DESC
        """, arguments: [sourceKeyHash]) {
        let activity: InboxActivity = try inboxDecode(data)
        guard let previous = activity.previousEvent,
              previous.startsAt != activity.event.startsAt || previous.endsAt != activity.event.endsAt,
              let interval = try? SyncWindow(start: previous.startsAt, end: previous.endsAt) else { continue }
        return InboxObservation(
            event: observation.event, revision: observation.revision,
            firstObservedAt: observation.firstObservedAt, lastObservedAt: observation.lastObservedAt,
            responseBaseline: observation.responseBaseline, responseTiming: observation.responseTiming,
            tombstone: observation.tombstone, acknowledgedRevision: observation.acknowledgedRevision,
            previousInterval: interval
        )
    }
    return observation
}

private func saveInboxObservation(_ db: Database, observation: InboxObservation) throws {
    try db.execute(sql: """
        INSERT INTO inbox_observations (source_key_hash, connection_id, calendar_binding_id, snapshot)
        VALUES (?, ?, ?, ?) ON CONFLICT(source_key_hash) DO UPDATE SET snapshot = excluded.snapshot
        """, arguments: [observation.event.sourceKeyHash, observation.event.connectionID,
                          observation.event.calendarBindingID, try inboxEncode(observation)])
}

/// Called only inside the normalized-events/cursors transaction.
func recordInboxObservations(
    _ db: Database, connectionID: String, calendarBindingID: String,
    instances: [StoredNormalizedInstance], cancelled: [String], removed: [String], excluded: [String],
    windowStart: Date, windowEnd: Date, isFullRefresh: Bool, now: Date
) throws {
    let selected = try Bool.fetchOne(db, sql: """
        SELECT b.is_selected AND c.is_enabled FROM calendar_bindings b
        JOIN connections c ON c.id = b.connection_id WHERE b.id = ? AND c.id = ?
        """, arguments: [calendarBindingID, connectionID]) ?? false
    guard selected else { return }
    let coverage = try Row.fetchOne(db, sql: """
        SELECT starts_at, ends_at FROM inbox_coverage WHERE connection_id = ? AND calendar_binding_id = ?
        """, arguments: [connectionID, calendarBindingID])
    for key in excluded {
        try db.execute(sql: "DELETE FROM inbox_observations WHERE source_key_hash = ? AND connection_id = ?",
                       arguments: [key, connectionID])
    }
    let excludedKeys = Set(excluded)
    for event in instances where !excludedKeys.contains(event.sourceKeyHash) {
        let previous = try loadInboxObservation(db, sourceKeyHash: event.sourceKeyHash)
        if previous == nil && (event.endsAt <= windowStart || event.startsAt >= windowEnd) { continue }
        var fields = previous.map { event.inboxChangedFields(from: $0.event) } ?? []
        let responseChanged = previous.map {
            $0.event.currentUserResponse.state != event.currentUserResponse.state
                || $0.event.currentUserResponse.respondedAt != event.currentUserResponse.respondedAt
        } ?? false
        if responseChanged { fields.append("response") }
        var types: [InboxActivityType] = []
        if previous == nil, let coverage {
            let start: Date = coverage["starts_at"]
            let end: Date = coverage["ends_at"]
            if event.startsAt >= start && event.endsAt <= end { types.append(.newEvent) }
        }
        if previous != nil {
            if fields.contains(where: { $0 != "response" }) { types.append(.contentChanged) }
            if responseChanged { types.append(.responseChanged) }
            if previous?.tombstone != nil {
                types.append(.newEvent)
                fields.append("restored")
            }
        }
        let revision = (previous?.revision ?? 0) + (previous == nil || !types.isEmpty ? 1 : 0)
        let baseline: InboxResponseBaseline?
        let timing: InboxResponseTiming
        if event.hasInboxResponseBaseline {
            if previous == nil || responseChanged || previous?.responseBaseline == nil {
                baseline = InboxResponseBaseline(event: event, revision: revision, observedAt: now)
                timing = fields.contains(where: { $0 != "response" }) ? .uncertain : .observedBaseline
            } else {
                baseline = previous?.responseBaseline
                // Evidence is based on sequential local observations. A provider
                // response timestamp arriving together with an edit cannot prove order.
                timing = types.contains(.contentChanged) ? .afterResponse : (previous?.responseTiming ?? .observedBaseline)
            }
        } else {
            baseline = nil
            timing = .notApplicable
        }
        let observation = InboxObservation(
            event: event, revision: revision, firstObservedAt: previous?.firstObservedAt ?? now,
            lastObservedAt: now, responseBaseline: baseline, responseTiming: timing,
            tombstone: nil, acknowledgedRevision: previous?.acknowledgedRevision,
            previousInterval: fields.contains("time") ? previous.flatMap {
                try? SyncWindow(start: $0.event.startsAt, end: $0.event.endsAt)
            } : previous?.previousInterval
        )
        try saveInboxObservation(db, observation: observation)
        if !types.isEmpty {
            try saveInboxActivity(db, observation: observation, previous: previous?.event,
                                  types: types, fields: fields, now: now)
        }
    }
    for (keys, type) in [(cancelled, InboxActivityType.cancelled), (removed, .removed)] {
        for key in Set(keys).subtracting(excludedKeys) {
            guard let previous = try loadInboxObservation(db, sourceKeyHash: key),
                  previous.event.connectionID == connectionID,
                  previous.event.calendarBindingID == calendarBindingID,
                  previous.tombstone != type else { continue }
            let observation = InboxObservation(
                event: previous.event, revision: previous.revision + 1,
                firstObservedAt: previous.firstObservedAt, lastObservedAt: now,
                responseBaseline: previous.responseBaseline, responseTiming: .notApplicable,
                tombstone: type, acknowledgedRevision: previous.acknowledgedRevision,
                previousInterval: previous.previousInterval
            )
            try saveInboxObservation(db, observation: observation)
            try saveInboxActivity(db, observation: observation, previous: previous.event,
                                  types: [type], fields: [type.rawValue], now: now)
        }
    }
    if isFullRefresh {
        try db.execute(sql: """
            INSERT INTO inbox_coverage (connection_id, calendar_binding_id, starts_at, ends_at, observed_at)
            VALUES (?, ?, ?, ?, ?) ON CONFLICT(connection_id, calendar_binding_id) DO UPDATE SET
            starts_at = excluded.starts_at, ends_at = excluded.ends_at, observed_at = excluded.observed_at
            """, arguments: [connectionID, calendarBindingID, windowStart, windowEnd, now])
    }
    // Bound activity detail to 90 days and 1,000 revisions per Connection.
    // Baselines, latest snapshots, tombstones and acknowledgements are independent.
    try db.execute(sql: """
        DELETE FROM inbox_activity WHERE source_key_hash IN
        (SELECT source_key_hash FROM inbox_observations WHERE connection_id = ?) AND observed_at < ?
        """, arguments: [connectionID, now.addingTimeInterval(-90 * 86_400)])
    try db.execute(sql: """
        DELETE FROM inbox_activity WHERE rowid IN (
            SELECT a.rowid FROM inbox_activity a JOIN inbox_observations o USING (source_key_hash)
            WHERE o.connection_id = ? ORDER BY a.observed_at DESC, a.source_key_hash, a.revision DESC
            LIMIT -1 OFFSET 1000)
        """, arguments: [connectionID])
}

private func saveInboxActivity(_ db: Database, observation: InboxObservation, previous: StoredNormalizedInstance?,
                               types: [InboxActivityType], fields: [String], now: Date) throws {
    let activity = InboxActivity(
        sourceKeyHash: observation.event.sourceKeyHash, revision: observation.revision,
        observedAt: now, types: types, changedFields: fields, previousEvent: previous,
        event: observation.event, responseTiming: observation.responseTiming, acknowledgedAt: nil
    )
    try db.execute(sql: """
        INSERT INTO inbox_activity (source_key_hash, revision, observed_at, snapshot) VALUES (?, ?, ?, ?)
        """, arguments: [activity.sourceKeyHash, activity.revision, now, try inboxEncode(activity)])
}

private func inboxEncode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
}

private func inboxDecode<T: Decodable>(_ data: Data) throws -> T {
    try JSONDecoder().decode(T.self, from: data)
}
