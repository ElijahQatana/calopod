import CalopodStore

/// Names, the Ignored list and colors chosen on this Mac, read once per command from the local
/// state. They only change what Calopod shows.
struct CalendarNames {
    let preferences: [String: CalendarPreference]

    init(preferences: [String: CalendarPreference] = [:]) { self.preferences = preferences }

    init(_ repository: LocalStateRepository) {
        preferences = (try? repository.calendarPreferences()) ?? [:]
    }

    /// The chosen name, unless it is the same as the provider's.
    func alias(_ id: String, real: String?) -> String? {
        guard let alias = preferences[id]?.alias, alias != real else { return nil }
        return alias
    }

    func shown(_ id: String, real: String?) -> String? { alias(id, real: real) ?? real }

    func isIgnored(_ id: String) -> Bool { preferences[id]?.isIgnored == true }

    /// Marks the extra fields on a source only where they apply, so unchanged calendars print as before.
    func source(_ source: CommandSource) -> CommandSource {
        CommandSource(id: source.id, connectionID: source.connectionID, provider: source.provider, label: source.label,
                      alias: alias(source.id, real: source.label), ignored: isIgnored(source.id) ? true : nil,
                      inbox: source.inbox)
    }
}
