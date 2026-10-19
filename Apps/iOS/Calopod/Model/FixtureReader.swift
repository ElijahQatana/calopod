import CalopodDomain
import CalopodSnapshot
import Foundation

/// Synthetic data for previews, tests and the simulator. Nothing here comes from a real calendar.
struct FixtureReader: SnapshotReader {
    enum Scenario: String, Sendable {
        case fresh, stale, noCalendars, sharingOff, nothingPublished, offline
        /// A week around a spring clock change in London, and a feed from a Mac that sends busy time only.
        case clockChange, oldMac
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
        case .clockChange:
            .snapshot({
                var snapshot = Self.snapshot(publishedAt: now.addingTimeInterval(-420), now: now)
                snapshot.availability = Self.clockChangeWeek
                return snapshot
            }())
        case .oldMac:
            .snapshot({
                var snapshot = Self.snapshot(publishedAt: now.addingTimeInterval(-420), now: now)
                snapshot.availability = snapshot.availability.map {
                    // An older Mac counted everything busy and sent no outside list.
                    AvailabilityDay(
                        day: $0.day, timeZoneIdentifier: $0.timeZoneIdentifier,
                        busy: ($0.busy + ($0.outside ?? []).map { BusyInterval(start: $0.start, end: $0.end) })
                            .sorted { $0.start < $1.start })
                }
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
        // Hours are decimal: 9.75 is 9:45.
        func span(_ day: Int, _ from: Double, _ to: Double) -> BusyInterval {
            BusyInterval(start: at(day, 0).addingTimeInterval(from * 3600), end: at(day, 0).addingTimeInterval(to * 3600))
        }
        func worked(
            _ day: Int, busy: [(Double, Double)], free: [(Double, Double)], overlaps: Int = 0, status: AvailabilityStatus,
            off: Bool = false, outside: [(Double, Double, HoursSide)] = []
        ) -> AvailabilityDay {
            AvailabilityDay(
                day: Self.dayKey(at(day, 0), calendar: calendar), timeZoneIdentifier: calendar.timeZone.identifier,
                busy: busy.map { span(day, $0, $1) }, working: off ? nil : span(day, 9, 17), free: free.map { span(day, $0, $1) },
                overlaps: overlaps, status: status,
                outside: outside.map { OutsideBlock(start: span(day, $0, $1).start, end: span(day, $0, $1).end, side: $2) })
        }
        let busy = [
            worked(0, busy: [(9, 9.75), (10, 12.75), (13.5, 15), (16.5, 17)], free: [(9.75, 10), (12.75, 13.5), (15, 16.5)], overlaps: 1, status: .overbooked,
                   outside: [(7, 8, .before), (22.5, 24, .after)]),
            worked(1, busy: [(9.5, 12), (13, 15.5), (16, 17)], free: [(9, 9.5), (12, 13), (15.5, 16)], status: .tight),
            // A meeting from 8:30 to 9:30 is split at the start of the day.
            worked(2, busy: [(9, 9.5), (10, 11)], free: [(9.5, 10), (11, 17)], status: .mostlyFree, outside: [(8.5, 9, .before)]),
            worked(3, busy: [], free: [], status: .dayOff, off: true),
            worked(4, busy: [(13, 14)], free: [(9, 13), (14, 17)], status: .mostlyFree),
            worked(5, busy: [], free: [(9, 17)], status: .mostlyFree),
            worked(6, busy: [], free: [], status: .dayOff, off: true, outside: [(10, 11, .dayOff)]),
        ]
        let events = [
            event("e1", "work", "Team standup", at(0, 9), at(0, 9, 30)),
            event("e2", "work", "Quarterly planning", at(0, 13, 30), at(0, 15), location: "Room 4B, 12 Example Street", response: .needsResponse,
                join: "https://example.zoom.us/j/123456789"),
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
            reminders: ReminderSettings(
                enabled: true, firstEnabled: true, firstMinutes: 10, finalEnabled: true, finalMinutes: 1, hideTitles: false),
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

    /// The Sunday is the night the clocks go forward, so the day is 23 hours long and 00:00 to 09:00 is
    /// 8 real hours. The ranges are real dates, as the Mac sends them.
    private static let clockChangeWeek: [AvailabilityDay] = {
        var calendar = Calendar(identifier: .gregorian)
        let zone = TimeZone(identifier: "Europe/London")!
        calendar.timeZone = zone
        func start(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2027, month: 3, day: day))! }
        func span(_ day: Int, _ from: Double, _ to: Double) -> BusyInterval {
            BusyInterval(start: start(day).addingTimeInterval(from * 3600), end: start(day).addingTimeInterval(to * 3600))
        }
        return [
            AvailabilityDay(
                day: "2027-03-27", timeZoneIdentifier: zone.identifier, busy: [span(27, 10, 11)], working: span(27, 9, 17),
                free: [span(27, 9, 10), span(27, 11, 17)], overlaps: 0, status: .mostlyFree),
            AvailabilityDay(
                day: "2027-03-28", timeZoneIdentifier: zone.identifier, busy: [span(28, 2, 3)], working: span(28, 0, 8),
                free: [span(28, 0, 2), span(28, 3, 8)], overlaps: 0, status: .mostlyFree),
            AvailabilityDay(
                day: "2027-03-29", timeZoneIdentifier: zone.identifier, busy: [span(29, 9, 12)], working: span(29, 8, 16),
                free: [span(29, 8, 9), span(29, 12, 16)], overlaps: 0, status: .tight),
        ]
    }()

    private static func event(
        _ id: String, _ calendarID: String, _ title: String?, _ start: Date, _ end: Date,
        allDay: Bool = false, location: String? = nil, response: EventResponseState = .organizer, join: String? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            id: id, calendarID: calendarID, title: title, startsAt: start, endsAt: end, isAllDay: allDay,
            location: location, response: response, joinURL: join)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

/// Notifications for a fixture launch: allowed unless `-fixtureNotifications denied` or `notDetermined` says otherwise.
struct FixtureNotificationCenter: ReminderCenter {
    func permission() async -> NotificationPermission {
        switch UserDefaults.standard.string(forKey: "fixtureNotifications") {
        case "denied": .denied
        case "notDetermined": .notDetermined
        default: .allowed
        }
    }
    func requestPermission() async -> Bool { true }
    func pendingIDs() async -> [String] { [] }
    func add(_ reminder: PlannedReminder) async {}
    func remove(ids: [String]) async {}
}
