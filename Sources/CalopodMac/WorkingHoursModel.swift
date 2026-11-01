import CalopodStore
import Foundation
import Observation

/// The working hours as Settings shows them. They are saved in the local state, which the command
/// line reads and writes too, so `reload` picks up a change made there.
@MainActor
@Observable
final class WorkingHoursModel {
    private(set) var hours: WorkingHours
    private(set) var focus: FocusSettings
    /// Why the last change was refused, in plain words. Cleared by the next change that works.
    private(set) var notice: String?
    /// Called after a saved change, so availability follows.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let state: LocalStateRepository?

    init(state: LocalStateRepository?) {
        self.state = state
        hours = (try? state?.workingHours()) ?? .standard
        focus = (try? state?.focusSettings()) ?? .standard
    }

    func reload() {
        guard let state else { return }
        if let saved = try? state.workingHours(), saved != hours { hours = saved }
        if let saved = try? state.focusSettings(), saved != focus { focus = saved }
    }

    func apply(_ change: (WorkingHours) throws -> WorkingHours) {
        do {
            let changed = try change(hours)
            guard changed != hours else { notice = nil; return }
            try state?.saveWorkingHours(changed)
            hours = changed
            notice = nil
            onChange?()
        } catch {
            notice = error.localizedDescription
        }
    }

    func setFocus(minutes: Int) {
        do {
            let changed = try FocusSettings(minutes: minutes)
            guard changed != focus else { notice = nil; return }
            try state?.saveFocusSettings(changed)
            focus = changed
            notice = nil
            onChange?()
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Turns a day on, at the standard hours, or off.
    func setWorking(_ working: Bool, isoWeekday: Int) {
        apply { try $0.setting(isoWeekday: isoWeekday, to: working ? WorkingHours.standard.day(isoWeekday: 1) : nil) }
    }

    func setStart(_ minute: Int, isoWeekday: Int) {
        apply { current in
            guard let day = current.day(isoWeekday: isoWeekday) else { return current }
            return try current.setting(isoWeekday: isoWeekday, to: WorkingHours.Day(startMinute: minute, endMinute: day.endMinute))
        }
    }

    func setEnd(_ minute: Int, isoWeekday: Int) {
        apply { current in
            guard let day = current.day(isoWeekday: isoWeekday) else { return current }
            return try current.setting(isoWeekday: isoWeekday, to: WorkingHours.Day(startMinute: day.startMinute, endMinute: minute))
        }
    }
}
