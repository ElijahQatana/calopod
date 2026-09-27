import CalopodStore
import Foundation
import Testing

@Test
func agentControlDefaultsToActiveAndPersistsPauseChanges() throws {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())

    #expect(try repository.agentControl() == StoredAgentControl(
        isPaused: false,
        updatedAt: nil
    ))

    let pausedAt = Date(timeIntervalSince1970: 100)
    try repository.setAgentPaused(true, now: pausedAt)
    #expect(try repository.agentControl() == StoredAgentControl(
        isPaused: true,
        updatedAt: pausedAt
    ))

    let resumedAt = Date(timeIntervalSince1970: 200)
    try repository.setAgentPaused(false, now: resumedAt)
    #expect(try repository.agentControl() == StoredAgentControl(
        isPaused: false,
        updatedAt: resumedAt
    ))
}
