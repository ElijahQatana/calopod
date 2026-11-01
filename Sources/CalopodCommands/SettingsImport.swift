import CalopodDomain
import CalopodStore
import CalopodSync
import Foundation

public struct SettingsImportPlan {
    struct Change {
        let text: String
        let run: () throws -> Void
    }

    let changes: [Change]
    /// Connections in the file with no single match here. Their calendars and Arms are left out.
    public let missingConnections: [String]
    /// Calendars and Arms that could not be matched, and are left as they are.
    public let unmatched: [String]
    public let addsArms: Bool

    /// Copies an Arm made on the old Mac carry a key this Mac does not have.
    public static let copiesNotice =
        "Copies made on the old Mac are not recognised here. Delete them from the target calendars before the first sync, or those Arms stop and report them."

    public var lines: [String] { changes.map(\.text) }
}

public struct SettingsImportResult: Equatable {
    public var applied = 0
    public var failed: [String] = []
}

private struct Edits {
    var parts: [String] = []
    var runs: [() throws -> Void] = []

    mutating func add(_ part: String, _ run: @escaping () throws -> Void) {
        parts.append(part)
        runs.append(run)
    }

    func changes(_ text: String) -> [SettingsImportPlan.Change] {
        let runs = runs
        return runs.isEmpty ? [] : [.init(text: "\(text) (\(parts.joined(separator: ", ")))") { for run in runs { try run() } }]
    }
}

/// Reads a settings file into this Mac's local state only. Nothing reaches a calendar provider.
public struct SettingsImporter: Sendable {
    private let repository: LocalStateRepository

    public init(repository: LocalStateRepository) {
        self.repository = repository
    }

