import GRDB

extension CalopodDatabase {
    public static let supportedMigrationIdentifiers = [
        "v1_foundation",
        "v2_calendar_sources",
        "v3_normalized_event_details",
        "v4_main_calendar",
        "v5_full_event_details",
        "v6_sync_run_summaries",
        "v7_agent_control",
        "v8_arm_names",
        "v9_event_response",
        "v10_inbox_observations",
        "v11_inbox_context_settings",
        "v12_inbox_rsvp_actions",
        "v13_inbox_review_sessions",
        "v14_all_day_time_zone",
        "v15_refresh_retention_indexes",
        "v16_calendar_provider_color",
        "v17_copy_external_id",
        "v18_calendar_preferences",
        "v19_calendar_view_hidden",
        "v20_notification_settings",
        "v21_working_hours",
        "v22_iphone_feed",
        "v23_iphone_calendars",
        "v24_iphone_feed_zone",
        "v25_arm_filters",
        "v26_arm_label",
        "v27_arm_padding",
        "v28_arm_sync_health",
        "v29_inbox_snoozes",
        "v30_inbox_digest",
    ]

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

        migrator.registerMigration("v2_calendar_sources") { database in
            try database.alter(table: "calendar_bindings") { table in
                table.add(column: "provider_source_id", .text)
                table.add(column: "provider_source_type", .text)
                table.add(column: "provider_source_label", .text)
            }
        }

        migrator.registerMigration("v3_normalized_event_details") { database in
            try database.alter(table: "normalized_instances") { table in
                table.add(column: "title", .text)
                table.add(column: "is_private", .boolean).notNull().defaults(to: false)
                table.add(column: "provider_updated_at", .datetime)
            }
        }

        migrator.registerMigration("v4_main_calendar") { database in
            try database.alter(table: "arms") { table in
                table.add(column: "is_main", .boolean).notNull().defaults(to: false)
            }
            try database.execute(
                sql: """
                    CREATE UNIQUE INDEX arms_one_main_calendar
                    ON arms (is_main)
                    WHERE is_main = 1
                    """
            )
        }

        migrator.registerMigration("v5_full_event_details") { database in
            try database.alter(table: "normalized_instances") { table in
                table.add(column: "location", .text)
                table.add(column: "notes", .text)
                table.add(column: "url", .text)
                table.add(column: "organizer_json", .blob)
                table.add(column: "attendees_json", .blob)
            }
        }

