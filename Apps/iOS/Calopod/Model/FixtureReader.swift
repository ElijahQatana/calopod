import CalopodDomain
import CalopodSnapshot
import Foundation

/// Synthetic data for previews, tests and the simulator. Nothing here comes from a real calendar.
struct FixtureReader: SnapshotReader {
    enum Scenario: String, Sendable {
        case fresh, stale, noCalendars, sharingOff, nothingPublished, offline
    }

    var scenario: Scenario = .fresh
    var now: Date = .now

    func read() async throws -> SnapshotResult {
        switch scenario {
        case .fresh: .snapshot(Self.snapshot(publishedAt: now.addingTimeInterval(-420), now: now))
        case .stale: .snapshot(Self.snapshot(publishedAt: now.addingTimeInterval(-3 * 3600), now: now))
        case .noCalendars:
            .snapshot({
                var snapshot = Self.snapshot(publishedAt: now.addingTimeInterval(-420), now: now)
                snapshot.days = []
                return snapshot
            }())
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
            startsAt: at(0, 13, 30), endsAt: at(0, 15), sourceName: "work@example.com", calendarID: "work",
            response: .needsResponse, organizerName: "Dana Whitfield",
            attendees: AttendeeSummary(total: 9, accepted: 5, tentative: 1, declined: 1),
            location: "Room 4B, 12 Example Street", notes: "Bring the draft roadmap.", url: "https://example.com/planning",
            conflicts: [ConflictingEvent(title: "School pickup", startsAt: at(0, 14, 15), endsAt: at(0, 14, 45))])
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
                busy: [BusyInterval(start: at(day, 9), end: at(day, 10, 30)), BusyInterval(start: at(day, 13), end: at(day, 15))]
                    + (day == 0 ? [BusyInterval(start: at(0, 22, 30), end: at(1, 0, 30))] : []))
        }
        let events = [
            event("e1", "work", "Team standup", at(0, 9), at(0, 9, 30)),
            event("e2", "work", "Quarterly planning", at(0, 13, 30), at(0, 15), location: "Room 4B, 12 Example Street", response: .needsResponse),
            event("e3", "family", "School pickup", at(0, 14, 15), at(0, 14, 45)),
            event("e4", "personal", nil, at(0, 14), at(0, 16)),
            event("e5", "work", "Planning offsite", at(0, 0), at(1, 0), allDay: true),
            event("e6", "personal", "Late flight", at(0, 22, 30), at(1, 0, 30), location: "Gate 12"),
            event("e7", "client", "Design review", at(1, 10), at(1, 11), response: .accepted),
            event("e8", "work", "Vendor call", at(1, 16), at(1, 16, 30), response: .tentative),
            event("e9", "personal", "Dinner with a friend", at(3, 19), at(3, 21)),
            event("e10", "family", "Grandma visiting", at(2, 0), at(4, 0), allDay: true),
        ]
        return Snapshot(
            publishedAt: publishedAt,
            inbox: [planning, pickup, review, vendor, dinner],
            availability: busy,
            days: (0..<5).compactMap { offset in
                let start = at(offset, 0), end = at(offset + 1, 0)
                let today = events.filter { $0.endsAt > start && $0.startsAt < end }
                return today.isEmpty ? nil : CalendarDay(
                    day: Self.dayKey(start, calendar: calendar), timeZoneIdentifier: calendar.timeZone.identifier, events: today)
            },
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

    private static func event(
        _ id: String, _ calendarID: String, _ title: String?, _ start: Date, _ end: Date,
        allDay: Bool = false, location: String? = nil, response: EventResponseState = .organizer
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, calendarID: calendarID, title: title, startsAt: start, endsAt: end, isAllDay: allDay,
            location: location, response: response)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
