import CalopodCommands
import CalopodSync
import Foundation
import Observation

/// The week shown in the Overview availability card. It reads the local copy only, and the same
/// working hours and calculation as `calopod availability`.
@MainActor
@Observable
final class AvailabilityModel {
    private(set) var reports: [AvailabilityDayReport] = []
    private(set) var loadFailed = false
    var selected: Date
    var findText = ""
    private(set) var weekStart: Date

    let calendar: Calendar
    @ObservationIgnored private let load: @Sendable ([Date]) throws -> [AvailabilityDayReport]
    @ObservationIgnored private let now: () -> Date

    init(
        calendar: Calendar = .current, now: @escaping () -> Date = Date.init,
        load: @escaping @Sendable ([Date]) throws -> [AvailabilityDayReport] = { try AvailabilityService().report(days: $0) }
    ) {
        self.calendar = calendar
        self.now = now
        self.load = load
        let today = calendar.startOfDay(for: now())
        selected = today
        weekStart = ScheduleLayout.weekDays(containing: today, calendar: calendar).first ?? today
    }

    var days: [Date] { (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) } }

    var range: Range<Date> {
        weekStart..<(calendar.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart)
    }

    /// The week as a page title, like "Oct 18 to Oct 24".
    var title: String {
        guard let first = days.first, let last = days.last else { return "Week" }
        let day = Date.FormatStyle().day().month(.abbreviated)
        return "\(first.formatted(day)) to \(last.formatted(day))"
    }

    var selectedReport: AvailabilityDayReport? { reports.first { $0.day.start == selected } }

    /// The free windows in the shown week that fit the length typed in the Find field, from now on.
    var found: [AvailabilityInterval] {
        guard let seconds = findSeconds else { return [] }
        return reports.flatMap { $0.result.freeWindows(atLeast: seconds, after: now()) }
    }

    /// Every window found, as text to paste into a message, in the zone the page shows.
    var foundText: String { FreeSlotText.text(found, timeZone: calendar.timeZone) }

    var findSeconds: TimeInterval? { FindSpan(findText.trimmingCharacters(in: .whitespaces))?.seconds }

    func report(for day: Date) -> AvailabilityDayReport? { reports.first { $0.day.start == day } }

    func isToday(_ day: Date) -> Bool { calendar.isDate(day, inSameDayAs: now()) }

    func step(_ weeks: Int) async {
        guard let moved = calendar.date(byAdding: .day, value: 7 * weeks, to: weekStart) else { return }
        // Keep the same weekday selected in the new week.
        let offset = calendar.dateComponents([.day], from: weekStart, to: selected).day ?? 0
        weekStart = moved
        selected = calendar.date(byAdding: .day, value: max(0, min(offset, 6)), to: moved) ?? moved
        await reload()
    }

    func goToToday() async {
        let today = calendar.startOfDay(for: now())
        weekStart = ScheduleLayout.weekDays(containing: today, calendar: calendar).first ?? today
        selected = today
        await reload()
    }

    func reload() async {
        let load = load, days = days
        do {
            let loaded = try await Task.detached { try load(days) }.value
            if reports != loaded { reports = loaded }
            if loadFailed { loadFailed = false }
        } catch {
            reports = []
            loadFailed = true
        }
    }
}
