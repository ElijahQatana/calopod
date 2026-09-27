@testable import CalopodCommands
import CalopodStore
import Foundation
import Testing

@Test
func providerDoctorCheckAggregatesWithoutConnectionDetails() throws {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
    let connection = StoredConnection(
        id: "synthetic-connection",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Synthetic private label",
        isEnabled: true
    )
    try repository.saveConnection(connection)
    try repository.markConnectionStale(
        connectionID: connection.id,
        errorCode: "authorization"
    )

    let check = try providerHealthCheck(
        connections: [connection],
        repository: repository
    )

    #expect(check.id == "provider-health")
    #expect(check.kind == "failed")
    #expect(check.reason == "authorization")
    #expect(check.label == nil)
    #expect(check.parentID == nil)
}

@Test
func doctorReplacesUnknownStoredFailuresWithAGenericCategory() {
    #expect(genericFailureCategory("authorization") == "authorization")
    #expect(genericFailureCategory("private-provider-message") == "provider")
    #expect(genericFailureCategory(nil) == "provider")
}

@Test
func doctorDistinguishesDisabledAndUnexpectedlyStoppedServices() {
    let disabled = serviceHealthCheck(LaunchAgentSnapshot(
        installed: true,
        loaded: false,
        disabled: true,
        configuration: nil
    ))
    let stopped = serviceHealthCheck(LaunchAgentSnapshot(
        installed: true,
        loaded: false,
        disabled: false,
        configuration: nil
    ))
    let running = serviceHealthCheck(LaunchAgentSnapshot(
        installed: true,
        loaded: true,
        disabled: false,
        configuration: nil
    ))

    #expect(disabled.item.kind == "pending")
    #expect(disabled.item.reason == "disabled")
    #expect(stopped.item.kind == "failed")
    #expect(stopped.item.reason == "stopped")
    #expect(running.item.kind == "ok")
    #expect(running.warning == nil)
}
