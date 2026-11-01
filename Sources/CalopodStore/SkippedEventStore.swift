import CryptoKit
import Foundation
import GRDB

/// An event, a series or one occurrence that Calopod does not copy. Only this Mac knows; nothing
/// goes to a calendar and the event is not touched.
public struct EventSkip: Equatable, Sendable {
    public let calendarBindingID: String
    /// The series id for a recurring event, otherwise the event's own id.
    public let ref: String
    /// Which occurrence of the series. Empty for the whole series and for a single event.
    public let occurrence: String
    /// False when `ref` is an id that only this Mac gives the event.
    public let isPortable: Bool
    public let skippedAt: Date

    public init(calendarBindingID: String, ref: String, occurrence: String = "", isPortable: Bool, skippedAt: Date) {
        self.calendarBindingID = calendarBindingID
        self.ref = ref
        self.occurrence = occurrence
        self.isPortable = isPortable
        self.skippedAt = skippedAt
    }

    /// A single EventKit event is portable only through its server id, since its own id differs per Mac.
    public init(_ event: StoredNormalizedInstance, wholeSeries: Bool, isEventKit: Bool, now: Date = Date()) {
        if let series = event.providerSeriesID {
            self.init(calendarBindingID: event.calendarBindingID, ref: series,
                      occurrence: wholeSeries ? "" : event.recurrenceID ?? "", isPortable: true, skippedAt: now)
        } else {
            self.init(calendarBindingID: event.calendarBindingID, ref: event.providerExternalID ?? event.providerEventID,
                      isPortable: event.providerExternalID != nil || !isEventKit, skippedAt: now)
        }
    }

    public var id: String {
        let key = [calendarBindingID, ref, occurrence].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return SHA256.hash(data: Data(key.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public func matches(_ event: StoredNormalizedInstance) -> Bool {
        guard event.calendarBindingID == calendarBindingID else { return false }
        if let series = event.providerSeriesID {
            return series == ref && (occurrence.isEmpty || occurrence == event.recurrenceID)
        }
        return ref == event.providerEventID || ref == event.providerExternalID
    }
}

extension LocalStateRepository {
    public func eventSkips() throws -> [EventSkip] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM skipped_events ORDER BY skipped_at, ref, occurrence").map {
                EventSkip(calendarBindingID: $0["calendar_binding_id"], ref: $0["ref"], occurrence: $0["occurrence"],
                          isPortable: $0["is_portable"], skippedAt: $0["skipped_at"])
            }
        }
    }

    public func addEventSkip(_ skip: EventSkip) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO skipped_events (calendar_binding_id, ref, occurrence, is_portable, skipped_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [skip.calendarBindingID, skip.ref, skip.occurrence, skip.isPortable, skip.skippedAt])
        }
    }

    public func removeEventSkip(_ skip: EventSkip) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM skipped_events WHERE calendar_binding_id = ? AND ref = ? AND occurrence = ?",
                           arguments: [skip.calendarBindingID, skip.ref, skip.occurrence])
        }
    }
}
