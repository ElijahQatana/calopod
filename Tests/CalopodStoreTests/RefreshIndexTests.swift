@testable import CalopodStore
import Foundation
import GRDB
import Testing

@Test
func refreshIndexesUpgradeEveryEarlierSchema() throws {
    for identifier in CalopodDatabase.supportedMigrationIdentifiers.dropLast() {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("refresh-upgrade-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let queue = try DatabaseQueue(path: path)
            try CalopodDatabase.migrator.migrate(queue, upTo: identifier)
            try queue.write { db in
                try db.execute(sql: "INSERT INTO sync_runs (id, mode, status, started_at) VALUES ('recover', 'apply', 'running', ?)", arguments: [Date(timeIntervalSince1970: 100)])
                try db.execute(sql: """
                    INSERT INTO configurations VALUES ('configuration', '2026-01-01', '2026-01-01');
                    INSERT INTO connections (id, configuration_id, provider, created_at, updated_at)
                        VALUES ('connection', 'configuration', 'eventkit', '2026-01-01', '2026-01-01');
                    INSERT INTO calendar_bindings (id, connection_id, provider_calendar_id, created_at)
                        VALUES ('calendar', 'connection', 'source', '2026-01-01');
                    INSERT INTO normalized_instances (source_key_hash, connection_id, calendar_binding_id,
                        provider_event_id, starts_at, ends_at, is_all_day, availability, is_cancelled,
                        content_fingerprint, seen_generation)
                        VALUES ('source', 'connection', 'calendar', 'event', '2026-01-01', '2026-01-02', 0, 'busy', 0, 'synthetic', 7);
                    INSERT INTO tombstones VALUES ('source', 'mirror', 'proof', '2026-01-01');
                    INSERT INTO sync_operations (idempotency_key, run_id, mirror_key, action, desired_fingerprint, status, updated_at)
                        VALUES ('operation', 'recover', 'mirror', 'delete', 'synthetic', 'pending', '2026-01-01');
                    """)
            }
        }
        let upgraded = try CalopodDatabase(path: path)
        try upgraded.migrate()
        try upgraded.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations") == 18)
            #expect(try String.fetchOne(db, sql: "SELECT status FROM sync_runs WHERE id = 'recover'") == "running")
            #expect(try Int.fetchOne(db, sql: "SELECT seen_generation FROM normalized_instances WHERE source_key_hash = 'source'") == 7)
            #expect(try Date.fetchOne(db, sql: "SELECT last_seen_at FROM normalized_instances WHERE source_key_hash = 'source'") == nil)
            #expect(try String.fetchOne(db, sql: "SELECT proof_cursor_hash FROM tombstones") == "proof")
            #expect(try String.fetchOne(db, sql: "SELECT status FROM sync_operations") == "pending")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name IN ('normalized_instances_binding_generation', 'normalized_instances_binding_window', 'sync_runs_retention', 'sync_operations_mirror')") == 4)
        }
    }
}

@Test
func largeWindowRefreshUsesIndexesAndReplacesOnlyItsScope() throws {
    let database = try CalopodDatabase.inMemory()
    let repository = LocalStateRepository(database: database)
    try repository.saveConnection(StoredConnection(id: "connection", configurationID: "default", provider: "eventkit", displayLabel: nil, isEnabled: true))
    try repository.replaceCalendarBindings(connectionID: "connection", bindings: ["calendar", "other"].map {
        StoredCalendarBinding(id: $0, connectionID: "connection", providerCalendarID: $0, displayLabel: nil, isSelected: true, isReadOnly: true)
    })
    let start = Date(timeIntervalSince1970: 1_000_000)
    let end = start.addingTimeInterval(100_000)
    let events = (0..<10_000).map { index in
        StoredNormalizedInstance(sourceKeyHash: "event-\(index)", connectionID: "connection", calendarBindingID: "calendar", providerEventID: "event-\(index)", recurrenceID: nil, startsAt: start.addingTimeInterval(Double(index)), endsAt: start.addingTimeInterval(Double(index + 60)), isAllDay: false, availability: "busy", isCancelled: false, isPrivate: false, title: nil, contentFingerprint: "synthetic", providerUpdatedAt: nil)
    }
    func refresh(_ instances: [StoredNormalizedInstance]) throws {
        try repository.applyEventRefresh(connectionID: "connection", calendarBindingID: "calendar", windowStart: start, windowEnd: end, instances: instances, cancelledSourceKeyHashes: [], isFullRefresh: true, cursorUpdates: [], now: end)
    }
    try refresh(events)
    try database.write { db in
        try db.execute(sql: """
            INSERT INTO normalized_instances (source_key_hash, connection_id, calendar_binding_id,
                provider_event_id, starts_at, ends_at, is_all_day, availability, is_cancelled,
                content_fingerprint, seen_generation)
            SELECT 'other-' || source_key_hash, connection_id, 'other', provider_event_id,
                starts_at, ends_at, is_all_day, availability, is_cancelled, content_fingerprint,
                seen_generation FROM normalized_instances
            """)
    }
    try database.read { (db: Database) throws -> Void in
        let generationPlan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN SELECT MAX(seen_generation) FROM normalized_instances WHERE calendar_binding_id = ?", arguments: ["calendar"]).map { $0["detail"] as String }.joined()
        let deletionPlan = try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN DELETE FROM normalized_instances WHERE calendar_binding_id = ? AND ends_at > ? AND starts_at < ? AND seen_generation <> ?", arguments: ["calendar", start, end, 2]).map { $0["detail"] as String }.joined()
        #expect(generationPlan.contains("COVERING INDEX normalized_instances_binding_generation"))
        #expect(deletionPlan.contains("INDEX normalized_instances_binding_window"))
    }
    try database.read { (db: Database) throws -> Void in
        for (label, query) in [
            ("scan", "SELECT MAX(seen_generation) FROM normalized_instances NOT INDEXED WHERE calendar_binding_id = ?"),
            ("indexed", "SELECT MAX(seen_generation) FROM normalized_instances WHERE calendar_binding_id = ?")
        ] {
            let began = Date()
            for _ in 0..<200 {
                #expect(try Int.fetchOne(db, sql: query, arguments: ["calendar"]) == 1)
            }
            print("Refresh generation lookup \(label): \(Date().timeIntervalSince(began)) seconds for 200 queries over 20,000 rows")
        }
    }
    try refresh(Array(events.prefix(5_000)))
    #expect(try repository.normalizedInstances(calendarBindingIDs: ["calendar"], from: start, through: end).count == 5_000)
    #expect(try repository.normalizedInstances(calendarBindingIDs: ["other"], from: start, through: end).count == 10_000)
    try database.read { (db: Database) throws -> Void in
        #expect(try Date.fetchOne(db, sql: "SELECT MIN(last_seen_at) FROM normalized_instances WHERE calendar_binding_id = 'calendar'") == end)
        #expect(try Int.fetchOne(db, sql: "SELECT MIN(seen_generation) FROM normalized_instances WHERE calendar_binding_id = 'calendar'") == 2)
    }
}
