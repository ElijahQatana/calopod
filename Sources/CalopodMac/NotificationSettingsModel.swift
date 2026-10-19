import CalopodStore
import Foundation
import Observation

/// The reminder settings as Settings shows them. They are saved in the local state, which the command
/// line reads and writes too, so `reload` picks up a change made there.
@MainActor
@Observable
final class NotificationSettingsModel {
    private(set) var settings: NotificationSettings
    /// Why the last change was refused, in plain words. Cleared by the next change that works.
    private(set) var notice: String?
    /// Called after a saved change, so the pending reminders follow.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let state: LocalStateRepository?

    init(state: LocalStateRepository?) {
        self.state = state
        settings = (try? state?.notificationSettings()) ?? .standard
    }

    /// The saved settings, for the scheduler.
    func current() -> NotificationSettings {
        reload()
        return settings
    }

    func reload() {
        guard let state, let saved = try? state.notificationSettings(), saved != settings else { return }
        settings = saved
    }

    func apply(_ change: (NotificationSettings) throws -> NotificationSettings) {
        do {
            let changed = try change(settings)
            guard changed != settings else { notice = nil; return }
            try state?.saveNotificationSettings(changed)
            settings = changed
            notice = nil
            onChange?()
        } catch {
            notice = error.localizedDescription
        }
    }

    // Bounds for the steppers, so the order rule is kept without an error in the usual case.
    var firstRange: ClosedRange<Int> {
        let lower = settings.finalEnabled ? min(settings.finalMinutes + 1, NotificationSettings.minutes.upperBound) : 1
        return lower...NotificationSettings.minutes.upperBound
    }

    var finalRange: ClosedRange<Int> {
        let upper = settings.firstEnabled ? max(settings.firstMinutes - 1, 1) : NotificationSettings.minutes.upperBound
        return 1...upper
    }
}
