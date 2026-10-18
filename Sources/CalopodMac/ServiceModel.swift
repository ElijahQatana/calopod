import CalopodCommands
import CalopodRuntime
import AppKit
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
    private(set) var lastRun: ManualRun?
    private(set) var statusAt = Date()
    private(set) var pendingPreview: SyncPreview?
    private(set) var health: HealthReport?
    private(set) var registration: ServiceRegistration.State = .unavailable

    private typealias AgentState = (status: AgentControlStatus?, overview: AgentControlOverview?, health: HealthReport?)
    private var service = AgentControlService()
    private let registrar = ServiceRegistration()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                // Slower while Calopod is in the background, such as with only the menu bar item showing.
                let active = self?.isAppActive ?? false
                try? await Task.sleep(for: .seconds(active ? 15 : 60))
            }
        }
    }

    deinit { refreshTask?.cancel() }

    private var isAppActive: Bool { NSApplication.shared.isActive }

    /// Set by the app from the Calendar access check; `.unchecked` until a Mac connection exists.
    var calendarAccess: CalendarAccessState = .unchecked
    var syncHealth: SyncHealth {
        SyncHealth.make(status: status, statusAt: statusAt, run: lastRun, access: calendarAccess)
    }
    var menuBarAlert: Bool { syncHealth.tone == .bad }
    var menuBarDimmed: Bool { syncHealth.tone == .caution }

    var isBusy: Bool { busyAction != nil }

    private static var bundledAgentExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/calopod-agent")
    }

    func refresh() async {
        let updating = busyAction == nil
        let registrar = registrar
        let current = service
        let bundled = Self.bundledAgentExecutable
        // Registration status and the service reads can block, so they stay off the main actor.
        let result = await Task.detached { () -> (ServiceRegistration.State?, AgentControlService, AgentState) in
            var service = current
            var state: ServiceRegistration.State?
            if updating {
                let found = registrar.state()
                state = found
                service = AgentControlService(bundledAgentExecutable: found == .enabled ? bundled : nil)
            }
            return (state, service, service.state())
        }.value
        guard busyAction == nil else { return }
        if let state = result.0 {
            if registration != state { registration = state }
            service = result.1
        }
        // Equal values are not assigned, so a quiet poll redraws nothing.
        if status != result.2.status { status = result.2.status }
        statusAt = Date()
        settleManualRun()
        if overview != result.2.overview { overview = result.2.overview }
        if health != result.2.health { health = result.2.health }
    }

    private func settleManualRun() {
        guard let status else { return }
        lastRun = SyncHealth.settled(lastRun, status: status, statusAt: statusAt)
    }

    private func finishRun(_ summary: String, succeeded: Bool) {
        lastRun = ManualRun(summary: summary, succeeded: succeeded, finishedAt: Date(), settledState: nil)
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
                finishRun("Everything is up to date. Nothing to change.", succeeded: true)
            } else {
                pendingPreview = preview
            }
        } catch {
            notice = service.message(for: error)
        }
        busyAction = nil
        await refresh()
    }

    /// Clears the error banner. Also used when the screen is left.
    func dismissNotice() { notice = nil }

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
                    finishRun("Everything is up to date. Nothing to change.", succeeded: true)
                } else {
                    pendingPreview = fresh
                    notice = "Your calendars changed since this preview, so the list was updated. Review it before applying."
                }
            } else {
                busyAction = "Syncing…"
                let report = try await Task.detached { try await service.syncNow() }.value
                let summary = Self.summary(of: report)
                completed = report.status == "ok"
                finishRun(summary, succeeded: completed)
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

    /// Stops the source-installed agent first so two never run. It is turned back on if registering
    /// fails or macOS still needs approval, so syncing never stops without the new service taking over.
    func installBundledService() async {
        let service = service
        let registrar = registrar
        let legacyActive = legacyServiceActive
        await perform("Installing background service…") {
            try Self.install(legacyActive: legacyActive, registrar: registrar, setLegacyEnabled: { try service.setEnabled($0) })
            return nil
        }
    }

    nonisolated static func install(
        legacyActive: Bool, registrar: some BundledServiceRegistering, setLegacyEnabled: (Bool) throws -> Void
    ) throws {
        if legacyActive { try setLegacyEnabled(false) }
        do {
            // Already approved when finishing a move, and registering twice is an error.
            if registrar.state() != .enabled { try registrar.register() }
        } catch {
            if legacyActive { try? setLegacyEnabled(true) }
            throw error
        }
        if legacyActive, registrar.state() != .enabled {
            try? setLegacyEnabled(true)
            throw InstallError.needsApproval
        }
    }

    enum InstallError: Error {
        case needsApproval
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
        lastRun = nil
        do {
            _ = try await Task.detached { try await work() }.value
        } catch {
            let nsError = error as NSError
            if error is InstallError {
                notice = "Allow Calopod in System Settings, General, Login Items, then choose Move to the app again. Your current service keeps running until then."
            } else {
                notice = nsError.domain == "SMAppServiceErrorDomain"
                    ? nsError.localizedDescription
                    : service.message(for: error)
            }
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
            "The sync failed. Try again in a moment. If it keeps failing, reconnect your calendar accounts."
        }
    }
}
