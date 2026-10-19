import CalopodStore
import Foundation

/// Fills names, ignores and colors an earlier version kept in preferences into the local state
/// database. It runs at every launch and only fills what the database lacks, so a value already
/// there is never replaced. Preferences are not cleared, so nothing is lost.
enum CalendarPreferenceMigration {
    static let aliasKey = "calendarAliases"
    static let ignoredKey = "calendarIgnored"
    static let colorKey = "calendarColors"

    static func run(defaults: UserDefaults, state: LocalStateRepository) {
        _ = try? state.importCalendarPreferences(
            aliases: defaults.dictionary(forKey: aliasKey) as? [String: String] ?? [:],
            ignored: Set(defaults.stringArray(forKey: ignoredKey) ?? []),
            colors: defaults.dictionary(forKey: colorKey) as? [String: String] ?? [:])
    }

    /// What the app does at launch: fill what is missing, then drop rows for calendars that no longer
    /// exist anywhere.
    static func launch(defaults: UserDefaults, state: LocalStateRepository) {
        run(defaults: defaults, state: state)
        _ = try? state.pruneCalendarPreferences()
    }

    /// Called when someone clears a name or stops ignoring a calendar, so the next launch does not
    /// bring the old choice back.
    static func forgetAlias(_ calendarID: String, defaults: UserDefaults) {
        guard var aliases = defaults.dictionary(forKey: aliasKey) as? [String: String],
              aliases.removeValue(forKey: calendarID) != nil else { return }
        defaults.set(aliases, forKey: aliasKey)
    }

    static func forgetIgnored(_ calendarID: String, defaults: UserDefaults) {
        guard var ignored = defaults.stringArray(forKey: ignoredKey), ignored.contains(calendarID) else { return }
        ignored.removeAll { $0 == calendarID }
        defaults.set(ignored, forKey: ignoredKey)
    }
}
