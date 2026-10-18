import CalopodStore
import Foundation

/// How one finished sync run ended, as the run strip on Overview draws it.
public enum RunMark: Equatable, Sendable {
    case good, failed

    /// How many runs the strip shows.
    public static let barCount = 12
}

extension LocalStateRepository {
    /// The last finished sync runs, oldest first. A run that was interrupted counts as failed.
    public func recentRunMarks(limit: Int = RunMark.barCount) throws -> [RunMark] {
        try recentSyncRuns(limit: limit).reversed().map { $0.status == "succeeded" ? .good : .failed }
    }
}
