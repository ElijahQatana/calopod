import CalopodCommands
import CalopodRuntime
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class ServiceModel {
    private(set) var status: AgentControlStatus?
    private(set) var overview: AgentControlOverview?
    private(set) var busyAction: String?
    private(set) var notice: String?
    private(set) var lastRunSummary: String?
    private(set) var pendingPreview: SyncPreview?
    private(set) var health: HealthReport?
    private(set) var registration: ServiceRegistration.State = .unavailable

    private var service = AgentControlService()
    private let registrar = ServiceRegistration()
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

    var menuBarAlert: Bool { ["failed", "stopped"].contains(status?.state) }
    var menuBarDimmed: Bool { ["paused", "disabled"].contains(status?.state) }

    var isBusy: Bool { busyAction != nil }

    private static var bundledAgentExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/calopod-agent")
    }

    private func updateService() {
        let state = registrar.state()
        registration = state
        service = AgentControlService(
            bundledAgentExecutable: state == .enabled ? Self.bundledAgentExecutable : nil
        )
    }

    func refresh() async {
        if busyAction == nil { updateService() }
        let service = service
        let result = await Task.detached {
            (try? service.status(), try? service.overview(), try? service.health())
        }.value
        if busyAction == nil {
            status = result.0
            overview = result.1
            health = result.2
        }
    }

    func previewSync() async {
        guard busyAction == nil else { return }
        let service = service
        busyAction = "Planning sync…"
        notice = nil
        pendingPreview = nil
        do {
            let preview = try await Task.detached { try await service.preview() }.value
            if preview.changeCount == 0 {
                lastRunSummary = "Everything is up to date. Nothing to change."
            } else {
                pendingPreview = preview
            }
        } catch {
            notice = service.message(for: error)
        }
        busyAction = nil
        await refresh()
    }

    func discardPreview() {
        pendingPreview = nil
    }

    /// Plans again first. If the changes differ from what was shown, the new list replaces it and
    /// nothing is written, so only an approved plan is applied. Returns true when the sync completed.
    @discardableResult
    func applyPreview() async -> Bool {
        guard busyAction == nil, let approved = pendingPreview else { return false }
        pendingPreview = nil
        let service = service
        busyAction = "Checking the plan…"
        notice = nil
        var completed = false
        do {
            let fresh = try await Task.detached { try await service.preview() }.value
            if !Self.samePlan(Self.planKeys(approved), Self.planKeys(fresh)) {
                if fresh.changeCount == 0 {
                    lastRunSummary = "Everything is up to date. Nothing to change."
                } else {
                    pendingPreview = fresh
                    notice = "Your calendars changed since this preview, so the list was updated. Review it before applying."
                }
            } else {
                busyAction = "Syncing…"
                let report = try await Task.detached { try await service.syncNow() }.value
                let summary = Self.summary(of: report)
                lastRunSummary = summary
                completed = report.status == "ok"
                if !completed { notice = summary }
            }
        } catch {
            notice = service.message(for: error)
        }
        busyAction = nil
        await refresh()
        return completed
    }

    /// One entry per planned change, so two plans can be compared.
    nonisolated static func planKeys(_ preview: SyncPreview) -> [String] {
        preview.lines.map { "\($0.id)|\($0.action)" }
    }

    /// Same planned changes, whatever order they come in.
    nonisolated static func samePlan(_ a: [String], _ b: [String]) -> Bool { a.sorted() == b.sorted() }

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

    var legacyServiceActive: Bool {
        guard let status, status.installed else { return false }
        return status.enabled || status.running
    }

    /// Stops the source-installed agent first so two never run, and restores it if registering fails.
    func installBundledService() async {
        let service = service
        let registrar = registrar
        let legacyActive = legacyServiceActive
        await perform("Installing background service…") {
            if legacyActive { try service.setEnabled(false) }
            do {
                try registrar.register()
            } catch {
                if legacyActive { try? service.setEnabled(true) }
                throw error
            }
            return nil
        }
    }

    func removeBundledService() async {
        let registrar = registrar
        await perform("Removing background service…") {
            try await registrar.unregister()
            return nil
        }
    }

    func openLoginItemsSettings() {
        registrar.openLoginItemsSettings()
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
            let nsError = error as NSError
            notice = nsError.domain == "SMAppServiceErrorDomain"
                ? nsError.localizedDescription
                : service.message(for: error)
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
