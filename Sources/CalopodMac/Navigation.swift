import Foundation
import Observation

enum Screen: String, CaseIterable, Identifiable {
    case overview, calendars, arms, conflicts, service

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .calendars: "Calendars"
        case .arms: "Arms"
        case .conflicts: "Conflicts"
        case .service: "Background sync"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .calendars: "calendar"
        case .arms: "arrow.triangle.branch"
        case .conflicts: "rectangle.on.rectangle.angled"
        case .service: "clock.arrow.2.circlepath"
        }
    }
}

/// Which screen the main window shows, so the menu bar can open straight to one.
@MainActor
@Observable
final class AppNavigation {
    var selection: Screen

    /// `CALOPOD_START_SCREEN=conflicts` opens straight to a screen, for screenshots and testing.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        selection = environment["CALOPOD_START_SCREEN"].flatMap(Screen.init(rawValue:)) ?? .overview
    }
}
