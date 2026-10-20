import CalopodSnapshot
import Foundation
import Observation

/// Which calendars the Calendar tab hides, and whether it shows sources or destinations. It is a choice
/// for this phone only: it is kept here and never changes what the Mac publishes.
@Observable
final class CalendarFilter {
    enum Scope: String, CaseIterable {
        case all = "All", sources = "Sources", destinations = "Destinations"
    }

    private(set) var hidden: Set<String>
    private(set) var scope: Scope
    /// Whether Calopod's copies show on All and Sources. Destinations always shows them.
    private(set) var showCopies: Bool

    private let defaults: UserDefaults
    private static let key = "hiddenCalendars"
    private static let scopeKey = "calendarScope"
    private static let copiesKey = "calendarShowCopies"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: Self.key) ?? [])
        scope = defaults.string(forKey: Self.scopeKey).flatMap(Scope.init(rawValue:)) ?? .all
        showCopies = defaults.bool(forKey: Self.copiesKey)
    }

    func setShowCopies(_ shown: Bool) {
        showCopies = shown
        defaults.set(shown, forKey: Self.copiesKey)
    }

    func setScope(_ scope: Scope) {
        self.scope = scope
        defaults.set(scope.rawValue, forKey: Self.scopeKey)
    }

    func reset() {
        hidden = []
        defaults.set([String](), forKey: Self.key)
    }

    func isShown(_ id: String) -> Bool { !hidden.contains(id) }

    func setShown(_ shown: Bool, for id: String) {
        if shown { hidden.remove(id) } else { hidden.insert(id) }
        defaults.set(hidden.sorted(), forKey: Self.key)
    }

    /// The calendars worth listing: those the Mac sent events for, in the Mac's order.
    static func listed(in snapshot: Snapshot) -> [CalendarEntry] {
        let used = Set(snapshot.days.flatMap(\.events).map(\.calendarID))
        return snapshot.calendars.filter { used.contains($0.id) }
    }
}

extension CalendarFilter {
    /// Whether the Mac said which calendars play which part. A feed from an older Mac does not,
    /// and then there is nothing to pick between.
    static func knowsRoles(in snapshot: Snapshot) -> Bool {
        snapshot.calendars.contains { $0.destination != nil || $0.source != nil }
    }

    /// As on the Mac, a calendar can be a source, a destination, both or neither. A Mac that sends only
    /// `destination` counts every other calendar as a source.
    static func isSource(_ calendar: CalendarEntry) -> Bool { calendar.source ?? (calendar.destination != true) }
    static func isDestination(_ calendar: CalendarEntry) -> Bool { calendar.destination == true }

    /// The scope in use: what was picked, or All when the Mac does not send roles.
    func scope(in snapshot: Snapshot) -> Scope { Self.knowsRoles(in: snapshot) ? scope : .all }

    static func hasCopies(in snapshot: Snapshot) -> Bool {
        snapshot.days.contains { $0.events.contains(where: \.isCopy) }
    }

    func drawsCopies(in snapshot: Snapshot) -> Bool { scope(in: snapshot) == .destinations || showCopies }

    func inScope(_ calendar: CalendarEntry, in snapshot: Snapshot) -> Bool {
        switch scope(in: snapshot) {
        case .all: true
        case .sources: Self.isSource(calendar)
        case .destinations: Self.isDestination(calendar)
        }
    }

    /// Everything the schedule leaves out: calendars hidden by hand and those outside the scope.
    func hiding(in snapshot: Snapshot) -> Set<String> {
        hidden.union(snapshot.calendars.filter { !inScope($0, in: snapshot) }.map(\.id))
    }

    /// Calendars in the scope, and how many of them are shown.
    func count(in snapshot: Snapshot) -> (shown: Int, total: Int) {
        let calendars = Self.listed(in: snapshot).filter { inScope($0, in: snapshot) }
        return (calendars.filter { isShown($0.id) }.count, calendars.count)
    }

    /// "4 of 5 shown" for the calendars the Mac sent events for.
    func summary(in snapshot: Snapshot) -> String {
        let listed = Self.listed(in: snapshot)
        return "\(listed.filter { isShown($0.id) }.count) of \(listed.count) shown"
    }
}
