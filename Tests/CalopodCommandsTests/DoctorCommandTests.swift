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
