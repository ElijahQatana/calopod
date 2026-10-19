import CalopodSnapshot
import Foundation

/// Synthetic data for previews, tests and the simulator. Nothing here comes from a real calendar.
struct FixtureReader: SnapshotReader {
    enum Scenario: String, Sendable {
        case fresh, stale, sharingOff, nothingPublished, offline
    }

    var scenario: Scenario = .fresh
    var now: Date = .now

    func read() async throws -> SnapshotResult {
        switch scenario {
        case .fresh: .snapshot(Self.snapshot(publishedAt: now.addingTimeInterval(-420), now: now))
        case .stale: .snapshot(Self.snapshot(publishedAt: now.addingTimeInterval(-3 * 3600), now: now))
        case .sharingOff: .sharingOff
        case .nothingPublished: .nothingPublished
        case .offline: throw ReaderError.unavailable
        }
    }

    static func snapshot(publishedAt: Date, now: Date) -> Snapshot {
        let calendar = Calendar.current
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now))!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let planning = InboxItem(
            id: "fixture-1", reasons: [.needsRSVP, .conflict], title: "Quarterly planning",
            startsAt: at(0, 13, 30), endsAt: at(0, 15), calendarID: "work", response: .needsResponse,
            location: "Room 4B", conflicts: [ConflictingEvent(title: "School pickup", startsAt: at(0, 14, 15), endsAt: at(0, 14, 45))])
        let pickup = InboxItem(
            id: "fixture-2", reasons: [.conflict], title: "School pickup",
            startsAt: at(0, 14, 15), endsAt: at(0, 14, 45), calendarID: "family", response: .accepted)
        let review = InboxItem(
            id: "fixture-3", reasons: [.unreadChange], title: "Design review", startsAt: at(1, 10),
            endsAt: at(1, 11), calendarID: "client", response: .accepted)
        let vendor = InboxItem(
            id: "fixture-4", reasons: [.maybe], title: "Vendor call", startsAt: at(1, 16),
            endsAt: at(1, 16, 30), calendarID: "work", response: .tentative)
        let dinner = InboxItem(
            id: "fixture-5", reasons: [.unreadChange], changeOrderUncertain: true, title: "Dinner with a friend",
            startsAt: at(3, 19), endsAt: at(3, 21), calendarID: "personal", response: .accepted)
        let busy = (0..<5).map { day in
            AvailabilityDay(
                day: Self.dayKey(at(day, 0), calendar: calendar), timeZoneIdentifier: calendar.timeZone.identifier,
                busy: [BusyInterval(start: at(day, 9), end: at(day, 10, 30)), BusyInterval(start: at(day, 13), end: at(day, 15))])
        }
        return Snapshot(
            publishedAt: publishedAt,
            inbox: [planning, pickup, review, vendor, dinner],
            availability: busy,
            calendars: [
                CalendarEntry(id: "work", name: "Work", colorIndex: 6),
                CalendarEntry(id: "personal", name: "Personal", colorIndex: 4),
                CalendarEntry(id: "family", name: "Family", colorIndex: 8),
                CalendarEntry(id: "client", name: "Client", colorIndex: 9),
            ],
            status: SyncStatus(
                lastSyncAt: publishedAt,
                issues: [SyncIssue(kind: .stale, calendarID: "client", since: now.addingTimeInterval(-86400))]))
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
