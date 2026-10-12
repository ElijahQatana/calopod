@testable import CalopodStore
import Foundation
import GRDB
import Testing

@Test
func historyRetentionKeepsRecoveryAndDeletionProof() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    let now = Date(timeIntervalSince1970: 20_000_000)
    let cutoff = now.addingTimeInterval(-90 * 86_400)
    let old = cutoff.addingTimeInterval(-1)
    try repository.saveConnection(StoredConnection(id: "connection", configurationID: "default", provider: "eventkit", displayLabel: nil, isEnabled: true))
    try repository.replaceCalendarBindings(connectionID: "connection", bindings: [StoredCalendarBinding(id: "calendar", connectionID: "connection", providerCalendarID: "source", displayLabel: nil, isSelected: true, isReadOnly: true)])
    try database.write { db in
        for (id, status, finish) in [
            ("expired", "succeeded", old), ("failed", "failed", old),
            ("recent", "succeeded", now), ("boundary", "succeeded", cutoff),
            ("running", "running", old), ("interrupted", "interrupted", old),
            ("uncertain", "succeeded", old), ("unknown-operation", "failed", old), ("future", "unknown", old)
        ] {
            try db.execute(sql: "INSERT INTO sync_runs (id, mode, status, started_at, finished_at) VALUES (?, 'apply', ?, ?, ?)", arguments: [id, status, old, finish])
        }
        try db.execute(sql: "INSERT INTO sync_runs (id, mode, status, started_at) VALUES ('unfinished', 'apply', 'succeeded', ?)", arguments: [old])
        for (run, status) in [("expired", "succeeded"), ("uncertain", "pending"), ("recent", "succeeded"), ("unknown-operation", "unknown")] {
            try db.execute(sql: "INSERT INTO sync_operations (idempotency_key, run_id, mirror_key, action, desired_fingerprint, status, updated_at) VALUES (?, ?, ?, 'delete', 'synthetic', ?, ?)", arguments: [run, run, run, status, old])
        }
        try db.execute(sql: """
            INSERT INTO normalized_instances (source_key_hash, connection_id, calendar_binding_id,
                provider_event_id, starts_at, ends_at, is_all_day, availability, is_cancelled,
                content_fingerprint, seen_generation)
            VALUES ('returned', 'connection', 'calendar', 'event', ?, ?, 0, 'busy', 0, 'synthetic', 1),
                   ('cancelled', 'connection', 'calendar', 'cancelled', ?, ?, 0, 'busy', 1, 'synthetic', 1),
                   ('stale', 'connection', 'calendar', 'stale', ?, ?, 0, 'busy', 0, 'synthetic', 1),
                   ('legacy', 'connection', 'calendar', 'legacy', ?, ?, 0, 'busy', 0, 'synthetic', 1)
            """, arguments: [old, now, old, now, old, now, old, now])
        try db.execute(sql: "UPDATE normalized_instances SET last_seen_at = ? WHERE source_key_hash = 'returned'", arguments: [now])
        try db.execute(sql: "UPDATE normalized_instances SET last_seen_at = ? WHERE source_key_hash = 'stale'", arguments: [old.addingTimeInterval(-1)])
        for (source, mirror, date) in [
            ("returned", "expired", old), ("returned", "recent", old),
            ("returned", "uncertain", old), ("returned", "boundary", cutoff),
            ("absent", "absent", old), ("cancelled", "cancelled", old),
            ("returned", "mapped", old), ("stale", "stale", old), ("legacy", "legacy", old)
        ] {
            try db.execute(sql: "INSERT INTO tombstones VALUES (?, ?, 'proof', ?)", arguments: [source, mirror, date])
        }
        try db.execute(sql: "INSERT INTO arms (id, configuration_id, target_binding_id, rule_mode, created_at, updated_at) VALUES ('arm', 'default', 'calendar', 'busy', ?, ?)", arguments: [old, old])
        try db.execute(sql: "INSERT INTO mirror_mappings VALUES ('mapped', 'arm', 'returned', 'target', NULL, 'synthetic', 'ownership', ?)", arguments: [old])
    }
    try database.read { (db: Database) throws -> Void in
        let runs = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN DELETE FROM sync_runs WHERE status IN ('succeeded', 'failed') AND finished_at < ? AND NOT EXISTS (SELECT 1 FROM sync_operations WHERE run_id = sync_runs.id AND status <> 'succeeded')", arguments: [cutoff]).map { $0["detail"] as String }.joined()
        let operations = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT 1 FROM sync_operations WHERE mirror_key = ?", arguments: ["mirror"]).map { $0["detail"] as String }.joined()
        #expect(runs.contains("INDEX sync_runs_retention"))
        #expect(runs.contains("INDEX sync_operations_run_status"))
        #expect(operations.contains("INDEX sync_operations_mirror"))
    }
    try repository.pruneSyncHistory(now: now)
    try repository.pruneSyncHistory(now: now)
    try database.read { (db: Database) throws -> Void in
        #expect(try String.fetchAll(db, sql: "SELECT id FROM sync_runs ORDER BY id") == ["boundary", "future", "interrupted", "recent", "running", "uncertain", "unfinished", "unknown-operation"])
        #expect(try String.fetchAll(db, sql: "SELECT idempotency_key FROM sync_operations ORDER BY idempotency_key") == ["recent", "uncertain", "unknown-operation"])
        #expect(try String.fetchAll(db, sql: "SELECT mirror_key FROM tombstones ORDER BY mirror_key") == ["absent", "boundary", "cancelled", "legacy", "mapped", "recent", "stale", "uncertain"])
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mirror_mappings") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM normalized_instances") == 4)
    }
    _ = try repository.beginSyncRun(mode: "preview", trigger: "manual", now: now.addingTimeInterval(91 * 86_400))
    #expect(try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_runs WHERE id = 'recent'") } == 0)
}
