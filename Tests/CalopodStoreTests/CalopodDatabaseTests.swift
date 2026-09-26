import CalopodStore
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
