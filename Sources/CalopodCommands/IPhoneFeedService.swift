import ArgumentParser
import CalopodSnapshot
import CalopodStore
import Foundation

/// Publishes the iPhone feed and keeps its state. Only the Mac app has a publisher; the command line
/// just turns the feed on or off and reads the state.
public struct IPhoneFeedService: Sendable {
    /// A calendar the phone can get events for, named and colored as on the Calendars screen.
    public struct CalendarChoice: Equatable, Sendable {
        public let id: String
        public let name: String
        public let colorIndex: Int
        public let isChosen: Bool
    }

    public enum Outcome: Equatable, Sendable {
        case idle
        case published(records: Int)
        case removed
        case failed(String)
    }

    /// After a failed upload, wait this long before trying again on its own.
    static let retryDelay: TimeInterval = 300

    public struct Zones: Equatable, Sendable {
        public let full: String
        public let busy: String
    }

    private let makeRepository: @Sendable () throws -> LocalStateRepository
    private let now: @Sendable () -> Date
    private let macName: @Sendable () -> String?

    public init() {
        makeRepository = { try CommandEnvironment.repository() }
        now = Date.init
        macName = Self.systemName
    }

    init(
        makeRepository: @escaping @Sendable () throws -> LocalStateRepository, now: @escaping @Sendable () -> Date = Date.init,
        macName: @escaping @Sendable () -> String? = { "Test Mac" }
    ) {
        self.makeRepository = makeRepository
        self.now = now
        self.macName = macName
    }

    private static func systemName() -> String? {
        #if os(macOS)
        Host.current().localizedName
        #else
        ProcessInfo.processInfo.hostName
        #endif
    }

    public func state() throws -> StoredIPhoneFeed { try makeRepository().iPhoneFeed() }

    public func setEnabled(_ enabled: Bool) throws { try makeRepository().setIPhoneFeedEnabled(enabled) }

    public func zones() throws -> Zones {
        let id = try makeRepository().iPhoneFeedZone().macID
        return Zones(full: SnapshotRemote.zoneName(mac: id), busy: SnapshotRemote.zoneName(mac: id, level: .busy))
    }

    public func busyShared() throws -> Bool { try makeRepository().iPhoneFeedZone().busyShared }

    public func startBusyCopy(publisher: any SnapshotPublisher) async -> Outcome {
        do { try makeRepository().setIPhoneFeedBusyShared(true) } catch { return .failed("The sync state could not be read.") }
        return await run(publisher: publisher, force: true)
    }

    public func endBusyCopy(publisher: any SnapshotPublisher) async throws {
        let zones = try zones()
        try await publisher.deleteZone(zones.busy)
        try makeRepository().setIPhoneFeedBusyShared(false)
    }

    /// Every calendar that is not ignored, with whether its events go to the phone.
    public func calendarChoices() throws -> [CalendarChoice] {
        let repository = try makeRepository()
        let chosen = try repository.iPhoneCalendarIDs()
        return IPhoneFeedBuilder.calendars(try repository.inboxContextSnapshot(), repository: repository).calendars.map {
            CalendarChoice(id: $0.id, name: $0.name, colorIndex: $0.colorIndex, isChosen: chosen.contains($0.id))
        }
    }

    /// Chooses or unchooses a calendar given by identifier or exact name, as on the Calendars screen.
    @discardableResult
    public func setCalendar(_ reference: String, chosen: Bool) throws -> CalendarChoice {
        let choices = try calendarChoices()
        var matches = choices.filter { $0.id == reference }
        if matches.isEmpty { matches = choices.filter { $0.name == reference } }
        guard matches.count == 1, let match = matches.first else {
            throw ValidationError(matches.isEmpty
                ? "No calendar has the identifier or name '\(reference)'. Ignored calendars cannot be chosen."
                : "More than one calendar is named '\(reference)'. Use its identifier.")
        }
        try makeRepository().setIPhoneCalendar(match.id, chosen: chosen)
        return CalendarChoice(id: match.id, name: match.name, colorIndex: match.colorIndex, isChosen: chosen)
    }

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
            let zone = try repository.iPhoneFeedZone()
            let zones = Zones(full: SnapshotRemote.zoneName(mac: zone.macID), busy: SnapshotRemote.zoneName(mac: zone.macID, level: .busy))
            if feed.removePending {
                try await publisher.deleteZone(zones.full)
                try await publisher.deleteZone(zones.busy)
                if !zone.legacyRemoved { try await publisher.deleteZone(SnapshotRemote.legacyZoneName) }
                try repository.recordIPhoneFeedRemoved()
                return .removed
            }
            guard feed.isEnabled else { return .idle }
            let runID = try repository.latestSuccessfulSyncRun()?.id ?? ""
            guard force || feed.publishedAt == nil || feed.publishedRunID != runID else { return .idle }
            let records = try IPhoneFeedBuilder.records(repository: repository, now: date, macName: macName())
            try await publisher.replaceAll(with: records, inZone: zones.full)
            if zone.busyShared {
                try await publisher.replaceAll(with: records.filter { SnapshotLevel.busy.keeps($0.kind) }, inZone: zones.busy)
            }
            // The old shared zone can go now. If this fails it is tried again next time.
            if !zone.legacyRemoved, (try? await publisher.deleteZone(SnapshotRemote.legacyZoneName)) != nil {
                try? repository.recordIPhoneFeedLegacyRemoved()
            }
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
