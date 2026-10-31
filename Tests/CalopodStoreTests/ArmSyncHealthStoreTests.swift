import CalopodStore
import Foundation
import Testing

@Suite("Arm sync health")
struct ArmSyncHealthStoreTests {
    private func makeRepository() throws -> LocalStateRepository {
        let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
        try repository.saveConnection(StoredConnection(
            id: "synthetic-connection", configurationID: "synthetic-configuration",
            provider: "eventkit", displayLabel: "Synthetic provider", isEnabled: true))
        try repository.replaceCalendarBindings(
            connectionID: "synthetic-connection",
            bindings: ["synthetic-source", "synthetic-target"].map {
                StoredCalendarBinding(
                    id: $0, connectionID: "synthetic-connection", providerCalendarID: "provider-\($0)",
                    displayLabel: $0, isSelected: true, isReadOnly: false)
            })
        try repository.saveArm(StoredArm(
            id: "synthetic-arm", configurationID: "synthetic-configuration",
            sourceBindingIDs: ["synthetic-source"], targetBindingID: "synthetic-target", ruleMode: .busy))
        return repository
    }

    @Test("A failed run keeps the last success, and a later success clears the error")
    func failureKeepsSuccess() throws {
        let repository = try makeRepository()
        #expect(try repository.armSyncHealth(armID: "synthetic-arm") == nil)

        let first = Date(timeIntervalSince1970: 100)
        try repository.recordArmSync(armID: "synthetic-arm", succeededAt: first, error: nil, waiting: 0)
        try repository.recordArmSync(armID: "synthetic-arm", succeededAt: nil, error: "source-refresh", waiting: nil)
        #expect(try repository.armSyncHealth(armID: "synthetic-arm") == StoredArmSyncHealth(
            armID: "synthetic-arm", lastSuccessAt: first, lastError: "source-refresh", waiting: nil))

        let second = Date(timeIntervalSince1970: 200)
        try repository.recordArmSync(armID: "synthetic-arm", succeededAt: second, error: nil, waiting: 0)
        #expect(try repository.armSyncHealth(armID: "synthetic-arm")?.lastError == nil)
        #expect(try repository.armSyncHealth(armID: "synthetic-arm")?.lastSuccessAt == second)
    }

    @Test("A preview changes only the waiting count")
    func previewKeepsHistory() throws {
        let repository = try makeRepository()
        let at = Date(timeIntervalSince1970: 100)
        try repository.recordArmSync(armID: "synthetic-arm", succeededAt: at, error: nil, waiting: 0)
        try repository.recordArmWaiting(armID: "synthetic-arm", waiting: 4)
        #expect(try repository.armSyncHealth(armID: "synthetic-arm") == StoredArmSyncHealth(
            armID: "synthetic-arm", lastSuccessAt: at, lastError: nil, waiting: 4))
    }

    @Test("Removing an Arm removes its health")
    func removed() throws {
        let repository = try makeRepository()
        try repository.recordArmWaiting(armID: "synthetic-arm", waiting: 1)
        try repository.removeArm(id: "synthetic-arm")
        #expect(try repository.armSyncHealth(armID: "synthetic-arm") == nil)
    }
}
