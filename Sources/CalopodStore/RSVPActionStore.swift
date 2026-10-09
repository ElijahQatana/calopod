import CalopodDomain
import Foundation
import GRDB

public enum RSVPActionStoreError: Error {
    case unresolvedAction(String)
    case intentMismatch
}

extension LocalStateRepository {
    public func isMappedRSVPTarget(_ target: RSVPTarget) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (SELECT 1 FROM mirror_mappings m JOIN arms a ON a.id = m.arm_id
                WHERE a.target_binding_id = ? AND m.provider_event_id = ?)
                """, arguments: [target.calendarBindingID, target.eventID]) ?? false
        }
    }

    /// Atomic reservation prevents another process from resending an uncertain action.
    public func beginRSVPAction(_ intent: RSVPActionIntent) throws -> (record: RSVPActionRecord, isNew: Bool) {
        try database.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT record FROM inbox_rsvp_actions WHERE id = ?", arguments: [intent.id]) {
                let existing = try JSONDecoder().decode(RSVPActionRecord.self, from: row["record"])
                guard existing.intent == intent else { throw RSVPActionStoreError.intentMismatch }
                return (existing, false)
            }
            let target = try JSONEncoder.sorted.encode(intent.target)
            if let id = try String.fetchOne(db, sql: """
                SELECT id FROM inbox_rsvp_actions WHERE target = ? AND status IN ('pending', 'accepted', 'unknown')
                """, arguments: [target]) {
                throw RSVPActionStoreError.unresolvedAction(id)
            }
            let record = RSVPActionRecord(intent: intent, outcome: RSVPActionOutcome(status: .pending))
            try db.execute(sql: "INSERT INTO inbox_rsvp_actions (id, target, status, record) VALUES (?, ?, ?, ?)",
                           arguments: [intent.id, target, record.outcome.status.rawValue, try JSONEncoder.sorted.encode(record)])
            return (record, true)
        }
    }

    public func rsvpAction(id: String) throws -> RSVPActionRecord? {
        try database.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT record FROM inbox_rsvp_actions WHERE id = ?", arguments: [id]) else { return nil }
            return try JSONDecoder().decode(RSVPActionRecord.self, from: data)
        }
    }

    public func saveRSVPOutcome(id: String, outcome: RSVPActionOutcome) throws -> RSVPActionRecord {
        try database.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT record FROM inbox_rsvp_actions WHERE id = ?", arguments: [id]) else {
                throw RSVPActionStoreError.intentMismatch
            }
            let existing = try JSONDecoder().decode(RSVPActionRecord.self, from: data)
            guard existing.outcome.status.isUnresolved else { return existing }
            let record = RSVPActionRecord(intent: existing.intent, outcome: outcome, submissionAccepted: existing.submissionAccepted)
            try db.execute(sql: "UPDATE inbox_rsvp_actions SET status = ?, record = ? WHERE id = ?",
                           arguments: [outcome.status.rawValue, try JSONEncoder.sorted.encode(record), id])
            return record
        }
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
