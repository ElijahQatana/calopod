import Foundation

/// Whether a sync run is allowed to write to providers (`apply`) or should
/// only report what it would do (`dryRun`). Both modes run the exact same
/// planning logic; only whether mutations are actually performed differs.
public enum SyncMode: String, Codable, Sendable {
    case apply
    case dryRun = "dry-run"
}

public enum SyncWindowError: Error, Equatable {
    case endMustFollowStart
}

/// A bounded date range every sync and Availability calculation runs
/// against. Sync never operates over an unbounded range, which keeps
/// provider queries, polling, and plan sizes predictable.
public struct SyncWindow: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) throws {
        guard end > start else {
            throw SyncWindowError.endMustFollowStart
        }

        self.start = start
        self.end = end
    }
}

/// A single sync invocation: which mode to run in and, optionally, an
/// explicit window (a caller that omits it gets the runner's default range).
public struct SyncRequest: Codable, Equatable, Sendable {
    public let mode: SyncMode
    public let window: SyncWindow?

    public init(mode: SyncMode, window: SyncWindow? = nil) {
        self.mode = mode
        self.window = window
    }
}

/// Aggregate counts from one sync run, safe to log or display without
/// exposing any individual event's content.
public struct SyncSummary: Codable, Equatable, Sendable {
    public let mode: SyncMode
    public let window: SyncWindow?
    public let plannedOperationCount: Int
    public let appliedOperationCount: Int

    public init(
        mode: SyncMode,
        window: SyncWindow?,
        plannedOperationCount: Int,
        appliedOperationCount: Int
    ) {
        self.mode = mode
        self.window = window
        self.plannedOperationCount = plannedOperationCount
        self.appliedOperationCount = appliedOperationCount
    }
}
