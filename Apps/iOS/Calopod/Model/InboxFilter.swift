import CalopodSnapshot
import Foundation

enum InboxFilter: CaseIterable, Hashable {
    case all, needsRSVP, maybe, changes, conflicts

    var title: String {
        switch self {
        case .all: "All"
        case .needsRSVP: "Needs RSVP"
        case .maybe: "Maybe"
        case .changes: "Changes"
        case .conflicts: "Conflicts"
        }
    }

    private var reason: InboxReason? {
        switch self {
        case .all: nil
        case .needsRSVP: .needsRSVP
        case .maybe: .maybe
        case .changes: .unreadChange
        case .conflicts: .conflict
        }
    }

    func matches(_ item: InboxItem) -> Bool {
        reason.map(item.reasons.contains) ?? true
    }

    func apply(to items: [InboxItem]) -> [InboxItem] { items.filter(matches) }
}

struct InboxDay: Equatable {
    var day: Date
    var items: [InboxItem]
}

/// Items grouped by the local day they start on, earliest first.
func groupedByDay(_ items: [InboxItem], calendar: Calendar = .current) -> [InboxDay] {
    let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.startsAt) }
    return grouped.keys.sorted().map { InboxDay(day: $0, items: grouped[$0]!.sorted { $0.startsAt < $1.startsAt }) }
}
