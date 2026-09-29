@testable import CalopodCommands
import Foundation
import Testing

#if os(macOS)
@Test
func restoreRequiresAnInstalledServiceToBeDisabledAndUnloaded() throws {
    let configuration = AgentServiceConfiguration(
        programURL: URL(fileURLWithPath: "/example/calopod-agent"),
        stateURL: URL(fileURLWithPath: "/example/state.sqlite"),
        eventKitHostURL: URL(fileURLWithPath: "/example/Calopod EventKit Host.app"),
        intervalSeconds: 900,
        jitterSeconds: 45,
        lookbackDays: 1,
        horizonDays: 30,
        environment: [:]
    )

    try requireServiceStoppedForRestore(
        LaunchAgentSnapshot(
            installed: true,
            loaded: false,
            disabled: true,
            configuration: configuration
        )
    )
    try requireServiceStoppedForRestore(
        LaunchAgentSnapshot(
            installed: false,
            loaded: false,
            disabled: false,
            configuration: nil
        )
    )

    #expect(throws: SupportCommandError.serviceMustBeStopped) {
        try requireServiceStoppedForRestore(
            LaunchAgentSnapshot(
                installed: true,
                loaded: false,
                disabled: false,
                configuration: configuration
            )
        )
    }
    #expect(throws: SupportCommandError.serviceMustBeStopped) {
        try requireServiceStoppedForRestore(
            LaunchAgentSnapshot(
                installed: true,
                loaded: true,
                disabled: true,
                configuration: configuration
            )
        )
    }
}
#endif
