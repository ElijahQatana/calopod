import Foundation
import Observation
import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    case overview, calendar, inbox, calendars, arms, conflicts, service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .calendar: "Calendar"
        case .inbox: "Inbox"
        case .calendars: "Calendars"
        case .arms: "Arms"
        case .conflicts: "Conflicts"
        case .service: "Background sync"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .calendar: "calendar.day.timeline.left"
        case .inbox: "tray"
        case .calendars: "calendar"
        case .arms: "arrow.triangle.branch"
        case .conflicts: "rectangle.on.rectangle.angled"
        case .service: "clock.arrow.2.circlepath"
        }
    }
}

extension Screen {
    /// Screens listed in the sidebar. Conflicts stays reachable from Overview
    /// and the menu bar until Inbox takes over its flow.
    static let main: [Screen] = [.overview, .calendar, .inbox]
    static let setup: [Screen] = [.calendars, .arms, .service]

    /// The sidebar row that shows as selected for this screen.
    var sidebarRow: Screen { self == .conflicts ? .inbox : self }
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

    /// `CALOPOD_START_SCREEN=conflicts` opens on that screen, for screenshots.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        selection = environment["CALOPOD_START_SCREEN"].flatMap(Screen.init(rawValue:)) ?? .overview
    }
}
