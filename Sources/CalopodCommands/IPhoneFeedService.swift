import CalopodSnapshot
import CalopodStore
import Foundation

/// Publishes the iPhone feed and keeps its state. Only the Mac app has a publisher; the command line
/// just turns the feed on or off and reads the state.
public struct IPhoneFeedService: Sendable {
    public enum Outcome: Equatable, Sendable {
        case idle
        case published(records: Int)
        case removed
        case failed(String)
    }

    /// After a failed upload, wait this long before trying again on its own.
    static let retryDelay: TimeInterval = 300

    private let makeRepository: @Sendable () throws -> LocalStateRepository
    private let now: @Sendable () -> Date

    public init() {
        makeRepository = { try CommandEnvironment.repository() }
        now = Date.init
    }

    init(makeRepository: @escaping @Sendable () throws -> LocalStateRepository, now: @escaping @Sendable () -> Date = Date.init) {
        self.makeRepository = makeRepository
        self.now = now
    }

    public func state() throws -> StoredIPhoneFeed { try makeRepository().iPhoneFeed() }

    public func setEnabled(_ enabled: Bool) throws { try makeRepository().setIPhoneFeedEnabled(enabled) }

    /// Does whatever is due: removes the remote copy after the feed was turned off, or uploads a new
    /// copy when a sync finished since the last one. A failure is recorded and returned, never thrown,
    /// so it can't fail a sync.
    public func run(publisher: any SnapshotPublisher, force: Bool = false) async -> Outcome {
        let date = now()
        let repository: LocalStateRepository
        let feed: StoredIPhoneFeed
        do {
            repository = try makeRepository()
            feed = try repository.iPhoneFeed()
        } catch {
            return .failed("The sync state could not be read.")
        }
        if !force, let failedAt = feed.failedAt, date.timeIntervalSince(failedAt) < Self.retryDelay { return .idle }
        do {
            if feed.removePending {
                try await publisher.deleteAll()
                try repository.recordIPhoneFeedRemoved()
                return .removed
            }
            guard feed.isEnabled else { return .idle }
            let runID = try repository.latestSuccessfulSyncRun()?.id ?? ""
            guard force || feed.publishedAt == nil || feed.publishedRunID != runID else { return .idle }
            let records = try IPhoneFeedBuilder.records(repository: repository, now: date)
            try await publisher.replaceAll(with: records)
            try repository.recordIPhoneFeedPublished(runID: runID, at: date)
            return .published(records: records.count)
        } catch {
            let message = Self.message(error)
            try? repository.recordIPhoneFeedFailure(message, at: date)
            return .failed(message)
        }
    }

    private static func message(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return String(text.prefix(200))
    }
}
