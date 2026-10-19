import Foundation

/// An event as the Next selection sees it. Callers drop what is not a candidate first.
public struct NextUpEntry: Equatable, Sendable {
    public let id: String
    public let startsAt: Date
    public let endsAt: Date

    public init(id: String, startsAt: Date, endsAt: Date) {
        self.id = id
        self.startsAt = startsAt
        self.endsAt = endsAt
    }
}

/// Which event the menu bar Next card, the Overview Next up list and `calopod join` treat as next.
///
/// Candidates are timed, not declined, not cancelled, not Calopod copies, from calendars that are
/// shown. A maybe counts. For a candidate that is running, the one that started last is current.
/// While now is within `lateJoinWindow` of its start, the current event is the primary one and the
/// next upcoming event is the secondary line. After that the next upcoming event is primary and
/// the current one is a small "In ... until" line. With nothing upcoming the current event stays
/// primary until it ends. An event that has ended is never returned.
public struct NextUpSelection: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// Running now, still inside the first ten minutes.
        case current
        /// Running now and past the first ten minutes, shown beside a later event.
        case inProgress
        /// Starts after now.
        case upcoming
    }

    public struct Line: Equatable, Sendable {
        public let event: NextUpEntry
        public let role: Role
    }

    public let primary: Line?
    public let secondary: Line?
    /// Other events running now besides the current one.
    public let alsoRunning: [NextUpEntry]

    /// The first ten minutes of a meeting, during which it still counts as the one to join.
    public static let lateJoinWindow: TimeInterval = 10 * 60

    public static func select(_ events: [NextUpEntry], now: Date) -> NextUpSelection {
        let live = events.filter { $0.endsAt > now }
        let running = live.filter { $0.startsAt <= now }
            .sorted { ($0.startsAt, $0.id) > ($1.startsAt, $1.id) }
        let upcoming = live.filter { $0.startsAt > now }
            .min { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
        let current = running.first
        let others = Array(running.dropFirst())

        switch (current, upcoming) {
        case let (current?, upcoming?):
            if now < current.startsAt.addingTimeInterval(lateJoinWindow) {
                return NextUpSelection(
                    primary: Line(event: current, role: .current),
                    secondary: Line(event: upcoming, role: .upcoming), alsoRunning: others)
            }
            return NextUpSelection(
                primary: Line(event: upcoming, role: .upcoming),
                secondary: Line(event: current, role: .inProgress), alsoRunning: others)
        case let (current?, nil):
            return NextUpSelection(primary: Line(event: current, role: .current), secondary: nil, alsoRunning: others)
        case let (nil, upcoming?):
            return NextUpSelection(primary: Line(event: upcoming, role: .upcoming), secondary: nil, alsoRunning: [])
        case (nil, nil):
            return NextUpSelection(primary: nil, secondary: nil, alsoRunning: [])
        }
    }

    /// The next moment the selection can change for these events, so a view can sleep until then.
    /// That is a start, an end, or ten minutes after a start, whichever comes first after now.
    public static func nextChange(_ events: [NextUpEntry], after now: Date) -> Date? {
        events.flatMap { [$0.startsAt, $0.startsAt.addingTimeInterval(lateJoinWindow), $0.endsAt] }
            .filter { $0 > now }.min()
    }
}
