import CalopodCommands
import CalopodDomain
import Foundation

struct ArmCalendar: Identifiable, Equatable {
    let id: String
    let name: String
    let isSelected: Bool
    let isReadOnly: Bool
}

/// The calendars of one account, as offered when building an arm.
struct ArmCalendarGroup: Identifiable, Equatable {
    let id: String
    let label: String
    var calendars: [ArmCalendar]
}

/// What the New arm sheet has so far, and whether it can be created. The service still has the
/// final say (duplicate routes, disabled accounts); this only keeps the obvious mistakes out.
struct NewArmDraft: Equatable {
    var name = ""
    var sources = Set<String>()
    var target: String?
    var rule: ArmRuleMode = .busy

    /// Every calendar, grouped by account. Ignored calendars keep syncing but are not offered for new arms.
    @MainActor
    static func groups(from connections: [SetupConnection], aliases: CalendarAliases) -> [ArmCalendarGroup] {
        connections.compactMap { connection in
            let calendars = connection.calendars
                .filter { !aliases.isIgnored($0.id) }
                .map {
                    ArmCalendar(id: $0.id, name: aliases.name(for: $0), isSelected: $0.isSelected, isReadOnly: $0.isReadOnly)
                }
            return calendars.isEmpty ? nil : ArmCalendarGroup(id: connection.id, label: connection.label, calendars: calendars)
        }
    }

    /// What events can come from: the calendars chosen on the Calendars screen.
    static func sources(in groups: [ArmCalendarGroup]) -> [ArmCalendarGroup] {
        groups.compactMap { group in
            let chosen = group.calendars.filter(\.isSelected)
            return chosen.isEmpty ? nil : ArmCalendarGroup(id: group.id, label: group.label, calendars: chosen)
        }
    }

    /// Where events can go: writable, and not one of the calendars they come from.
    func targets(in groups: [ArmCalendarGroup]) -> [ArmCalendarGroup] {
        groups.compactMap { group in
            let open = group.calendars.filter { !$0.isReadOnly && !sources.contains($0.id) }
            return open.isEmpty ? nil : ArmCalendarGroup(id: group.id, label: group.label, calendars: open)
        }
    }

    /// Why Create is unavailable, or nil when the draft is ready.
    var problem: String? {
        if sources.isEmpty { return "Choose at least one calendar to copy from." }
        guard let target else { return "Choose the calendar to copy into." }
        if sources.contains(target) { return "A calendar can't copy into itself." }
        return nil
    }

    /// The name to send: nil keeps the default.
    var trimmedName: String? {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    mutating func toggleSource(_ id: String) {
        if sources.remove(id) == nil { sources.insert(id) }
        if let target, sources.contains(target) { self.target = nil }
    }
}

extension SetupArm {
    /// The Main calendar always copies full details.
    var canChangeRule: Bool { !isMain }
}
