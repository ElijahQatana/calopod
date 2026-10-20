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
    /// A plain line under the headline when a good manual sync is not the whole story.
    var note: String?

    var color: Color {
        switch tone {
        case .good: Theme.good
        case .caution: Theme.caution
        case .bad: Theme.bad
        case .unknown: .secondary
        }
    }

    /// The one line in the menu bar window. Short enough to fit without cutting off the time.
    var menuLine: String {
        // Nothing syncs without access, so the time would only crowd the line.
        if label == "Needs Calendar access" { return "No Calendar access" }
        guard let age = lastSyncedAge.map(Format.ago) else { return label }
        return tone == .good ? "Last synced \(age)" : "\(label) · \(age)"
    }

    /// A good manual run keeps its own headline, but never reads as an all-clear while automatic sync is
    /// off, stopped, paused or failing: the icon turns to caution and a note says what is wrong. An
    /// automatic failure after the manual run still wins the headline.
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

        if let fresh, let manualAge, fresh.succeeded, status.state != "ok", !failedAfter(fresh, status: status, statusAt: statusAt) {
            let note: String
            switch status.state {
            case "disabled": note = "Automatic sync is off, so changes will not sync by themselves."
            case "paused": note = "Scheduled syncs are paused, so changes will not sync by themselves."
            case "failed": note = status.message.isEmpty ? "The last automatic sync didn't finish." : status.message
            default: note = status.message.isEmpty ? "Automatic sync is stopped, so changes will not sync by themselves." : status.message
            }
            let symbol = status.state == "disabled" ? "power" : status.state == "paused" ? "pause.fill" : "exclamationmark"
            let label = ["disabled": "Sync is off", "paused": "Paused", "failed": "Needs attention"][status.state] ?? "Stopped"
            return SyncHealth(tone: .caution, symbol: symbol, label: label, headline: fresh.summary, detail: detail(manualAge), lastSyncedAge: manualAge, offersEnable: Self.canEnable(status), note: note)
        }

        let age = status.lastSuccessAgeSeconds
        func reason(_ text: String) -> String { text.isEmpty ? detail(age) : text }
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
            return SyncHealth(tone: .bad, symbol: "exclamationmark", label: "Stopped", headline: "Automatic sync is stopped", detail: reason(status.message), lastSyncedAge: age, offersEnable: Self.canEnable(status))
        }
    }

    /// Off, or on but not running. Enable starts whichever service is the live one.
    static func canEnable(_ status: AgentControlStatus) -> Bool {
        status.state == "disabled" || status.state == "stopped"
    }

    /// An automatic run failed after the manual run finished.
    static func failedAfter(_ run: ManualRun, status: AgentControlStatus, statusAt: Date) -> Bool {
        guard status.state == "failed", let ago = status.failureAgeSeconds else { return false }
        return statusAt.addingTimeInterval(-Double(ago)) > run.finishedAt
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
