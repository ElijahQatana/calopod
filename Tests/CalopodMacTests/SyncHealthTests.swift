@testable import CalopodCommands
import XCTest

@testable import CalopodMac

final class SyncHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func status(_ state: String, message: String = "", age: Int? = 960) -> AgentControlStatus {
        AgentControlStatus(
            state: state, message: message, installed: true, enabled: state != "disabled",
            paused: state == "paused", running: false, intervalSeconds: 600,
            lastSuccessAgeSeconds: age, failureCategory: nil)
    }

    private func run(_ ok: Bool = true, secondsAgo: Int = 30) -> ManualRun {
        ManualRun(summary: ok ? "Everything is up to date. Nothing to change." : "The sync failed.", succeeded: ok,
                  finishedAt: now.addingTimeInterval(-Double(secondsAgo)), settledState: nil)
    }

    private func health(_ status: AgentControlStatus?, _ run: ManualRun? = nil) -> SyncHealth {
        SyncHealth.make(status: status, statusAt: now, run: run, now: now)
    }

    func testRecentManualSuccessOverridesFailedAgentConsistently() {
        let result = health(status("failed", message: "Keychain is locked"), run())
        XCTAssertEqual(result.tone, .good)
        XCTAssertEqual(result.symbol, "checkmark")
        XCTAssertEqual(result.headline, "Everything is up to date. Nothing to change.")
        XCTAssertEqual(result.detail, "Last synced just now · every 10 minutes")
        XCTAssertEqual(result.label, "Syncing")
    }

    func testMissingCalendarAccessBeatsASuccessfulSync() {
        for (access, tone) in [(CalendarAccessState.canAsk, SyncHealth.Tone.caution), (.blocked, .bad)] {
            let result = SyncHealth.make(status: status("ok"), statusAt: now, run: run(), access: access, now: now)
            XCTAssertEqual(result.tone, tone)
            XCTAssertEqual(result.label, "Needs Calendar access")
        }
        let granted = SyncHealth.make(status: status("ok"), statusAt: now, run: nil, access: .granted, now: now)
        XCTAssertEqual(granted.tone, .good)
    }

    func testAgentSuccessNewerThanManualRunWins() {
        let result = health(status("ok", age: 5), run(secondsAgo: 300))
        XCTAssertEqual(result.headline, "Everything is in sync")
        XCTAssertEqual(result.lastSyncedAge, 5)
    }

    func testPausedAndDisabledKeepTheirOwnMessageEvenWithAManualRun() {
        for (state, headline) in [("paused", "Scheduled syncs are paused"), ("disabled", "Automatic sync is off")] {
            let result = health(status(state), run())
            XCTAssertEqual(result.tone, .caution)
            XCTAssertEqual(result.headline, headline)
        }
    }

    func testFailedAgentWithoutManualRunGivesThePlainReason() {
        let result = health(status("failed", message: "Keychain is locked"))
        XCTAssertEqual(result.tone, .bad)
        XCTAssertEqual(result.symbol, "exclamationmark")
        XCTAssertEqual(result.headline, "The last sync didn't finish")
        XCTAssertEqual(result.detail, "Keychain is locked")
    }

    func testFailedManualRunIsShownAsBad() {
        let result = health(status("ok"), run(false))
        XCTAssertEqual(result.tone, .bad)
        XCTAssertEqual(result.headline, "The sync failed.")
    }

    func testRunIsKeptOnTheFirstRefreshThenDroppedWhenTheStateChanges() {
        let failed = status("failed")
        var kept = SyncHealth.settled(run(), status: failed, statusAt: now)
        XCTAssertEqual(kept?.settledState, "failed")
        kept = SyncHealth.settled(kept, status: failed, statusAt: now)
        XCTAssertNotNil(kept)
        XCTAssertNil(SyncHealth.settled(kept, status: status("ok", age: 2), statusAt: now))
    }

    func testRunIsDroppedOnceTheAgentReportsANewerResult() {
        var kept = SyncHealth.settled(run(secondsAgo: 300), status: status("failed", age: 960), statusAt: now)
        kept = SyncHealth.settled(kept, status: status("failed", age: 10), statusAt: now)
        XCTAssertNil(kept)
    }
}
