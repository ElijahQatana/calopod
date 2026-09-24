import GRDB

extension CalopodDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_foundation") { database in
            try database.create(table: "configurations") { table in
                table.column("id", .text).primaryKey()
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "devices") { table in
                table.column("id", .text).primaryKey()
                table.column("configuration_id", .text)
                    .notNull()
                    .references("configurations", onDelete: .cascade)
                table.column("is_current", .boolean).notNull().defaults(to: false)
                table.column("created_at", .datetime).notNull()
            }

            try database.create(table: "connections") { table in
                table.column("id", .text).primaryKey()
                table.column("configuration_id", .text)
                    .notNull()
                    .references("configurations", onDelete: .cascade)
                table.column("provider", .text).notNull()
                table.column("display_label", .text)
                table.column("is_enabled", .boolean).notNull().defaults(to: true)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "calendar_bindings") { table in
                table.column("id", .text).primaryKey()
                table.column("connection_id", .text)
                    .notNull()
                    .references("connections", onDelete: .cascade)
                table.column("provider_calendar_id", .text).notNull()
                table.column("display_label", .text)
                table.column("is_selected", .boolean).notNull().defaults(to: false)
                table.column("is_read_only", .boolean).notNull().defaults(to: false)
                table.column("created_at", .datetime).notNull()
                table.uniqueKey(["connection_id", "provider_calendar_id"])
            }

            try database.create(table: "arms") { table in
                table.column("id", .text).primaryKey()
                table.column("configuration_id", .text)
                    .notNull()
                    .references("configurations", onDelete: .cascade)
                table.column("target_binding_id", .text)
                    .notNull()
                    .references("calendar_bindings", onDelete: .restrict)
                table.column("rule_mode", .text).notNull()
                table.column("preferred_writer_device_id", .text)
                    .references("devices", onDelete: .setNull)
                table.column("is_enabled", .boolean).notNull().defaults(to: true)
                table.column("created_at", .datetime).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "arm_sources") { table in
                table.column("arm_id", .text)
                    .notNull()
                    .references("arms", onDelete: .cascade)
                table.column("calendar_binding_id", .text)
                    .notNull()
                    .references("calendar_bindings", onDelete: .cascade)
                table.primaryKey(["arm_id", "calendar_binding_id"])
            }

            try database.create(table: "provider_cursors") { table in
                table.column("connection_id", .text)
                    .notNull()
                    .references("connections", onDelete: .cascade)
                table.column("calendar_binding_id", .text)
                    .notNull()
                    .references("calendar_bindings", onDelete: .cascade)
                table.column("scope_key", .text).notNull()
                table.column("scope_start", .datetime)
                table.column("scope_end", .datetime)
                table.column("cursor_value", .text).notNull()
                table.column("updated_at", .datetime).notNull()
                table.primaryKey(["connection_id", "calendar_binding_id", "scope_key"])
            }

            try database.create(table: "normalized_instances") { table in
                table.column("source_key_hash", .text).primaryKey()
                table.column("connection_id", .text)
                    .notNull()
                    .references("connections", onDelete: .cascade)
                table.column("calendar_binding_id", .text)
                    .notNull()
                    .references("calendar_bindings", onDelete: .cascade)
                table.column("provider_event_id", .text).notNull()
                table.column("recurrence_id", .text)
                table.column("starts_at", .datetime).notNull()
                table.column("ends_at", .datetime).notNull()
                table.column("is_all_day", .boolean).notNull()
                table.column("availability", .text).notNull()
                table.column("is_cancelled", .boolean).notNull()
                table.column("content_fingerprint", .text).notNull()
                table.column("seen_generation", .integer).notNull()
            }

            try database.create(table: "mirror_mappings") { table in
                table.column("mirror_key", .text).primaryKey()
                table.column("arm_id", .text)
                    .notNull()
                    .references("arms", onDelete: .cascade)
                table.column("source_key_hash", .text).notNull()
                table.column("provider_event_id", .text).notNull()
                table.column("provider_version", .text)
                table.column("desired_fingerprint", .text).notNull()
                table.column("ownership_key_id", .text).notNull()
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "tombstones") { table in
                table.column("source_key_hash", .text).notNull()
                table.column("mirror_key", .text).notNull()
                table.column("proof_cursor_hash", .text)
                table.column("observed_at", .datetime).notNull()
                table.primaryKey(["source_key_hash", "mirror_key"])
            }

            try database.create(table: "sync_runs") { table in
                table.column("id", .text).primaryKey()
                table.column("mode", .text).notNull()
                table.column("status", .text).notNull()
                table.column("started_at", .datetime).notNull()
                table.column("finished_at", .datetime)
                table.column("error_code", .text)
            }

            try database.create(table: "sync_operations") { table in
                table.column("idempotency_key", .text).primaryKey()
                table.column("run_id", .text)
                    .notNull()
                    .references("sync_runs", onDelete: .cascade)
                table.column("mirror_key", .text).notNull()
                table.column("action", .text).notNull()
                table.column("desired_fingerprint", .text).notNull()
                table.column("status", .text).notNull()
                table.column("attempt_count", .integer).notNull().defaults(to: 0)
                table.column("updated_at", .datetime).notNull()
            }

            try database.create(table: "connection_health") { table in
                table.column("connection_id", .text)
                    .primaryKey()
                    .references("connections", onDelete: .cascade)
                table.column("status", .text).notNull()
                table.column("checked_at", .datetime).notNull()
                table.column("stale_since", .datetime)
                table.column("error_code", .text)
            }

            try database.create(
                index: "normalized_instances_window",
                on: "normalized_instances",
                columns: ["starts_at", "ends_at"]
            )
            try database.create(
                index: "mirror_mappings_source",
                on: "mirror_mappings",
                columns: ["source_key_hash"]
            )
            try database.create(
                index: "sync_operations_run_status",
                on: "sync_operations",
                columns: ["run_id", "status"]
            )
        }

        return migrator
    }
}
