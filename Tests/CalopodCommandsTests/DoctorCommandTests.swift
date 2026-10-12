@testable import CalopodCommands
import CalopodStore
import Foundation
import Testing

@Test
func missingClientIDIsAKnownFailureCategory() {
    #expect(genericFailureCategory("client-id") == "client-id")
}

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
func providerDoctorCheckIgnoresConnectionsUnusedByAutomaticSync() throws {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
    let sourceConnection = StoredConnection(
        id: "source-connection",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Synthetic source",
        isEnabled: true
    )
    let targetConnection = StoredConnection(
        id: "target-connection",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Synthetic target",
        isEnabled: true
    )
    let unusedConnection = StoredConnection(
        id: "unused-connection",
        configurationID: "default",
        provider: "eventkit",
        displayLabel: "Synthetic unused",
        isEnabled: true
    )
    let source = StoredCalendarBinding(
        id: "source-calendar",
        connectionID: sourceConnection.id,
        providerCalendarID: "source-provider-calendar",
        displayLabel: "Synthetic source calendar",
        isSelected: true,
        isReadOnly: false
    )
    let target = StoredCalendarBinding(
        id: "target-calendar",
        connectionID: targetConnection.id,
        providerCalendarID: "target-provider-calendar",
        displayLabel: "Synthetic target calendar",
        isSelected: false,
        isReadOnly: false
    )
    try repository.saveConnection(sourceConnection)
    try repository.saveConnection(targetConnection)
    try repository.saveConnection(unusedConnection)
    try repository.replaceCalendarBindings(
        connectionID: sourceConnection.id,
        bindings: [source]
    )
    try repository.replaceCalendarBindings(
        connectionID: targetConnection.id,
        bindings: [target]
    )
    try repository.saveArm(StoredArm(
        id: "arm",
        configurationID: "default",
        sourceBindingIDs: [source.id],
        targetBindingID: target.id,
        ruleMode: .busy,
        isEnabled: true
    ))
    try repository.applyEventRefresh(
        connectionID: sourceConnection.id,
        calendarBindingID: source.id,
        windowStart: Date(timeIntervalSince1970: 1_000),
        windowEnd: Date(timeIntervalSince1970: 2_000),
        instances: [],
        cancelledSourceKeyHashes: [],
        isFullRefresh: true,
        cursorUpdates: []
    )

    let connections = try automaticSyncSourceConnections(repository: repository)
    let check = try providerHealthCheck(connections: connections, repository: repository)

    #expect(connections.map(\.id) == [sourceConnection.id])
    #expect(check.kind == "ok")
}

@Test
func providerDoctorCheckExplainsWhenAutomaticSyncHasNoSources() throws {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())

    let connections = try automaticSyncSourceConnections(repository: repository)
    let check = try providerHealthCheck(connections: connections, repository: repository)

    #expect(check.kind == "pending")
    #expect(check.reason == "inactive")
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
