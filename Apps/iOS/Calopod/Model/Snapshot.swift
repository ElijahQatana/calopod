import CalopodSnapshot
import Foundation

/// Everything the phone shows, as of one publish from the Mac.
struct Snapshot: Codable, Equatable, Sendable {
    var publishedAt: Date
    var inbox: [InboxItem]
    var availability: [AvailabilityDay]
    /// Events of the calendars chosen on the Mac. Empty when none is chosen.
    var days: [CalendarDay] = []
    /// The Mac's meeting reminder choices. Nil when the Mac has not published them, and then the phone sets no reminders.
    var reminders: ReminderSettings?
    var calendars: [CalendarEntry]
    var status: SyncStatus

    func calendar(for id: String) -> CalendarEntry? { calendars.first { $0.id == id } }
}

extension Snapshot {
    /// A copy saved before events or reminders existed has no `days` or `reminders`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        publishedAt = try container.decode(Date.self, forKey: .publishedAt)
        inbox = try container.decode([InboxItem].self, forKey: .inbox)
        availability = try container.decode([AvailabilityDay].self, forKey: .availability)
        days = try container.decodeIfPresent([CalendarDay].self, forKey: .days) ?? []
        reminders = try container.decodeIfPresent(ReminderSettings.self, forKey: .reminders)
        calendars = try container.decode([CalendarEntry].self, forKey: .calendars)
        status = try container.decode(SyncStatus.self, forKey: .status)
    }

    private enum CodingKeys: String, CodingKey { case publishedAt, inbox, availability, days, reminders, calendars, status }
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
