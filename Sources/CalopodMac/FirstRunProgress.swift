import Foundation
import Observation

/// Where the guided setup stands. Skipping keeps the place so Overview can resume it.
@MainActor
@Observable
final class FirstRunProgress {
    enum Step: Int, CaseIterable {
        case connect, calendars, destinations

        var title: String {
            switch self {
            case .connect: "Connect"
            case .calendars: "Calendars and colors"
            case .destinations: "Where events go"
            }
        }
    }

    private static let stepKey = "firstRunStep"
    private static let startedKey = "firstRunStarted"
    private static let finishedKey = "firstRunFinished"

    private(set) var step: Step
    private(set) var started: Bool
    private(set) var isFinished: Bool
    /// Set only when the sync preview is approved. Nothing is written to calendars before that.
    private(set) var previewApproved = false

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.forSingleton) {
        self.defaults = defaults
        step = Step(rawValue: defaults.integer(forKey: Self.stepKey)) ?? .connect
        started = defaults.bool(forKey: Self.startedKey)
        isFinished = defaults.bool(forKey: Self.finishedKey)
    }

    /// First launch, before the sheet has ever been opened.
    var shouldOpenAutomatically: Bool { !started && !isFinished }

    /// Setup was opened or skipped and is not done yet.
    var canResume: Bool { started && !isFinished }

    var isFirst: Bool { step == .connect }
    var isLast: Bool { step == .destinations }

    func begin() {
        started = true
        defaults.set(true, forKey: Self.startedKey)
    }

    /// Connecting needs an account, choosing needs a selected calendar.
    func canContinue(connections: Int, selectedCalendars: Int) -> Bool {
        switch step {
        case .connect: connections > 0
        case .calendars: selectedCalendars > 0
        case .destinations: false
        }
    }

    func next() {
        guard let following = Step(rawValue: step.rawValue + 1) else { return }
        move(to: following)
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        move(to: previous)
    }

    func approvePreview() {
        previewApproved = true
        isFinished = true
        defaults.set(true, forKey: Self.finishedKey)
    }

    private func move(to newStep: Step) {
        step = newStep
        defaults.set(newStep.rawValue, forKey: Self.stepKey)
    }
}
