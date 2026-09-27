import Foundation
import GRDB

public struct StoredAgentControl: Equatable, Sendable {
    public let isPaused: Bool
    public let updatedAt: Date?

    public init(isPaused: Bool, updatedAt: Date?) {
        self.isPaused = isPaused
        self.updatedAt = updatedAt
    }
}

extension LocalStateRepository {
    public func agentControl() throws -> StoredAgentControl {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT is_paused, updated_at FROM agent_control WHERE id = 'default'"
            ) else {
                return StoredAgentControl(isPaused: false, updatedAt: nil)
            }
            return StoredAgentControl(
                isPaused: row["is_paused"],
                updatedAt: row["updated_at"]
            )
        }
    }

    public func setAgentPaused(_ isPaused: Bool, now: Date = Date()) throws {
        try database.write { database in
            try database.execute(
                sql: """
                    INSERT INTO agent_control (id, is_paused, updated_at)
                    VALUES ('default', ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        is_paused = excluded.is_paused,
                        updated_at = excluded.updated_at
                    """,
                arguments: [isPaused, now]
            )
        }
    }
}
