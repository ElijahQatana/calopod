import CalopodCommands
import CalopodStore
import Foundation
import Observation

/// Names and an ignore list chosen on this Mac. They only change what Calopod shows; the calendar
/// at the provider, its identifier and what syncs are untouched.
@MainActor
@Observable
final class CalendarAliases {
    static let shared = CalendarAliases(defaults: AppDefaults.forSingleton, state: try? LocalState.repository())

    private static let expandedKey = "calendarIgnoredExpanded"

    private(set) var aliases: [String: String]
    private(set) var ignored: Set<String>
    /// Connections whose Ignored section is open. Closed unless opened.
    private(set) var expanded: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let state: LocalStateRepository?

    /// Names and ignores live in the local state database. Without one they last until the app quits.
    init(defaults: UserDefaults, state: LocalStateRepository?) {
        self.defaults = defaults
        self.state = state
        if let state { CalendarPreferenceMigration.run(defaults: defaults, state: state) }
        let saved = (try? state?.calendarPreferences()) ?? [:]
        aliases = saved.compactMapValues { CalendarDisplayName.alias($0.alias, real: nil) }
        ignored = Set(saved.filter(\.value.isIgnored).keys)
        expanded = Set(defaults.stringArray(forKey: Self.expandedKey) ?? [])
    }

    func reload() {
        let saved = (try? state?.calendarPreferences()) ?? [:]
        aliases = saved.compactMapValues { CalendarDisplayName.alias($0.alias, real: nil) }
        ignored = Set(saved.filter(\.value.isIgnored).keys)
    }

    func alias(for calendarID: String) -> String? { aliases[calendarID] }

    /// The name to show: the alias when there is one, else the name the provider gives.
    func name(for calendarID: String, real: String) -> String {
        CalendarDisplayName.shown(alias: aliases[calendarID], real: real) ?? real
    }

    /// Sets the alias. An empty one, or one equal to the real name, clears it.
    func setAlias(_ text: String, for calendarID: String, real: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == real { aliases[calendarID] = nil } else { aliases[calendarID] = trimmed }
        if aliases[calendarID] == nil { CalendarPreferenceMigration.forgetAlias(calendarID, defaults: defaults) }
        try? state?.setCalendarAlias(aliases[calendarID], calendarID: calendarID)
    }

    func isIgnored(_ calendarID: String) -> Bool { ignored.contains(calendarID) }

    func setIgnored(_ value: Bool, for calendarID: String) {
        if value { ignored.insert(calendarID) } else { ignored.remove(calendarID) }
        if !value { CalendarPreferenceMigration.forgetIgnored(calendarID, defaults: defaults) }
        try? state?.setCalendarIgnored(value, calendarID: calendarID)
    }

    func isExpanded(_ connectionID: String) -> Bool { expanded.contains(connectionID) }

    func setExpanded(_ value: Bool, for connectionID: String) {
        if value { expanded.insert(connectionID) } else { expanded.remove(connectionID) }
        defaults.set(expanded.sorted(), forKey: Self.expandedKey)
    }

    func name(for calendar: SetupCalendar) -> String { name(for: calendar.id, real: calendar.name) }

    /// A calendar the arms or sources still use. Ignoring never takes it out of sync, so it stays marked.
    static func isInUse(_ id: String, selected: Bool, armCalendars: Set<String>) -> Bool {
        selected || armCalendars.contains(id)
    }
}
