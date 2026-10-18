import ServiceManagement

/// What the service model needs from the registration, so tests can stand in for macOS.
protocol BundledServiceRegistering: Sendable {
    func state() -> ServiceRegistration.State
    func register() throws
}

extension ServiceRegistration: BundledServiceRegistering {}

/// Registers the bundled agent with macOS. Only works from the built Calopod.app.
struct ServiceRegistration: Sendable {
    static let plistName = "pro.elijahquintana.calopod.app-agent.plist"

    enum State: Equatable, Sendable {
        case unavailable
        case notRegistered
        case requiresApproval
        case enabled
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
