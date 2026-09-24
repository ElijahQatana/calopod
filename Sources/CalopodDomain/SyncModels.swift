import Foundation

public enum SyncMode: String, Codable, Sendable {
    case apply
    case dryRun = "dry-run"
}

public enum SyncWindowError: Error, Equatable {
    case endMustFollowStart
}

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

public struct SyncRequest: Codable, Equatable, Sendable {
    public let mode: SyncMode
    public let window: SyncWindow?

    public init(mode: SyncMode, window: SyncWindow? = nil) {
        self.mode = mode
        self.window = window
    }
}

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
