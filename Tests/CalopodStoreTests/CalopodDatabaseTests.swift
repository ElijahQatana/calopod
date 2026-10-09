@testable import CalopodStore
import Foundation
import GRDB
import Testing

private enum ExpectedFailure: Error {
    case rollback
}

@Test
func foundationMigrationCreatesEveryStateTable() throws {
    let store = try CalopodDatabase.inMemory()
    let expectedTables = [
        "agent_control",
        "arm_sources",
        "arms",
        "calendar_bindings",
        "configurations",
        "connection_health",
        "connections",
        "devices",
        "mirror_mappings",
        "normalized_instances",
        "provider_cursors",
        "sync_operations",
        "sync_runs",
        "tombstones",
    ]

    let tables = try store.read { database in
        try String.fetchAll(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        )
    }

    for table in expectedTables {
        #expect(tables.contains(table))
    }

    try store.migrate()

    let armColumns = try store.read { database in
        try Row.fetchAll(database, sql: "PRAGMA table_info(arms)")
            .map { row in row["name"] as String }
    }
    #expect(armColumns.contains("is_main"))

    let eventColumns = try store.read { database in
        try Row.fetchAll(database, sql: "PRAGMA table_info(normalized_instances)")
            .map { row in row["name"] as String }
    }
    for column in ["location", "notes", "url", "organizer_json", "attendees_json"] {
        #expect(eventColumns.contains(column))
    }
}

@Test
func failedTransactionRollsBackEveryWrite() throws {
    let store = try CalopodDatabase.inMemory()

    #expect(throws: ExpectedFailure.rollback) {
        try store.writeTransaction { database in
            try database.execute(
                sql: "INSERT INTO configurations (id, created_at, updated_at) VALUES (?, ?, ?)",
                arguments: ["configuration-1", Date(), Date()]
            )
            throw ExpectedFailure.rollback
        }
    }

    let count = try store.read { database in
        try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM configurations")
    }
    #expect(count == 0)
}

@Test
func stateSchemaHasNoCredentialColumns() throws {
    let store = try CalopodDatabase.inMemory()
    let disallowedFragments = ["access_token", "refresh_token", "password", "client_secret"]

    let columnNames = try store.read { database in
        let tables = try String.fetchAll(
            database,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
        )

        return try tables.flatMap { table in
            try Row.fetchAll(database, sql: "PRAGMA table_info(\(table.quotedDatabaseIdentifier))")
                .map { row in row["name"] as String }
        }
    }

    for columnName in columnNames {
        for fragment in disallowedFragments {
            #expect(!columnName.localizedCaseInsensitiveContains(fragment))
        }
    }
}

