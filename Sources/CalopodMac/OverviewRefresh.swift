import Foundation
import Observation

/// One Refresh calendars action for the whole Overview page. It reads the calendars again, then
/// reloads everything the page shows, so no section keeps an older picture than the others.
@MainActor
@Observable
final class OverviewRefresh {
    struct Step {
        let section: String
        /// Does the work and returns a plain message when it failed.
        let run: @MainActor () async -> String?
    }

    struct Message: Identifiable, Equatable {
        let id: String
        let text: String
    }

    private(set) var isBusy = false
    private(set) var messages: [Message] = []
    /// When the last refresh finished with nothing failing.
    private(set) var refreshedAt: Date?

    @ObservationIgnored private let steps: [Step]

    init(steps: [Step]) { self.steps = steps }

    /// In order: the calendar refresh and Inbox board, the schedule, the agent status and runs, Calendar access.
    convenience init(inbox: InboxModel, schedule: CalendarModel, service: ServiceModel, access: CalendarAccessModel) {
        self.init(steps: [
            Step(section: "Inbox") {
                await inbox.refresh()
                return inbox.notice
            },
            Step(section: "Schedule") {
                await schedule.reload()
                return schedule.loadFailed ? "The calendar list could not be read, so Next up today and Calendars may be out of date." : nil
            },
            Step(section: "Sync") {
                await service.refresh()
                return service.status == nil ? "The sync status could not be read." : nil
            },
            Step(section: "Access") {
                await access.check()
                return access.hostFailure.map { "Calendar access could not be checked. \($0)" }
            },
        ])
    }

    func run() async {
        guard !isBusy else { return }
        isBusy = true
        messages = []
        var failed: [Message] = []
        for step in steps {
            if let text = await step.run() { failed.append(Message(id: step.section, text: text)) }
        }
        messages = failed
        if failed.isEmpty { refreshedAt = Date() }
        isBusy = false
    }

    func dismiss(_ id: String) { messages.removeAll { $0.id == id } }

    func dismissAll() { messages = [] }

    /// "Last refreshed just now" under the status headline, once a refresh has finished.
    func refreshedText(now: Date = Date()) -> String? {
        refreshedAt.map { "Last refreshed \(Format.ago(max(0, Int(now.timeIntervalSince($0)))))" }
    }
}
