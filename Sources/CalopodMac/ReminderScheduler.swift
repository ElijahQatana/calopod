import CalopodCommands
import CalopodStore
import Foundation

/// The part of the notification center the scheduler uses, so tests can stand in for it.
protocol ReminderCenter: Sendable {
    func permission() async -> NotificationPermissionState
    func requestPermission() async -> Bool
    func pending() async -> [PendingReminder]
    func add(_ reminder: PlannedReminder) async
    func remove(ids: [String]) async
}

/// Keeps the center's pending reminders in step with the local schedule. It runs after each schedule
/// reload, when settings change and when the app comes forward. Calls that arrive while one is running
/// are folded into one more pass, so reminders are never added twice at once.
@MainActor
final class ReminderScheduler {
    private let center: (any ReminderCenter)?
    private let settings: @MainActor () -> NotificationSettings
    private let schedule: @MainActor () -> CalendarSchedule?
    private let ignored: @MainActor (String) -> Bool
    private let shownName: @MainActor (ScheduleCalendar) -> String
    private let now: () -> Date
    private var running = false
    private var again = false

    init(
        center: (any ReminderCenter)?, settings: @escaping @MainActor () -> NotificationSettings,
        schedule: @escaping @MainActor () -> CalendarSchedule?, ignored: @escaping @MainActor (String) -> Bool,
        shownName: @escaping @MainActor (ScheduleCalendar) -> String, now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.settings = settings
        self.schedule = schedule
        self.ignored = ignored
        self.shownName = shownName
        self.now = now
    }

    func reconcile() async {
        guard center != nil else { return }
        if running { again = true; return }
        running = true
        repeat {
            again = false
            await pass()
        } while again
        running = false
    }

    private func pass() async {
        guard let center else { return }
        // Before the first load there is nothing to compare with, and an empty plan would clear every reminder.
        guard let loaded = schedule() else { return }
        let wanted: [PlannedReminder]
        if await center.permission() == .allowed {
            wanted = ReminderPlanner.plan(
                schedule: loaded, settings: settings(), now: now(), ignored: ignored, calendarName: shownName)
        } else {
            wanted = []
        }
        let diff = ReminderReconciler.diff(desired: wanted, pending: await center.pending())
        if !diff.remove.isEmpty { await center.remove(ids: diff.remove) }
        for reminder in diff.add { await center.add(reminder) }
    }
}