@Test
func v6StateSurvivesTheAgentControlMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-v6-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state.sqlite").path
    let timestamp = Date(timeIntervalSince1970: 1_000)

    do {
        let database = try DatabaseQueue(path: path)
        try CalopodDatabase.migrator.migrate(database, upTo: "v6_sync_run_summaries")
        try database.write { database in
            try database.execute(
                sql: "INSERT INTO configurations VALUES (?, ?, ?)",
                arguments: ["default", timestamp, timestamp]
            )
            try database.execute(
                sql: """
                    INSERT INTO connections
                        (id, configuration_id, provider, display_label, is_enabled,
                         created_at, updated_at)
                    VALUES (?, ?, ?, ?, 1, ?, ?)
                    """,
                arguments: [
                    "connection", "default", "eventkit", "Synthetic connection",
                    timestamp, timestamp,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO calendar_bindings
                        (id, connection_id, provider_calendar_id, display_label,
                         is_selected, is_read_only, created_at)
                    VALUES
                        (?, ?, ?, ?, 1, 0, ?),
                        (?, ?, ?, ?, 0, 0, ?)
                    """,
                arguments: [
                    "source", "connection", "source-provider", "Synthetic source", timestamp,
                    "target", "connection", "target-provider", "Synthetic target", timestamp,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO arms
                        (id, configuration_id, target_binding_id, rule_mode,
                         is_enabled, is_main, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 1, 0, ?, ?)
                    """,
                arguments: ["arm", "default", "target", "busy", timestamp, timestamp]
            )
            try database.execute(
                sql: "INSERT INTO arm_sources VALUES (?, ?)",
                arguments: ["arm", "source"]
            )
            try database.execute(
                sql: """
                    INSERT INTO mirror_mappings
                        (mirror_key, arm_id, source_key_hash, provider_event_id,
                         provider_version, desired_fingerprint, ownership_key_id, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "mirror", "arm", "source-hash", "managed-event", "version",
                    "fingerprint", "ownership-key", timestamp,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO sync_runs
                        (id, mode, trigger, status, started_at, finished_at,
                         planned_count, applied_count, reconciled_count,
                         no_op_count, warning_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "run", "apply", "automatic", "succeeded", timestamp, timestamp,
                    4, 1, 1, 2, 0,
                ]
            )
        }
    }

    let repository = LocalStateRepository(database: try CalopodDatabase(path: path))

    #expect(try repository.connections().map(\.id) == ["connection"])
    #expect(try repository.arms().map(\.id) == ["arm"])
    #expect(try repository.arms().first?.sourceBindingIDs == ["source"])
    #expect(try repository.mirrorMappings(armID: "arm").map(\.mirrorKey) == ["mirror"])
    #expect(try repository.latestSyncRun(trigger: "automatic")?.id == "run")
    #expect(try repository.latestSyncRun(trigger: "automatic")?.plannedCount == 4)
    #expect(try repository.agentControl().isPaused == false)
}

@Test
func v7StateSurvivesTheArmNameMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-v7-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state.sqlite").path
    let timestamp = Date(timeIntervalSince1970: 1_000)

    do {
        let database = try DatabaseQueue(path: path)
        try CalopodDatabase.migrator.migrate(database, upTo: "v7_agent_control")
        try database.write { database in
            try database.execute(
                sql: "INSERT INTO configurations VALUES (?, ?, ?)",
                arguments: ["default", timestamp, timestamp]
            )
            try database.execute(
                sql: """
                    INSERT INTO connections
                        (id, configuration_id, provider, display_label, is_enabled,
                         created_at, updated_at)
                    VALUES (?, ?, ?, ?, 1, ?, ?)
                    """,
                arguments: [
                    "connection", "default", "eventkit", "Synthetic connection",
                    timestamp, timestamp,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO calendar_bindings
                        (id, connection_id, provider_calendar_id, display_label,
                         is_selected, is_read_only, created_at)
                    VALUES
                        (?, ?, ?, ?, 1, 0, ?),
                        (?, ?, ?, ?, 0, 0, ?)
                    """,
                arguments: [
                    "source", "connection", "source-provider", "Synthetic source", timestamp,
                    "target", "connection", "target-provider", "Synthetic target", timestamp,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO arms
                        (id, configuration_id, target_binding_id, rule_mode,
                         is_enabled, is_main, created_at, updated_at)
                    VALUES (?, ?, ?, ?, 1, 0, ?, ?)
                    """,
                arguments: ["arm", "default", "target", "busy", timestamp, timestamp]
            )
            try database.execute(
                sql: "INSERT INTO arm_sources VALUES (?, ?)",
                arguments: ["arm", "source"]
            )
            try database.execute(
                sql: """
                    INSERT INTO mirror_mappings
                        (mirror_key, arm_id, source_key_hash, provider_event_id,
                         provider_version, desired_fingerprint, ownership_key_id, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "mirror", "arm", "source-hash", "managed-event", "version",
                    "fingerprint", "ownership-key", timestamp,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO sync_runs
                        (id, mode, trigger, status, started_at, finished_at,
                         planned_count, applied_count, reconciled_count,
                         no_op_count, warning_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "run", "apply", "automatic", "succeeded", timestamp, timestamp,
                    4, 1, 1, 2, 0,
                ]
            )
        }
    }

    let repository = LocalStateRepository(database: try CalopodDatabase(path: path))

    #expect(try repository.connections().map(\.id) == ["connection"])
    #expect(try repository.arms().map(\.id) == ["arm"])
    #expect(try repository.arms().first?.sourceBindingIDs == ["source"])
    #expect(try repository.mirrorMappings(armID: "arm").map(\.mirrorKey) == ["mirror"])
    #expect(try repository.latestSyncRun(trigger: "automatic")?.id == "run")
    #expect(try repository.latestSyncRun(trigger: "automatic")?.plannedCount == 4)
    #expect(try repository.arms().first?.name == nil)
    #expect(try repository.arms().first?.displayName == "Unnamed Arm")
    _ = try repository.setArmName(id: "arm", name: "Synthetic route")
    let reopened = LocalStateRepository(database: try CalopodDatabase(path: path))
    #expect(try reopened.arm(id: "arm")?.name == "Synthetic route")
    #expect(try reopened.mirrorMappings(armID: "arm") == repository.mirrorMappings(armID: "arm"))
    #expect(try repository.agentControl().isPaused == false)
}

@Test
func failedAgentControlMigrationLeavesV6StateRecoverable() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("calopod-failed-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("state.sqlite").path

    do {
        let database = try DatabaseQueue(path: path)
        try CalopodDatabase.migrator.migrate(database, upTo: "v6_sync_run_summaries")
        try database.write { database in
            try database.execute(
                sql: "INSERT INTO configurations VALUES (?, ?, ?)",
                arguments: [
                    "recoverable",
                    Date(timeIntervalSince1970: 1_000),
                    Date(timeIntervalSince1970: 1_000),
                ]
            )
            try database.create(table: "agent_control") { table in
                table.column("incompatible", .text)
            }
        }
    }

    var migrationFailed = false
    do {
        _ = try CalopodDatabase(path: path)
    } catch {
        migrationFailed = true
    }

    let database = try DatabaseQueue(path: path)
    let evidence = try database.read { database in
        (
            try CalopodDatabase.migrator.appliedMigrations(database),
            try String.fetchAll(database, sql: "SELECT id FROM configurations"),
            try Row.fetchAll(database, sql: "PRAGMA table_info(agent_control)")
                .map { row in row["name"] as String }
        )
    }
    #expect(migrationFailed)
    #expect(evidence.0.last == "v6_sync_run_summaries")
    #expect(evidence.1 == ["recoverable"])
    #expect(evidence.2 == ["incompatible"])
}
