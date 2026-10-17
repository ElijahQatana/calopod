import CalopodCommands
import Foundation
import Observation
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case overview, calendar, inbox, calendars, arms, service, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .calendar: "Calendar"
        case .inbox: "Inbox"
        case .calendars: "Calendars"
        case .arms: "Arms"
        case .service: "Background sync"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .calendar: "calendar.day.timeline.left"
        case .inbox: "tray"
        case .calendars: "calendar"
        case .arms: "arrow.triangle.branch"
        case .service: "clock.arrow.2.circlepath"
        case .settings: "gearshape"
        }
    }
}

extension Screen {
    /// Screens listed in the sidebar.
    static let main: [Screen] = [.overview, .calendar, .inbox]
    static let setup: [Screen] = [.calendars, .arms, .service, .settings]
}

/// Whether the sidebar is an icon rail. Remembered across launches.
@MainActor
@Observable
final class SidebarState {
    static let key = "sidebarCollapsed"
    private let defaults: UserDefaults

    var isCollapsed: Bool {
        didSet { defaults.set(isCollapsed, forKey: Self.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCollapsed = defaults.bool(forKey: Self.key)
    }

    func toggle() {
        withAnimation(.snappy(duration: 0.28)) { isCollapsed.toggle() }
    }
}

/// Lets the menu bar open the window on a given screen.
@MainActor
@Observable
final class AppNavigation {
    var selection: Screen
    /// The Inbox filter to show. Set it with `openInbox` from other screens.
    var inboxFilter: InboxFilter = .all

    /// `CALOPOD_START_SCREEN=inbox` opens on that screen, for screenshots.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        selection = environment["CALOPOD_START_SCREEN"].flatMap(Screen.init(rawValue:)) ?? .overview
    }

    func openInbox(_ filter: InboxFilter = .all) {
        inboxFilter = filter
        selection = .inbox
    }
}
