import CalopodDomain
import CalopodSync
import CalopodTestSupport
import Testing

@Test
func placeholderEngineUsesTheSharedRequestContract() async throws {
    let request = SyncRequest(mode: .dryRun, window: try SyncFixtures.oneDayWindow())

    let summary = try await SyncEngine().run(request)

    #expect(summary.mode == request.mode)
    #expect(summary.window == request.window)
    #expect(summary.plannedOperationCount == 0)
    #expect(summary.appliedOperationCount == 0)
}
