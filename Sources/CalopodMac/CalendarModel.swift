import CalopodCommands
import Foundation
import Observation

/// State for the Calendar screen. It reads the local copy only; a sync running elsewhere
/// shows up on the next reload.
@MainActor
@Observable
final class CalendarModel {
    enum Mode: Hashable { case week, day }

    private(set) var schedule: CalendarSchedule?
    private(set) var loadFailed = false
    var mode: Mode = .week { didSet { selectedID = nil } }
    var anchor: Date { didSet { selectedID = nil } }
    /// Calendars hidden in this view. Not remembered and not shared with other screens.
    private(set) var hidden: Set<String> = []
    var selectedID: String?
    /// Whether Busy copies Calopod made are drawn. Only this view changes; Inbox and sync do not.
    var showCopies: Bool {
        didSet {
            defaults.set(showCopies, forKey: Self.showCopiesKey)
            if !showCopies, selected?.isCopy == true { selectedID = nil }
        }
    }

    static let showCopiesKey = "calendarShowCopies"

    let calendar: Calendar
    @ObservationIgnored private let load: @Sendable () throws -> CalendarSchedule
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults

    init(
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard,
        load: @escaping @Sendable () throws -> CalendarSchedule = { try CalendarScheduleService().schedule() }
    ) {
        self.calendar = calendar
        self.now = now
        self.defaults = defaults
        self.load = load
        showCopies = defaults.object(forKey: Self.showCopiesKey) as? Bool ?? true
        anchor = now()
    }

    var days: [Date] {
        switch mode {
        case .week: ScheduleLayout.weekDays(containing: anchor, calendar: calendar)
        case .day: [calendar.startOfDay(for: anchor)]
        }
    }

    var range: Range<Date> {
        let first = days.first ?? calendar.startOfDay(for: anchor)
        let last = days.last ?? first
        return first..<(calendar.date(byAdding: .day, value: 1, to: last) ?? last)
    }

    var calendars: [ScheduleCalendar] { schedule?.calendars ?? [] }

    var events: [ScheduleEvent] {
        (schedule?.events ?? []).filter { !hidden.contains($0.calendarID) && (showCopies || !$0.isCopy) }
    }

    var selected: ScheduleEvent? {
        selectedID.flatMap { id in schedule?.events.first { $0.id == id } }
    }

    var notices: [String] {
        ScheduleLayout.notices(calendars: calendars, hidden: hidden, range: range, now: now())
    }

    func reload() async {
        let load = load
        do {
            schedule = try await Task.detached { try load() }.value
            loadFailed = false
            if selectedID != nil, selected == nil { selectedID = nil }
        } catch {
            loadFailed = true
        }
    }

    func toggle(_ calendarID: String) {
        if hidden.contains(calendarID) { hidden.remove(calendarID) } else { hidden.insert(calendarID) }
        if let selected, hidden.contains(selected.calendarID) { selectedID = nil }
    }

    func step(_ direction: Int) {
        let unit: Calendar.Component = mode == .week ? .weekOfYear : .day
        anchor = calendar.date(byAdding: unit, value: direction, to: anchor) ?? anchor
    }

    func goToToday() { anchor = now() }

    func isToday(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: now()) }
}