    public func plan(_ file: SettingsFile) throws -> SettingsImportPlan {
        var changes: [SettingsImportPlan.Change] = []
        var missing: [String] = []
        var unmatched: [String] = []
        var addsArms = false
        let service = ArmConfigurationService(repository: repository)

        let local = try repository.connections()
        var connections: [String: StoredConnection] = [:]
        for connection in file.connections {
            func matches(_ kind: ProviderKind, _ name: String?) -> Bool {
                kind == connection.kind && (kind == .eventKit || name == connection.name)
            }
            let candidates = local.filter { matches(ProviderKind(rawValue: $0.provider) ?? .ics, $0.displayLabel) }
            if candidates.count == 1, file.connections.filter({ matches($0.kind, $0.name) }).count == 1 {
                connections[connection.key] = candidates[0]
            } else {
                missing.append(connection.name ?? connection.kind.rawValue)
            }
        }

        let preferences = try repository.calendarPreferences()
        let iPhone = try repository.iPhoneCalendarIDs()
        var bindings: [String: StoredCalendarBinding] = [:]
        var names: [String: String] = [:]
        for calendar in file.calendars {
            names[calendar.key] = calendar.alias ?? calendar.name
            guard let connection = connections[calendar.connection] else { continue }
            let candidates = try repository.calendarBindings(connectionID: connection.id).filter {
                $0.displayLabel == calendar.name && $0.providerSourceLabel == calendar.account
            }
            guard candidates.count == 1, file.calendars.filter({
                $0.connection == calendar.connection && $0.name == calendar.name && $0.account == calendar.account
            }).count == 1 else {
                unmatched.append("Calendar \"\(calendar.name)\"")
                continue
            }
            let binding = candidates[0]
            bindings[calendar.key] = binding

            let preference = preferences[binding.id] ?? CalendarPreference()
            var edits = Edits()
            if binding.isSelected != calendar.selected {
                edits.add("selection") { _ = try repository.setCalendarSelection(id: binding.id, isSelected: calendar.selected) }
            }
            if preference.alias != calendar.alias {
                edits.add("name") { try repository.setCalendarAlias(calendar.alias, calendarID: binding.id) }
            }
            if preference.color != calendar.color {
                edits.add("color") { try repository.setCalendarColor(calendar.color, calendarID: binding.id) }
            }
            if preference.isIgnored != calendar.ignored {
                edits.add("ignored") { try repository.setCalendarIgnored(calendar.ignored, calendarID: binding.id) }
            }
            for view in CalendarViewMode.allCases {
                let hidden = calendar.hiddenIn.contains(view.rawValue)
                if try repository.hiddenCalendars(view: view.rawValue).contains(binding.id) != hidden {
                    edits.add("hidden in \(view.title)") {
                        try repository.setCalendarHidden(hidden, view: view.rawValue, calendarID: binding.id)
                    }
                }
            }
            if iPhone.contains(binding.id) != calendar.iPhone {
                edits.add("iPhone") { try repository.setIPhoneCalendar(binding.id, chosen: calendar.iPhone) }
            }
            changes += edits.changes("Change calendar \"\(calendar.name)\"")
        }

        for arm in file.arms {
            let title = arm.name.map { "\"\($0)\"" } ?? (arm.main ? "Main calendar"
                : "from \(arm.sources.compactMap { names[$0] }.joined(separator: ", ")) to \(names[arm.target] ?? "")")
            let sources = arm.sources.compactMap { bindings[$0]?.id }
            guard sources.count == arm.sources.count, let target = bindings[arm.target]?.id else {
                unmatched.append("Arm \(title)")
                continue
            }
            let includePrivate = arm.includePrivate ?? (arm.rule == .fullDetails)
            if let existing = try repository.arm(id: arm.id) {
                var edits = Edits()
                if existing.name != arm.name { edits.add("name") { _ = try service.rename(armID: arm.id, name: arm.name) } }
                if existing.ruleMode != arm.rule || existing.label != arm.label {
                    edits.add("Rule") { _ = try service.updateRule(armID: arm.id, ruleMode: arm.rule, label: arm.label) }
                }
                if existing.filters != arm.filters { edits.add("filters") { _ = try service.updateFilters(armID: arm.id, filters: arm.filters) } }
                if existing.includePrivate != includePrivate {
                    edits.add("private events") { _ = try service.updateIncludePrivate(armID: arm.id, includePrivate: includePrivate) }
                }
                if existing.padding != arm.padding { edits.add("padding") { _ = try service.updatePadding(armID: arm.id, padding: arm.padding) } }
                if existing.isEnabled != arm.enabled {
                    edits.add(arm.enabled ? "turn on" : "turn off") { _ = try repository.setArmEnabled(id: arm.id, isEnabled: arm.enabled) }
                }
                changes += edits.changes("Change Arm \(title)")
            } else {
                addsArms = true
                changes.append(.init(text: "Add Arm \(title)") {
                    try service.createArm(
                        id: arm.id, sourceBindingIDs: sources, targetBindingID: target, ruleMode: arm.rule, isMain: arm.main,
                        name: arm.name, filters: arm.filters, label: arm.label, padding: arm.padding,
                        includePrivate: includePrivate)
                    if !arm.enabled { _ = try repository.setArmEnabled(id: arm.id, isEnabled: false) }
                })
            }
        }

        let haveSkips = Set(try repository.eventSkips().map(\.id))
        var newSkips: [String: [EventSkip]] = [:]
        for skip in file.skips ?? [] {
            guard let binding = bindings[skip.calendar], let ref = skip.ref else {
                unmatched.append("Skipped event on \"\(names[skip.calendar] ?? "")\"")
                continue
            }
            let value = EventSkip(
                calendarBindingID: binding.id, ref: ref, occurrence: skip.occurrence ?? "", isPortable: true, skippedAt: Date())
            if !haveSkips.contains(value.id) { newSkips[skip.calendar, default: []].append(value) }
        }
        for (calendar, skips) in newSkips.sorted(by: { $0.key < $1.key }) {
            changes.append(.init(
                text: "Don't copy \(skips.count) event\(skips.count == 1 ? "" : "s") on \"\(names[calendar] ?? "")\"") {
                for skip in skips { try repository.addEventSkip(skip) }
            })
        }

        let hours: WorkingHours, focus: FocusSettings, reminders: NotificationSettings
        let margins: InboxContextSettings, digest: InboxDigestSettings
        do {
            hours = try WorkingHours(days: Dictionary(file.workingDays.map {
                ($0.weekday, try .init(startMinute: $0.startMinute, endMinute: $0.endMinute))
            }, uniquingKeysWith: { _, last in last }))
            focus = try FocusSettings(minutes: file.focusMinutes)
            reminders = try NotificationSettings(
                enabled: file.reminders.enabled, firstEnabled: file.reminders.firstEnabled,
                firstMinutes: file.reminders.firstMinutes, finalEnabled: file.reminders.finalEnabled,
                finalMinutes: file.reminders.finalMinutes, hideTitles: file.reminders.hideTitles)
            margins = try InboxContextSettings(
                beforeMinutes: file.inboxMargins.beforeMinutes, afterMinutes: file.inboxMargins.afterMinutes)
            digest = try InboxDigestSettings(enabled: file.inboxDigest.enabled, minute: file.inboxDigest.minute)
        } catch {
            throw SettingsFileError.unusable
        }
        if try hours != repository.workingHours() {
            changes.append(.init(text: "Change working hours") { try repository.saveWorkingHours(hours) })
        }
        if try focus != repository.focusSettings() {
            changes.append(.init(text: "Change focus length") { try repository.saveFocusSettings(focus) })
        }
        if try reminders != repository.notificationSettings() {
            changes.append(.init(text: "Change reminders") { try repository.saveNotificationSettings(reminders) })
        }
        if try margins != repository.inboxContextSettings() {
            changes.append(.init(text: "Change Inbox margins") { try repository.saveInboxContextSettings(margins) })
        }
        if try digest != repository.inboxDigestSettings() {
            changes.append(.init(text: "Change Inbox digest") { try repository.saveInboxDigestSettings(digest) })
        }
        return SettingsImportPlan(
            changes: changes, missingConnections: missing, unmatched: unmatched,
            addsArms: addsArms)
    }

    public func apply(_ plan: SettingsImportPlan) -> SettingsImportResult {
        var result = SettingsImportResult()
        for change in plan.changes {
            do {
                try change.run()
                result.applied += 1
            } catch {
                result.failed.append("\(change.text): \(String(describing: error))")
            }
        }
        return result
    }
}
