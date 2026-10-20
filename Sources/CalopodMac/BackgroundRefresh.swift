import AppKit
import CalopodRuntime

/// Keeps the local copies and reminders current for as long as the app runs, with or without the
/// menu bar item or the window.
@MainActor
enum BackgroundRefresh {
    private static var started = false

    static func start(
        inbox: InboxModel, schedule: CalendarModel, iPhoneFeed: IPhoneFeedModel, permissions: PermissionsModel,
        reminders: ReminderScheduler, navigation: AppNavigation
    ) {
        guard !started, !RunningUnderTests.isActive else { return }
        started = true
        Task {
            var first = true
            while !Task.isCancelled {
                await inbox.reload()
                await schedule.reload()
                await iPhoneFeed.tick()
                if first {
                    first = false
                    // A click on a reminder that launched the app waits for this first read.
                    ReminderRouter.shared.attach { ReminderNavigation.open($0, schedule: schedule, navigation: navigation) }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        // Reminders are checked again whenever the app comes forward.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                await permissions.refreshNotifications()
                await reminders.reconcile()
            }
        }
    }
}
