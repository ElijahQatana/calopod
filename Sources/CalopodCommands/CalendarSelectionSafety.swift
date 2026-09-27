import CalopodDomain
import CalopodEventKit
import CalopodStore

/// Blocks the same calendar account from being synced twice — once through
/// macOS's own EventKit copy of an account, and once through a direct
/// Google or Microsoft connection to that same account — which would
/// otherwise double every event. Detection is heuristic
/// (`EventKitSourceClassifier` guesses at account type from EventKit's loose
/// source metadata), so this only warns or blocks selection; it never
/// silently deduplicates on someone's behalf.
enum CalendarSelectionSafety {
    /// Checked before actually selecting a calendar: returns a blocking
    /// message if selecting `binding` would create the overlap in either
    /// direction — an EventKit calendar that looks like an account already
    /// selected directly, or a direct connection to a provider EventKit
    /// already has a selected calendar for.
    static func conflictMessage(
        selecting binding: StoredCalendarBinding,
        on connection: StoredConnection,
        repository: LocalStateRepository
    ) throws -> String? {
        let connections = try repository.connections()

        if connection.provider == ProviderKind.eventKit.rawValue,
           let provider = EventKitSourceClassifier.likelyDirectProvider(
               sourceType: binding.providerSourceType,
               sourceLabel: binding.providerSourceLabel
           ),
           try hasSelectedCalendar(
               provider: provider.rawValue,
               connections: connections,
               repository: repository
           ) {
            return overlapMessage(provider: provider)
        }

        guard let provider = ProviderKind(rawValue: connection.provider),
              provider == .google || provider == .microsoft else {
            return nil
        }

        for eventKitConnection in connections where eventKitConnection.provider == ProviderKind.eventKit.rawValue {
            let selected = try repository.calendarBindings(connectionID: eventKitConnection.id)
                .filter(\.isSelected)
            if selected.contains(where: {
                EventKitSourceClassifier.likelyDirectProvider(
                    sourceType: $0.providerSourceType,
                    sourceLabel: $0.providerSourceLabel
                ) == provider
            }) {
                return overlapMessage(provider: provider)
            }
        }
        return nil
    }

    /// Non-blocking counterpart to `conflictMessage`, used when listing or
    /// refreshing EventKit calendars: flags any that look like they overlap
    /// with an already-connected direct provider, without preventing the
    /// listing itself.
    static func warnings(
        for bindings: [StoredCalendarBinding],
        connection: StoredConnection,
        repository: LocalStateRepository
    ) throws -> [String] {
        guard connection.provider == ProviderKind.eventKit.rawValue else { return [] }
        let connectedProviders = Set(try repository.connections().map(\.provider))
        let providers = Set(bindings.compactMap {
            EventKitSourceClassifier.likelyDirectProvider(
                sourceType: $0.providerSourceType,
                sourceLabel: $0.providerSourceLabel
            )
        }).filter { connectedProviders.contains($0.rawValue) }

        return providers.sorted { $0.rawValue < $1.rawValue }.map {
            "A calendar source may overlap with the direct \(providerName($0)) Connection. Select only one copy."
        }
    }

    private static func hasSelectedCalendar(
        provider: String,
        connections: [StoredConnection],
        repository: LocalStateRepository
    ) throws -> Bool {
        for connection in connections where connection.provider == provider {
            if try repository.calendarBindings(connectionID: connection.id).contains(where: \.isSelected) {
                return true
            }
        }
        return false
    }

    private static func overlapMessage(provider: ProviderKind) -> String {
        "That calendar appears to overlap with the direct \(providerName(provider)) Connection. Deselect one copy before selecting the other."
    }

    private static func providerName(_ provider: ProviderKind) -> String {
        switch provider {
        case .google: "Google Calendar"
        case .microsoft: "Microsoft Calendar"
        case .eventKit: "Calendars on this Mac"
        case .ics: "ICS"
        }
    }
}
