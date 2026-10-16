import ServiceManagement

/// Registers the bundled background agent with macOS (System Settings > Login Items). Only works
/// from the built `Calopod.app`; a bare `swift run` executable has no bundled agent to register.
struct ServiceRegistration: Sendable {
    static let plistName = "pro.elijahquintana.calopod.app-agent.plist"

    enum State: Equatable, Sendable {
        /// Not running from an app bundle, so there is nothing to register.
        case unavailable
        case notRegistered
        case requiresApproval
        case enabled
        /// The bundle does not contain the agent plist.
        case notFound
    }

    private var service: SMAppService { .agent(plistName: Self.plistName) }

    static var isRunningFromBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func state() -> State {
        guard Self.isRunningFromBundle else { return .unavailable }
        return switch service.status {
        case .notRegistered: .notRegistered
        case .requiresApproval: .requiresApproval
        case .enabled: .enabled
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() async throws {
        try await service.unregister()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
