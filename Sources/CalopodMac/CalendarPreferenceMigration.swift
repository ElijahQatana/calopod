import CalopodStore
import Foundation

/// Moves names, ignores and colors an earlier version kept in preferences into the local state
/// database. It runs once; after that the preferences are no longer read.
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
}
