import CalopodCommands
import SwiftUI

/// A sync run started from the app, kept only until the agent reports something newer.
struct ManualRun: Equatable {
    let summary: String
    let succeeded: Bool
    let finishedAt: Date
    /// The agent state seen right after the run; a different state later means the run is out of date.
    var settledState: String?
}

/// What the Overview card, the sidebar dot and the menu bar window all show for sync.
struct SyncHealth: Equatable {
    enum Tone { case good, caution, bad, unknown }

    let tone: Tone
    let symbol: String
    /// Short label for the sidebar and menu bar window.
    let label: String
    let headline: String
    let detail: String
    /// Seconds since the last good sync, from whichever source is newer.
    let lastSyncedAge: Int?
    /// Automatic sync is switched off, so Overview and the menu offer a button to turn it on.
    var offersEnable = false

    var color: Color {
        switch tone {
        case .good: Theme.good
        case .caution: Theme.caution
        case .bad: Theme.bad
        case .unknown: .secondary
        }
    }

    /// A manual run can replace the headline only when the agent is healthy. When automatic sync is
    /// off, stopped, paused or failing, that stays the headline and the run only updates "last synced".
    static func make(status: AgentControlStatus?, statusAt: Date, run: ManualRun?, access: CalendarAccessState = .unchecked, now: Date = Date()) -> SyncHealth {
        guard let status else {
            return SyncHealth(tone: .unknown, symbol: "exclamationmark", label: "Checking…", headline: "Checking sync…", detail: "", lastSyncedAge: nil)
        }
        guard status.installed else {
            return SyncHealth(tone: .unknown, symbol: "exclamationmark", label: "Not set up yet", headline: "Automatic sync is not set up", detail: status.message, lastSyncedAge: nil)
        }
        // Without Calendar access nothing can sync, whatever the last run said.
        if access.isMissing {
            return SyncHealth(
                tone: access == .blocked ? .bad : .caution, symbol: "exclamationmark", label: "Needs Calendar access",
                headline: access.title, detail: "Syncing needs Calendar access.", lastSyncedAge: status.lastSuccessAgeSeconds)
        }
        let interval = status.intervalSeconds.map { "every \(Format.interval($0))" }
        func detail(_ age: Int?) -> String {
            let parts = [age.map { "Last synced \(Format.ago($0))" }, interval].compactMap { $0 }
            return parts.isEmpty ? status.message : parts.joined(separator: " · ")
        }

        let fresh = run.flatMap { newer($0, than: status, statusAt: statusAt) ? $0 : nil }
        let manualAge = fresh.map { max(0, Int(now.timeIntervalSince($0.finishedAt))) }

        if let fresh, let manualAge, ["ok", "failed", "stopped"].contains(status.state) {
            if fresh.succeeded, status.state == "ok" {
                return SyncHealth(tone: .good, symbol: "checkmark", label: "Syncing", headline: fresh.summary, detail: detail(manualAge), lastSyncedAge: manualAge)
            }
            if !fresh.succeeded {
                return SyncHealth(tone: .bad, symbol: "exclamationmark", label: "Needs attention", headline: fresh.summary, detail: detail(status.lastSuccessAgeSeconds), lastSyncedAge: status.lastSuccessAgeSeconds)
            }
        }

        // A good manual run still counts as the latest sync, but never hides what the agent is doing.
        let age = fresh?.succeeded == true ? manualAge : status.lastSuccessAgeSeconds
        let synced = fresh?.succeeded == true ? age.map { "Last synced \(Format.ago($0))" } : nil
        func reason(_ text: String) -> String {
            text.isEmpty ? detail(age) : [text, synced].compactMap { $0 }.joined(separator: " · ")
        }
        switch status.state {
        case "ok":
            return SyncHealth(tone: .good, symbol: "checkmark", label: "Syncing", headline: "Everything is in sync", detail: detail(age), lastSyncedAge: age)
        case "paused":
            return SyncHealth(tone: .caution, symbol: "pause.fill", label: "Paused", headline: "Scheduled syncs are paused", detail: detail(age), lastSyncedAge: age)
        case "disabled":
            return SyncHealth(tone: .caution, symbol: "power", label: "Sync is off", headline: "Automatic sync is off", detail: detail(age), lastSyncedAge: age, offersEnable: true)
        case "failed":
            return SyncHealth(tone: .bad, symbol: "exclamationmark", label: "Needs attention", headline: "The last sync didn't finish", detail: reason(status.message), lastSyncedAge: age)
        default:
            return SyncHealth(tone: .bad, symbol: "exclamationmark", label: "Stopped", headline: "Automatic sync is stopped", detail: reason(status.message), lastSyncedAge: age)
        }
    }

    /// True when the agent's last good run came before the manual run finished.
    static func newer(_ run: ManualRun, than status: AgentControlStatus, statusAt: Date) -> Bool {
        guard let age = status.lastSuccessAgeSeconds else { return true }
        return run.finishedAt > statusAt.addingTimeInterval(-Double(age))
    }

    /// Applied on every status refresh. The first one after a run records the state it left; a
    /// different state later, or an agent result newer than the run, drops the run.
    static func settled(_ run: ManualRun?, status: AgentControlStatus, statusAt: Date) -> ManualRun? {
        guard var run else { return nil }
        guard let seen = run.settledState else {
            run.settledState = status.state
            return run
        }
        return seen == status.state && newer(run, than: status, statusAt: statusAt) ? run : nil
    }
}

extension SyncHealth {
    /// The failed checks worth showing. A last automatic run that failed is dropped once a sync done
    /// from the app finished after it.
    static func attentionChecks(
        _ health: HealthReport?, status: AgentControlStatus?, statusAt: Date, run: ManualRun?
    ) -> [HealthReport.Check] {
        guard let health else { return [] }
        let failedAt = status?.failureAgeSeconds.map { statusAt.addingTimeInterval(-Double($0)) }
        let recovered = run.map { run in run.succeeded && (failedAt.map { run.finishedAt > $0 } ?? false) } ?? false
        return health.checks.filter { $0.state != "ok" && !($0.name == "automatic-run" && recovered) }
    }
}