        migrator.registerMigration("v6_sync_run_summaries") { database in
            try database.alter(table: "sync_runs") { table in
                table.add(column: "trigger", .text).notNull().defaults(to: "manual")
                table.add(column: "planned_count", .integer).notNull().defaults(to: 0)
                table.add(column: "applied_count", .integer).notNull().defaults(to: 0)
                table.add(column: "reconciled_count", .integer).notNull().defaults(to: 0)
                table.add(column: "no_op_count", .integer).notNull().defaults(to: 0)
                table.add(column: "warning_count", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v7_agent_control") { database in
            try database.create(table: "agent_control") { table in
                table.column("id", .text).primaryKey()
                table.column("is_paused", .boolean).notNull().defaults(to: false)
                table.column("updated_at", .datetime).notNull()
            }
        }

        migrator.registerMigration("v8_arm_names") { database in
            try database.alter(table: "arms") { table in
                table.add(column: "name", .text)
            }
        }

        migrator.registerMigration("v9_event_response") { database in
            try database.alter(table: "normalized_instances") { table in
                table.add(column: "response_json", .blob)
            }
            try database.alter(table: "calendar_bindings") { table in
                table.add(column: "response_identity_scope", .text)
                    .notNull().defaults(to: "unverified")
            }
        }

        migrator.registerMigration("v10_inbox_observations") { database in
            // Calendar discovery can lose a binding temporarily. Only removing
            // its Connection should cascade private observation detail.
            try database.create(table: "inbox_observations") { table in
                table.column("source_key_hash", .text).primaryKey()
                table.column("connection_id", .text).notNull()
                    .references("connections", onDelete: .cascade)
                table.column("calendar_binding_id", .text).notNull()
                table.column("snapshot", .blob).notNull()
            }
            try database.create(table: "inbox_activity") { table in
                table.column("source_key_hash", .text).notNull()
                    .references("inbox_observations", onDelete: .cascade)
                table.column("revision", .integer).notNull()
                table.column("observed_at", .datetime).notNull()
                table.column("acknowledged_at", .datetime)
                table.column("snapshot", .blob).notNull()
                table.primaryKey(["source_key_hash", "revision"])
            }
            try database.create(table: "inbox_coverage") { table in
                table.column("connection_id", .text).notNull()
                    .references("connections", onDelete: .cascade)
                table.column("calendar_binding_id", .text).notNull()
                table.column("starts_at", .datetime).notNull()
                table.column("ends_at", .datetime).notNull()
                table.column("observed_at", .datetime).notNull()
                table.primaryKey(["connection_id", "calendar_binding_id"])
            }
        }

        migrator.registerMigration("v11_inbox_context_settings") { database in
            try database.execute(sql: """
                CREATE TABLE inbox_context_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    before_minutes INTEGER NOT NULL CHECK (before_minutes BETWEEN 0 AND 10080),
                    after_minutes INTEGER NOT NULL CHECK (after_minutes BETWEEN 0 AND 10080),
                    CHECK (before_minutes + after_minutes > 0)
                )
                """)
        }

        migrator.registerMigration("v12_inbox_rsvp_actions") { database in
            try database.create(table: "inbox_rsvp_actions") { table in
                table.column("id", .text).primaryKey()
                table.column("target", .blob).notNull()
                table.column("status", .text).notNull()
                table.column("record", .blob).notNull()
            }
        }

        migrator.registerMigration("v13_inbox_review_sessions") { database in
            try database.alter(table: "normalized_instances") { table in
                table.add(column: "provider_series_id", .text)
            }
            try database.execute(sql: """
                CREATE TABLE inbox_review_sessions (
                    id TEXT PRIMARY KEY, generation INTEGER NOT NULL,
                    updated_at DATETIME NOT NULL, completed INTEGER NOT NULL,
                    has_unresolved_actions INTEGER NOT NULL, snapshot BLOB NOT NULL
                );
                CREATE TABLE inbox_review_session_connections (
                    session_id TEXT NOT NULL REFERENCES inbox_review_sessions(id) ON DELETE CASCADE,
                    connection_id TEXT NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
                    PRIMARY KEY (session_id, connection_id)
                );
                CREATE TRIGGER inbox_review_connection_removal BEFORE DELETE ON connections
                BEGIN
                    DELETE FROM inbox_review_sessions WHERE id IN (
                        SELECT session_id FROM inbox_review_session_connections WHERE connection_id = OLD.id
                    );
                END;
                """)
        }

        migrator.registerMigration("v14_all_day_time_zone") { database in
            try database.alter(table: "normalized_instances") { table in
                table.add(column: "time_zone", .text)
            }
        }

        migrator.registerMigration("v15_refresh_retention_indexes") { database in
            try database.alter(table: "normalized_instances") { table in
                table.add(column: "last_seen_at", .datetime)
            }
            try database.create(index: "normalized_instances_binding_generation",
                                on: "normalized_instances", columns: ["calendar_binding_id", "seen_generation"])
            try database.create(index: "normalized_instances_binding_window",
                                on: "normalized_instances", columns: ["calendar_binding_id", "starts_at", "ends_at"])
            try database.create(index: "sync_runs_retention", on: "sync_runs", columns: ["status", "finished_at"])
            try database.create(index: "sync_operations_mirror", on: "sync_operations", columns: ["mirror_key"])
        }

        migrator.registerMigration("v16_calendar_provider_color") { database in
            try database.alter(table: "calendar_bindings") { table in
                table.add(column: "provider_color", .text)
            }
        }

        // The event id of an EventKit copy can change when its calendar syncs, so the copy's
        // server-assigned id is kept as well.
        migrator.registerMigration("v17_copy_external_id") { database in
            try database.alter(table: "mirror_mappings") { table in
                table.add(column: "provider_external_id", .text)
            }
            try database.alter(table: "normalized_instances") { table in
                table.add(column: "provider_external_id", .text)
            }
        }

        // Names, ignores and colors chosen on this Mac. Keyed by calendar id with no foreign key, so a
        // choice is kept when a calendar drops out of a refresh and comes back. A null column means
        // never chosen.
        migrator.registerMigration("v18_calendar_preferences") { database in
            try database.execute(sql: """
                CREATE TABLE calendar_preferences (
                    calendar_id TEXT PRIMARY KEY,
                    connection_id TEXT,
                    alias TEXT,
                    is_ignored INTEGER,
                    color TEXT
                );
                CREATE TABLE calendar_preferences_import (id INTEGER PRIMARY KEY CHECK (id = 1));
                """)
        }

        // Calendars hidden in one Calendar view (all, sources, destinations). A row only exists while the
        // calendar is hidden, so one that is new to a view is shown. No foreign key, as with preferences.
        migrator.registerMigration("v19_calendar_view_hidden") { database in
            try database.execute(sql: """
                CREATE TABLE calendar_view_hidden (
                    view TEXT NOT NULL,
                    calendar_id TEXT NOT NULL,
                    PRIMARY KEY (view, calendar_id)
                ) WITHOUT ROWID;
                """)
        }

        // Meeting reminders. One row, like the Inbox context margins.
        migrator.registerMigration("v20_notification_settings") { database in
            try database.execute(sql: """
                CREATE TABLE notification_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    enabled INTEGER NOT NULL,
                    first_enabled INTEGER NOT NULL,
                    first_minutes INTEGER NOT NULL CHECK (first_minutes BETWEEN 1 AND 120),
                    final_enabled INTEGER NOT NULL,
                    final_minutes INTEGER NOT NULL CHECK (final_minutes BETWEEN 1 AND 120),
                    hide_titles INTEGER NOT NULL
                );
                """)
        }

        // Working hours per weekday, 1 is Monday. A day off has no times.
        migrator.registerMigration("v21_working_hours") { database in
            try database.execute(sql: """
                CREATE TABLE working_hours (
                    weekday INTEGER PRIMARY KEY CHECK (weekday BETWEEN 1 AND 7),
                    start_minute INTEGER,
                    end_minute INTEGER,
                    CHECK ((start_minute IS NULL AND end_minute IS NULL)
                        OR (start_minute >= 0 AND end_minute <= 1440 AND start_minute < end_minute))
                );
                """)
        }

        // Whether this Mac publishes a read-only copy for the iPhone, and how the last upload went.
        // One row. `published_run_id` is the sync run the last upload was built from.
        migrator.registerMigration("v22_iphone_feed") { database in
            try database.execute(sql: """
                CREATE TABLE iphone_feed (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    is_enabled INTEGER NOT NULL,
                    remove_pending INTEGER NOT NULL DEFAULT 0,
                    published_run_id TEXT,
                    published_at DATETIME,
                    failed_at DATETIME,
                    failure TEXT
                )
                """)
        }

        // The calendars whose events go to the iPhone. A calendar is here only while it is chosen.
        migrator.registerMigration("v23_iphone_calendars") { database in
            try database.execute(sql: "CREATE TABLE iphone_calendars (calendar_id TEXT PRIMARY KEY)")
        }

        // This Mac's zone id and share state. One row, made on first use.
        migrator.registerMigration("v24_iphone_feed_zone") { database in
            try database.execute(sql: """
                CREATE TABLE iphone_feed_zone (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    mac_id TEXT NOT NULL,
                    busy_shared INTEGER NOT NULL DEFAULT 0,
                    legacy_removed INTEGER NOT NULL DEFAULT 0
                )
                """)
        }

        // What an Arm leaves out.
        migrator.registerMigration("v25_arm_filters") { database in
            try database.alter(table: "arms") { table in
                table.add(column: "skip_declined", .boolean).notNull().defaults(to: false)
                table.add(column: "skip_all_day", .boolean).notNull().defaults(to: false)
                table.add(column: "skip_dont_clone", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v26_arm_label") { database in
            try database.alter(table: "arms") { table in
                table.add(column: "copy_label", .text)
            }
        }

        migrator.registerMigration("v27_arm_padding") { database in
            try database.alter(table: "arms") { table in
                table.add(column: "pad_before_minutes", .integer).notNull().defaults(to: 0)
                table.add(column: "pad_after_minutes", .integer).notNull().defaults(to: 0)
                table.add(column: "pad_in_person_only", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v28_arm_sync_health") { database in
            try database.create(table: "arm_sync_health") { table in
                table.column("arm_id", .text).primaryKey().references("arms", onDelete: .cascade)
                table.column("last_success_at", .datetime)
                table.column("last_error", .text)
                table.column("waiting", .integer)
            }
        }

        // No foreign key, so a snooze outlasts a refresh that drops the event for a while.
        migrator.registerMigration("v29_inbox_snoozes") { database in
            try database.create(table: "inbox_snoozes") { table in
                table.column("source_key_hash", .text).primaryKey()
                table.column("until", .datetime).notNull()
                table.column("revision", .integer).notNull()
                table.column("conflict_keys", .text).notNull()
            }
        }

        // One row, like the meeting reminders. No time means the start of the working day.
        migrator.registerMigration("v30_inbox_digest") { database in
            try database.execute(sql: """
                CREATE TABLE inbox_digest_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    enabled INTEGER NOT NULL,
                    minute INTEGER CHECK (minute BETWEEN 0 AND 1439)
                );
                """)
        }

        return migrator
    }
}
