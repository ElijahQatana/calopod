import CalopodCommands
import ServiceManagement

/// What the service model needs from the registration, so tests can stand in for macOS.
protocol BundledServiceRegistering: Sendable {
    func state() -> ServiceRegistration.State
    func register() throws
}

extension ServiceRegistration: BundledServiceRegistering {}

/// Registers the bundled agent with macOS. Only works from the built Calopod.app.
struct ServiceRegistration: Sendable {
    static let plistName = BackgroundServiceState.agentPlistName

    typealias State = BackgroundServiceState

    private var service: SMAppService { .agent(plistName: Self.plistName) }

    static var isRunningFromBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func state() -> State { .read(plistName: Self.plistName) }

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
