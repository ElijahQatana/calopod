@testable import CalopodStore
import Foundation
import GRDB
import Testing

@Test
func fullDetailsArmsKeepPrivateEventsAfterTheUpgrade() throws {
    let queue = try DatabaseQueue()
    try CalopodDatabase.migrator.migrate(queue, upTo: "v32_event_flags")
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO configurations VALUES ('configuration', '2026-01-01', '2026-01-01');
            INSERT INTO connections (id, configuration_id, provider, created_at, updated_at)
                VALUES ('connection', 'configuration', 'eventkit', '2026-01-01', '2026-01-01');
            INSERT INTO calendar_bindings (id, connection_id, provider_calendar_id, created_at)
                VALUES ('target', 'connection', 'target', '2026-01-01');
            INSERT INTO arms (id, configuration_id, target_binding_id, rule_mode, created_at, updated_at)
                VALUES ('busy', 'configuration', 'target', 'busy', '2026-01-01', '2026-01-01'),
                       ('label', 'configuration', 'target', 'label', '2026-01-01', '2026-01-01'),
                       ('full', 'configuration', 'target', 'full-details', '2026-01-01', '2026-01-01');
            """)
    }
    try CalopodDatabase.migrator.migrate(queue)
    let included = try queue.read { db in
        try Row.fetchAll(db, sql: "SELECT id, include_private FROM arms ORDER BY id").map { ($0["id"] as String, $0["include_private"] as Bool) }
    }
    #expect(included.map(\.0) == ["busy", "full", "label"])
    #expect(included.map(\.1) == [false, true, false])
}
