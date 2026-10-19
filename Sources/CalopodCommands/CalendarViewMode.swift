import ArgumentParser
import CalopodStore

/// Which calendars the Calendar screen and `calopod events` show, by the part each plays in the arms.
public enum CalendarViewMode: String, CaseIterable, Codable, Sendable, ExpressibleByArgument {
    case all
    case sources
    case destinations

    /// Copies are what Destinations is for; the other modes start without them.
    public var copiesShownByDefault: Bool { self == .destinations }

    public var title: String {
        switch self {
        case .all: "All"
        case .sources: "Sources"
        case .destinations: "Destinations"
        }
    }
}

/// The calendars active arms copy from and write to. Paused arms are ignored.
public struct CalendarRoles: Equatable, Sendable {
    public let sources: Set<String>
    public let destinations: Set<String>

    public init(sources: Set<String> = [], destinations: Set<String> = []) {
        self.sources = sources
        self.destinations = destinations
    }

    public init(arms: [StoredArm]) {
        let active = arms.filter(\.isEnabled)
        sources = Set(active.flatMap(\.sourceBindingIDs))
        destinations = Set(active.map(\.targetBindingID))
    }

    /// A calendar that is both appears in both modes; one no arm uses appears only in All.
    public func includes(_ calendarID: String, in mode: CalendarViewMode) -> Bool {
        switch mode {
        case .all: true
        case .sources: sources.contains(calendarID)
        case .destinations: destinations.contains(calendarID)
        }
    }
}
