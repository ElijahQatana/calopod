@testable import CalopodCommands
import XCTest

@testable import CalopodMac

final class SyncHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func status(_ state: String, message: String = "", age: Int? = 960) -> AgentControlStatus {
        AgentControlStatus(
            state: state, message: message, installed: true, enabled: state != "disabled",
            paused: state == "paused", running: false, intervalSeconds: 600,
            lastSuccessAgeSeconds: age, failureCategory: nil, failureAgeSeconds: nil,
            usesBundledService: false, sourceLoaded: false)
    }

    private func run(_ ok: Bool = true, secondsAgo: Int = 30) -> ManualRun {
        ManualRun(summary: ok ? "Everything is up to date. Nothing to change." : "The sync failed.", succeeded: ok,
                  finishedAt: now.addingTimeInterval(-Double(secondsAgo)), settledState: nil)
    }

    private func health(_ status: AgentControlStatus?, _ run: ManualRun? = nil) -> SyncHealth {
        SyncHealth.make(status: status, statusAt: now, run: run, now: now)
    }

    private func failing(secondsAgo: Int?) -> AgentControlStatus {
        AgentControlStatus(
            state: "failed", message: "Keychain is locked", installed: true, enabled: true, paused: false,
            running: false, intervalSeconds: 600, lastSuccessAgeSeconds: 960, failureCategory: "source-refresh",
            failureAgeSeconds: secondsAgo, usesBundledService: true, sourceLoaded: false)
    }

    func testManualSuccessWithAFailingAgentKeepsItsHeadlineButIsNotAllClear() {
        let result = health(failing(secondsAgo: 3600), run())
        XCTAssertEqual(result.headline, "Everything is up to date. Nothing to change.")
        XCTAssertEqual(result.detail, "Last synced just now · every 10 minutes")
        XCTAssertEqual(result.tone, .caution)
        XCTAssertNotEqual(result.symbol, "checkmark")
        XCTAssertEqual(result.note, "Keychain is locked")
    }

    func testAnAutomaticFailureAfterTheManualRunWinsTheHeadline() {
        let result = health(failing(secondsAgo: 5), run())
        XCTAssertEqual(result.tone, .bad)
        XCTAssertEqual(result.headline, "The last sync didn't finish")
        XCTAssertNil(result.note)
    }

    func testManualSuccessWithAStoppedAgentIsCautionWithANoteAndEnable() {
        let result = health(status("stopped"), run())
        XCTAssertEqual(result.tone, .caution)
        XCTAssertEqual(result.label, "Stopped")
        XCTAssertNotNil(result.note)
        XCTAssertTrue(result.offersEnable)
    }

    func testManualSuccessWithDisabledSyncOffersEnable() {
        let result = health(status("disabled"), run())
        XCTAssertEqual(result.headline, "Everything is up to date. Nothing to change.")
        XCTAssertEqual(result.tone, .caution)
        XCTAssertEqual(result.symbol, "power")
        XCTAssertEqual(result.label, "Sync is off")
        XCTAssertEqual(result.note, "Automatic sync is off, so changes will not sync by themselves.")
        XCTAssertTrue(result.offersEnable)
    }

    func testManualSuccessWithAHealthyAgentIsGreen() {
        let result = health(status("ok", age: 960), run())
        XCTAssertEqual(result.tone, .good)
        XCTAssertEqual(result.headline, "Everything is up to date. Nothing to change.")
        XCTAssertEqual(result.detail, "Last synced just now · every 10 minutes")
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

    func testPausedAndDisabledWithoutAManualRunKeepTheirOwnHeadline() {
        for (state, headline) in [("paused", "Scheduled syncs are paused"), ("disabled", "Automatic sync is off")] {
            let result = health(status(state))
            XCTAssertEqual(result.tone, .caution)
            XCTAssertEqual(result.headline, headline)
            XCTAssertEqual(result.offersEnable, state == "disabled")
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

final class AttentionChecksTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let health = HealthReport(
        status: "attention", message: "", checks: [
            .init(name: "automatic-run", state: "failed", reason: "source-refresh"),
            .init(name: "schedule", state: "pending", reason: "paused"),
        ], warnings: [])

    private func status(failedSecondsAgo: Int?) -> AgentControlStatus {
        AgentControlStatus(
            state: "failed", message: "", installed: true, enabled: true, paused: false, running: false,
            intervalSeconds: 600, lastSuccessAgeSeconds: nil, failureCategory: "source-refresh",
            failureAgeSeconds: failedSecondsAgo, usesBundledService: true, sourceLoaded: false)
    }

    private func run(_ ok: Bool, secondsAgo: Int) -> ManualRun {
        ManualRun(summary: "", succeeded: ok, finishedAt: now.addingTimeInterval(-Double(secondsAgo)), settledState: nil)
    }

    private func names(_ run: ManualRun?, failedSecondsAgo: Int = 3600) -> [String] {
        SyncHealth.attentionChecks(health, status: status(failedSecondsAgo: failedSecondsAgo), statusAt: now, run: run).map(\.name)
    }

    func testALaterSuccessfulRunClearsTheFailedRunRow() {
        XCTAssertEqual(names(run(true, secondsAgo: 30)), ["schedule"])
    }

    func testAnEarlierOrFailedRunKeepsIt() {
        XCTAssertEqual(names(run(true, secondsAgo: 7200)), ["automatic-run", "schedule"])
        XCTAssertEqual(names(run(false, secondsAgo: 30)), ["automatic-run", "schedule"])
        XCTAssertEqual(names(nil), ["automatic-run", "schedule"])
    }
}
