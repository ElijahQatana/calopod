import CalopodDomain
import CalopodTestSupport
import Testing

@Test
func syncWindowRequiresAscendingDates() {
    #expect(throws: SyncWindowError.endMustFollowStart) {
        try SyncWindow(start: SyncFixtures.end, end: SyncFixtures.start)
    }
}

@Test
func syncRequestKeepsItsWindowAndMode() throws {
    let window = try SyncFixtures.oneDayWindow()
    let request = SyncRequest(mode: .dryRun, window: window)

    #expect(request.mode == .dryRun)
    #expect(request.window == window)
}
