import CalopodSnapshot
import Foundation

/// Everything the phone shows, as of one publish from the Mac.
struct Snapshot: Codable, Equatable, Sendable {
    var publishedAt: Date
    var inbox: [InboxItem]
    var availability: [AvailabilityDay]
    var calendars: [CalendarEntry]
    var status: SyncStatus

    func calendar(for id: String) -> CalendarEntry? { calendars.first { $0.id == id } }
}

enum SnapshotResult: Equatable, Sendable {
    /// The Mac has not turned on sharing with the iPhone.
    case sharingOff
    /// Sharing is on but nothing has been published yet.
    case nothingPublished
    case snapshot(Snapshot)
}

enum ReaderError: Error, Equatable {
    /// The Mac wrote a newer format than this app understands.
    case needsNewerApp
    /// No iCloud account on this phone, so there is nothing to read from.
    case signedOut
    case unavailable
}

/// Where snapshots come from. Reading is all the phone does.
protocol SnapshotReader: Sendable {
    func read() async throws -> SnapshotResult
}
