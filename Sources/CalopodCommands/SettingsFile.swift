import CalopodDomain
import CalopodStore
import Foundation

public enum SettingsFileError: Error, Equatable, CustomStringConvertible {
    case unreadable
    case newerVersion(Int)
    case unusable

    public var description: String {
        switch self {
        case .unreadable: "This is not a Calopod settings file."
        case .unusable: "This file has a setting Calopod can't use."
        case let .newerVersion(version):
            "This file is version \(version). This Calopod reads up to version \(SettingsFile.currentVersion). Update Calopod and try again."
        }
    }
}

/// The settings that move to another Mac. Each file Connection and calendar has a key local to the
/// file, since the ids on this Mac mean nothing on another. Left out: sign-ins, the signing key,
/// cached events, history and this Mac's device and iPhone feed ids.
public struct SettingsFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Connection: Codable, Equatable, Sendable {
        public var key: String
        public var kind: ProviderKind
        public var name: String?
    }

    public struct Calendar: Codable, Equatable, Sendable {
        public var key: String
        public var connection: String
        public var name: String
        public var account: String?
        public var selected: Bool
        public var alias: String?
        public var color: String?
        public var ignored: Bool
        public var hiddenIn: [String]
        public var iPhone: Bool
    }

    public struct Arm: Codable, Equatable, Sendable {
        public var id: String
        public var name: String?
        public var sources: [String]
        public var target: String
        public var rule: ArmRuleMode
        public var label: String?
        public var enabled: Bool
        public var main: Bool
        public var filters: ArmFilters
        public var padding: ArmPadding
        /// Missing in older files, which kept the words of private events on Full details Arms.
        public var includePrivate: Bool?
    }

    public struct Day: Codable, Equatable, Sendable {
        public var weekday: Int
        public var startMinute: Int
        public var endMinute: Int
    }

    public struct Reminders: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var firstEnabled: Bool
        public var firstMinutes: Int
        public var finalEnabled: Bool
        public var finalMinutes: Int
        public var hideTitles: Bool
    }

    public struct InboxMargins: Codable, Equatable, Sendable {
        public var beforeMinutes: Int
        public var afterMinutes: Int
    }

    public struct InboxDigest: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var minute: Int?
    }

    public var formatVersion = currentVersion
    public var connections: [Connection]
    public var calendars: [Calendar]
    public var arms: [Arm]
    public var workingDays: [Day]
    public var focusMinutes: Int
    public var reminders: Reminders
    public var inboxMargins: InboxMargins
    public var inboxDigest: InboxDigest

    public static func decode(_ data: Data) throws -> SettingsFile {
        struct Header: Decodable { let formatVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.formatVersion >= 1 else {
            throw SettingsFileError.unreadable
        }
        guard header.formatVersion <= currentVersion else { throw SettingsFileError.newerVersion(header.formatVersion) }
        guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data) else { throw SettingsFileError.unreadable }
        return file
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

extension SettingsFile {
    /// Calendars with nothing chosen about them are left out, so a new Mac does not report them.
    public init(repository: LocalStateRepository) throws {
        let connections = try repository.connections()
        let arms = try repository.arms()
        let preferences = try repository.calendarPreferences()
        let iPhone = try repository.iPhoneCalendarIDs()
        let hidden = try Dictionary(uniqueKeysWithValues: CalendarViewMode.allCases.map {
            ($0.rawValue, try repository.hiddenCalendars(view: $0.rawValue))
        })
        let armCalendars = Set(arms.flatMap { $0.sourceBindingIDs + [$0.targetBindingID] })

        var calendars: [Calendar] = []
        var keys: [String: String] = [:]
        for (index, connection) in connections.enumerated() {
            for binding in try repository.calendarBindings(connectionID: connection.id) {
                let preference = preferences[binding.id]
                let views = CalendarViewMode.allCases.map(\.rawValue).filter { hidden[$0]?.contains(binding.id) == true }
                guard binding.isSelected || armCalendars.contains(binding.id) || iPhone.contains(binding.id)
                    || !views.isEmpty || preference?.alias != nil || preference?.color != nil
                    || preference?.isIgnored == true else { continue }
                keys[binding.id] = "calendar-\(calendars.count + 1)"
                calendars.append(Calendar(
                    key: "calendar-\(calendars.count + 1)", connection: "connection-\(index + 1)",
                    name: binding.displayLabel ?? "", account: binding.providerSourceLabel, selected: binding.isSelected,
                    alias: preference?.alias, color: preference?.color, ignored: preference?.isIgnored == true,
                    hiddenIn: views, iPhone: iPhone.contains(binding.id)))
            }
        }

        let hours = try repository.workingHours()
        let reminders = try repository.notificationSettings()
        let margins = try repository.inboxContextSettings()
        let digest = try repository.inboxDigestSettings()
        self.init(
            connections: connections.enumerated().map {
                Connection(key: "connection-\($0.offset + 1)", kind: ProviderKind(rawValue: $0.element.provider) ?? .eventKit,
                           name: $0.element.displayLabel)
            },
            calendars: calendars,
            arms: arms.compactMap { arm in
                let sources = arm.sourceBindingIDs.compactMap { keys[$0] }
                guard sources.count == arm.sourceBindingIDs.count, let target = keys[arm.targetBindingID] else { return nil }
                return Arm(id: arm.id, name: arm.name, sources: sources, target: target, rule: arm.ruleMode, label: arm.label,
                           enabled: arm.isEnabled, main: arm.isMain, filters: arm.filters, padding: arm.padding,
                           includePrivate: arm.includePrivate)
            },
            workingDays: hours.days.sorted { $0.key < $1.key }.map {
                Day(weekday: $0.key, startMinute: $0.value.startMinute, endMinute: $0.value.endMinute)
            },
            focusMinutes: try repository.focusSettings().minutes,
            reminders: Reminders(
                enabled: reminders.enabled, firstEnabled: reminders.firstEnabled, firstMinutes: reminders.firstMinutes,
                finalEnabled: reminders.finalEnabled, finalMinutes: reminders.finalMinutes, hideTitles: reminders.hideTitles),
            inboxMargins: InboxMargins(beforeMinutes: margins.beforeMinutes, afterMinutes: margins.afterMinutes),
            inboxDigest: InboxDigest(enabled: digest.enabled, minute: digest.minute))
    }
}
