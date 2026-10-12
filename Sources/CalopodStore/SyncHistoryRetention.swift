import Foundation
import GRDB

extension LocalStateRepository {
    public func pruneSyncHistory(now: Date = Date()) throws {
        try database.writeTransaction { database in
            try pruneSyncHistory(database, now: now)
        }
    }

    func pruneSyncHistory(_ database: Database, now: Date) throws {
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        try database.execute(sql: """
            DELETE FROM sync_runs
            WHERE status IN ('succeeded', 'failed') AND finished_at < ?
              AND NOT EXISTS (
                  SELECT 1 FROM sync_operations
                  WHERE run_id = sync_runs.id AND status <> 'succeeded'
              )
            """, arguments: [cutoff])

        // Age alone cannot retire deletion proof. A returned source supersedes it.
        try database.execute(sql: """
            DELETE FROM tombstones
            WHERE observed_at < ?
              AND EXISTS (
                  SELECT 1 FROM normalized_instances
                  WHERE source_key_hash = tombstones.source_key_hash AND is_cancelled = 0
                    AND last_seen_at > tombstones.observed_at
              )
              AND NOT EXISTS (
                  SELECT 1 FROM mirror_mappings WHERE mirror_key = tombstones.mirror_key
              )
              AND NOT EXISTS (
                  SELECT 1 FROM sync_operations WHERE mirror_key = tombstones.mirror_key
              )
            """, arguments: [cutoff])
    }
}
