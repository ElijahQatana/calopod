import CalopodCommands
import Foundation
import Observation

/// State for the Calendar screen. It reads the local copy only; a sync running elsewhere
/// shows up on the next reload.
@MainActor
@Observable
final class CalendarModel {
    enum Mode: Hashable { case week, day }

    private(set) var schedule: CalendarSchedule? { didSet { scheduleVersion += 1 } }
    private(set) var loadFailed = false
    var mode: Mode = .week { didSet { selectedID = nil } }
    var anchor: Date { didSet { selectedID = nil; openNotice = nil } }
    /// Why the last "open this event" request only moved to its day. Cleared when the view moves.
    private(set) var openNotice: String?
    /// Calendars hidden in this view. Not remembered and not shared with other screens.
    private(set) var hidden: Set<String> = []
    var selectedID: String?
    /// Whether Busy copies Calopod made are drawn. Only this view changes; Inbox and sync do not.
    /// Each mode remembers its own choice; until it is changed a mode uses its default.
    var showCopies: Bool {
        get { copyChoices[viewMode] ?? viewMode.copiesShownByDefault }
        set {
            copyChoices[viewMode] = newValue
            defaults.set(newValue, forKey: Self.showCopiesKey(viewMode))
            if !newValue, selected?.isCopy == true { selectedID = nil }
        }
    }

    private var copyChoices: [CalendarViewMode: Bool]

    /// Which calendars this view offers by their part in the arms. Hidden state per calendar is kept across modes.
    var viewMode: CalendarViewMode {
        didSet {
            defaults.set(viewMode.rawValue, forKey: Self.viewModeKey)
            if let selected, !isVisible(selected) { selectedID = nil }
        }
    }

    /// All keeps the key the single setting used before modes existed.
    static func showCopiesKey(_ mode: CalendarViewMode) -> String {
        mode == .all ? "calendarShowCopies" : "calendarShowCopies.\(mode.rawValue)"
    }
    static let viewModeKey = "calendarViewMode"

    let calendar: Calendar
    @ObservationIgnored private let load: @Sendable () throws -> CalendarSchedule
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let aliases: CalendarAliases

    init(
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = AppDefaults.standard,
        aliases: CalendarAliases,
        load: @escaping @Sendable () throws -> CalendarSchedule = { try CalendarScheduleService().schedule() }
    ) {
        self.calendar = calendar
        self.now = now
        self.defaults = defaults
        self.aliases = aliases
        self.load = load
        copyChoices = Dictionary(uniqueKeysWithValues: CalendarViewMode.allCases.compactMap { mode in
            (defaults.object(forKey: Self.showCopiesKey(mode)) as? Bool).map { (mode, $0) }
        })
        viewMode = defaults.string(forKey: Self.viewModeKey).flatMap(CalendarViewMode.init(rawValue:)) ?? .all
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

    /// Calendars offered as chips. Ignored ones are left out and their events are not drawn.
    var chipCalendars: [ScheduleCalendar] {
        let roles = schedule?.roles ?? CalendarRoles()
        return calendars.filter { !aliases.isIgnored($0.id) && roles.includes($0.id, in: viewMode) }
    }

    private func isVisible(_ event: ScheduleEvent) -> Bool {
        let roles = schedule?.roles ?? CalendarRoles()
        return roles.includes(event.calendarID, in: viewMode) && !hidden.contains(event.calendarID)
            && !aliases.isIgnored(event.calendarID) && (showCopies || !event.isCopy)
    }

    /// What one day column draws. Built once per schedule or filter change, not on every redraw.
    struct DayEvents: Equatable {
        let placements: [ScheduleLayout.Placement]
        let allDay: [ScheduleEvent]
    }

    private struct Cache {
        let version: Int
        let hidden: Set<String>
        let ignored: Set<String>
        let showCopies: Bool
        let viewMode: CalendarViewMode
        let events: [ScheduleEvent]
        var days: [Date: DayEvents] = [:]
    }

    @ObservationIgnored private var scheduleVersion = 0
    @ObservationIgnored private var cache: Cache?

    private func current() -> Cache {
        // Reading the ignore list here keeps views that call this watching it.
        let ignored = aliases.ignored
        if let cache, cache.version == scheduleVersion, cache.hidden == hidden,
            cache.ignored == ignored, cache.showCopies == showCopies, cache.viewMode == viewMode
        {
            return cache
        }
        let roles = schedule?.roles ?? CalendarRoles()
        let drawsCopies = showCopies
        let events = (schedule?.events ?? []).filter {
            !hidden.contains($0.calendarID) && !ignored.contains($0.calendarID) && roles.includes($0.calendarID, in: viewMode)
                && (drawsCopies || !$0.isCopy)
        }
        let fresh = Cache(
            version: scheduleVersion, hidden: hidden, ignored: ignored, showCopies: showCopies, viewMode: viewMode,
            events: events)
        cache = fresh
        return fresh
    }

    var events: [ScheduleEvent] { current().events }

    /// The placed and all-day events for one day, from the cache.
    func dayEvents(_ day: Date) -> DayEvents {
        var snapshot = current()
        let key = calendar.startOfDay(for: day)
        if let hit = snapshot.days[key] { return hit }
        let built = DayEvents(
            placements: ScheduleLayout.placements(snapshot.events, on: key, calendar: calendar),
            allDay: ScheduleLayout.allDay(snapshot.events, on: key, calendar: calendar))
        snapshot.days[key] = built
        cache = snapshot
        return built
    }

    var selected: ScheduleEvent? {
        selectedID.flatMap { id in schedule?.events.first { $0.id == id } }
    }

    /// The event a copy was made from, when it is in the loaded schedule and its calendar is drawn.
    func original(of event: ScheduleEvent) -> ScheduleEvent? {
        guard let id = event.copyOrigin?.sourceEventID,
            let found = schedule?.events.first(where: { $0.id == id && !$0.isCopy }),
            !aliases.isIgnored(found.calendarID)
        else { return nil }
        return found
    }

    var notices: [String] {
        ScheduleLayout.notices(
            calendars: chipCalendars, hidden: hidden, range: range, now: now(),
            name: { [aliases] in aliases.name(for: $0.id, real: $0.name) })
    }

    func reload() async {
        let load = load
        do {
            let loaded = try await Task.detached { try load() }.value
            // An unchanged read is not assigned, so views do not redraw for nothing.
            if schedule != loaded { schedule = loaded }
            if loadFailed { loadFailed = false }
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

    /// Shows the event's day and opens it in the inspector. The anchor is set first because moving it clears the selection.
    func show(_ event: ScheduleEvent) {
        anchor = event.startsAt
        // An event from Inbox may sit outside this mode; All is the one view that shows every calendar.
        if !(schedule?.roles ?? CalendarRoles()).includes(event.calendarID, in: viewMode) { viewMode = .all }
        if hidden.contains(event.calendarID) { toggle(event.calendarID) }
        selectedID = event.id
    }

    /// Opens an event from another screen. An event that is a copy, or is not in the schedule any
    /// more, cannot be selected, so the view moves to its day and says why. Returns whether it was selected.
    @discardableResult
    func open(_ event: ScheduleEvent) -> Bool {
        guard let found = schedule?.events.first(where: { $0.id == event.id }), !found.isCopy else {
            anchor = event.startsAt
            openNotice = event.isCopy ? Self.copyNotice : Self.missingNotice
            return false
        }
        show(found)
        return true
    }

    static let missingNotice = "That event is no longer in the schedule, so only its day is shown."
    static let copyNotice = "This is a copy made by Calopod, so only its day is shown."

    func isToday(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: now()) }
}
