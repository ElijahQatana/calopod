import CalopodSnapshot
import Foundation
import Observation

/// Which calendars the Calendar tab hides. It is a choice for this phone only: it is kept here
/// and never changes what the Mac publishes.
@Observable
final class CalendarFilter {
    private(set) var hidden: Set<String>

    private let defaults: UserDefaults
    private static let key = "hiddenCalendars"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidden = Set(defaults.stringArray(forKey: Self.key) ?? [])
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
    /// "4 of 5 shown" for the calendars the Mac sent events for.
    func summary(in snapshot: Snapshot) -> String {
        let listed = Self.listed(in: snapshot)
        return "\(listed.filter { isShown($0.id) }.count) of \(listed.count) shown"
    }
}
