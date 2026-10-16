import CalopodCommands
import CalopodRuntime
import Foundation
import Observation

/// Holds what the window shows and routes every action to `AgentControlService`, the same
/// controller and runner behind `calopod agent ...`. Blocking launchctl work stays off the main actor.
@MainActor
@Observable
final class ServiceModel {
    private(set) var status: AgentControlStatus?
    private(set) var overview: AgentControlOverview?
    private(set) var busyAction: String?
    private(set) var notice: String?
    private(set) var lastRunSummary: String?

    private let service = AgentControlService()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    deinit { refreshTask?.cancel() }

    var menuBarSymbol: String {
        switch status?.state {
        case "ok": "calendar.badge.checkmark"
        case "paused", "disabled": "calendar.badge.minus"
        case "failed", "stopped": "calendar.badge.exclamationmark"
        default: "calendar"
        }
    }

    var isBusy: Bool { busyAction != nil }

    func refresh() async {
        let service = service
        let result = await Task.detached {
            (try? service.status(), try? service.overview())
        }.value
        if busyAction == nil {
            status = result.0
            overview = result.1
        }
    }

    func syncNow() async {
        let service = service
        await perform("Syncing…") {
            let report = try await service.syncNow()
            return Self.summary(of: report)
        }
    }

    func setEnabled(_ enabled: Bool) async {
        let service = service
        await perform(enabled ? "Enabling…" : "Disabling…") {
            try service.setEnabled(enabled)
            return nil
        }
    }

    func setPaused(_ paused: Bool) async {
        let service = service
        await perform(paused ? "Pausing…" : "Resuming…") {
            try service.setPaused(paused)
            return nil
        }
    }

    func setInterval(seconds: Int) async {
        let service = service
        await perform("Updating interval…") {
            try service.setInterval(seconds: seconds)
            return nil
        }
    }

    private func perform(
        _ label: String,
        _ work: @escaping @Sendable () async throws -> String?
    ) async {
        guard busyAction == nil else { return }
        busyAction = label
        notice = nil
        do {
            let summary = try await Task.detached { try await work() }.value
            if let summary { lastRunSummary = summary }
        } catch {
            notice = service.message(for: error)
        }
        busyAction = nil
        await refresh()
    }

    private nonisolated static func summary(of report: AgentRunReport) -> String {
        switch report.status {
        case "ok":
            "Synced: \(report.creates) created, \(report.updates) updated, \(report.removals) removed."
        case "busy":
            "Another sync is already running."
        case "interrupted":
            "The sync was interrupted."
        default:
            "The sync failed. Run calopod doctor for details."
        }
    }
}
