@testable import CalopodCommands
import XCTest

@testable import CalopodMac

final class PreviewSyncRuleTests: XCTestCase {
    private func status(_ state: String, installed: Bool = true) -> AgentControlStatus {
        AgentControlStatus(
            state: state, message: "", installed: installed, enabled: state != "disabled",
            paused: state == "paused", running: false, intervalSeconds: 600,
            lastSuccessAgeSeconds: 60, failureCategory: nil, failureAgeSeconds: nil,
            usesBundledService: true, sourceLoaded: false)
    }

    private func rule(
        _ status: AgentControlStatus?, access: CalendarAccessState = .granted, busy: Bool = false, pending: Bool = false
    ) -> String? {
        PreviewSyncRule.make(status: status, access: access, busy: busy, hasPendingPreview: pending).disabledReason
    }

    func testDisabledStatesAlwaysGiveAReason() {
        XCTAssertEqual(rule(status("ok"), busy: true), "A sync is running")
        XCTAssertEqual(rule(status("ok"), access: .canAsk), "Needs Calendar access")
        XCTAssertEqual(rule(status("ok"), access: .blocked), "Needs Calendar access")
        XCTAssertEqual(rule(status("ok"), pending: true), "Review the open preview first")
        XCTAssertEqual(rule(status("not-installed", installed: false)), "Set up background sync first")
        XCTAssertEqual(rule(nil), "Set up background sync first")
    }

    func testStaysEnabledWhenAutomaticSyncIsOffOrFailing() {
        for state in ["ok", "disabled", "paused", "stopped", "failed"] {
            XCTAssertNil(rule(status(state)), state)
        }
        XCTAssertNil(rule(status("ok"), access: .unchecked))
    }

    func testOverviewAsksTheServiceRule() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/CalopodMac")
        for file in ["OverviewScreen.swift"] {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("model.previewRule"), file)
            XCTAssertFalse(text.contains("previewDisabled"), file)
        }
        let service = try String(contentsOf: dir.appendingPathComponent("ServiceModel.swift"), encoding: .utf8)
        XCTAssertTrue(service.contains("PreviewSyncRule.make("))
    }
}
