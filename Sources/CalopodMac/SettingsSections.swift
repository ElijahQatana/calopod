import Foundation

enum SettingsFeature { case updates, iPhone, commandLine }

struct SettingsItem {
    let title: String
    var keywords = ""
    var needs: SettingsFeature?
}

struct SettingsMatch {
    let section: SettingsSection
    let count: Int
}

/// Add a setting to its section's `items` so search finds it.
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, workingHours, notifications, iPhone, permissions, app

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .workingHours: "Working hours"
        case .notifications: "Notifications"
        case .iPhone: "iPhone"
        case .permissions: "Permissions"
        case .app: "App and command line"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintbrush"
        case .workingHours: "clock"
        case .notifications: "bell"
        case .iPhone: "iphone"
        case .permissions: "lock.shield"
        case .app: "terminal"
        }
    }

    var items: [SettingsItem] {
        switch self {
        case .appearance: [
            SettingsItem(title: "Appearance", keywords: "theme light dark system"),
            SettingsItem(title: "Window style", keywords: "glass frosted solid"),
            SettingsItem(title: "Transparency", keywords: "frame sidebar content see-through reset"),
        ]
        case .workingHours: [
            SettingsItem(title: "Working days", keywords: "start end day week"),
            SettingsItem(title: "Focus time", keywords: "availability"),
        ]
        case .notifications: [
            SettingsItem(title: "Meeting reminders", keywords: "first final"),
            SettingsItem(title: "Hide event titles"),
            SettingsItem(title: "Daily Inbox digest", keywords: "time"),
        ]
        case .iPhone: [
            SettingsItem(title: "Show Inbox and busy time", keywords: "icloud feed calendars send", needs: .iPhone),
            SettingsItem(title: "Shared people", keywords: "invite", needs: .iPhone),
        ]
        case .permissions: [
            SettingsItem(title: "Calendar access", keywords: "privacy"),
            SettingsItem(title: "Background service", keywords: "login items"),
            SettingsItem(title: "Notifications", keywords: "allow"),
            SettingsItem(title: "Saved sign-ins", keywords: "keychain"),
        ]
        case .app: [
            SettingsItem(title: "Menu bar", keywords: "dock"),
            SettingsItem(title: "Updates", keywords: "version release check", needs: .updates),
            SettingsItem(title: "Command line", keywords: "calopod terminal install path", needs: .commandLine),
        ]
        }
    }

    /// The section's title counts as a keyword.
    func items(matching query: String, features: Set<SettingsFeature>) -> [SettingsItem] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return items.filter { item in
            guard item.needs.map(features.contains) ?? true else { return false }
            let text = "\(title) \(item.title) \(item.keywords)"
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    static func results(query: String, features: Set<SettingsFeature>) -> [SettingsMatch] {
        allCases.compactMap { section in
            let count = section.items(matching: query, features: features).count
            return count > 0 ? SettingsMatch(section: section, count: count) : nil
        }
    }

    static func shown(selected: SettingsSection, in results: [SettingsMatch]) -> SettingsSection? {
        results.contains { $0.section == selected } ? selected : results.first?.section
    }
}
