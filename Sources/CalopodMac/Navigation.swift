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

/// The pages inside Calendar: the schedule grid and the week's free and busy time.
enum CalendarPage: String, CaseIterable {
    case schedule, availability

    var title: String { self == .schedule ? "Schedule" : "Availability" }
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

    init(defaults: UserDefaults = AppDefaults.standard) {
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
    /// The page Calendar shows. Set it with `openAvailability` from other screens.
    var calendarPage: CalendarPage = .schedule
    /// The Inbox filter to show. Set it with `openInbox` from other screens.
    var inboxFilter: InboxFilter = .all
    /// An event to select when Inbox opens. Inbox clears it once it has looked for the event.
    var inboxEvent: String?

    /// `CALOPOD_START_SCREEN=inbox` opens on that screen, for screenshots.
    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        selection = environment["CALOPOD_START_SCREEN"].flatMap(Screen.init(rawValue:)) ?? .overview
    }

    func openInbox(_ filter: InboxFilter = .all, event: String? = nil) {
        inboxFilter = filter
        inboxEvent = event
        selection = .inbox
    }

    func openAvailability() {
        calendarPage = .availability
        selection = .calendar
    }

    /// Opens Inbox on the first filter that holds the event, or All, with the event selected.
    func openInbox(showing event: ScheduleEvent) {
        openInbox(ScheduleLayout.inboxFilter(for: event), event: event.id)
    }

    /// Brings Calendar forward on the event. The menu bar and Overview both open events this way.
    func openCalendar(showing event: ScheduleEvent, in model: CalendarModel) {
        model.open(event)
        calendarPage = .schedule
        selection = .calendar
    }

    /// The requested event if the list holds it. Either way the request is done.
    func takeInboxEvent(in entries: [InboxEntry]) -> String? {
        defer { inboxEvent = nil }
        return entries.contains { $0.id == inboxEvent } ? inboxEvent : nil
    }
}
