import CalopodCommands
import CalopodEventKit
import XCTest

@testable import CalopodMac

@MainActor
final class PermissionsModelTests: XCTestCase {
    private final class Fakes: @unchecked Sendable {
        let lock = NSLock()
        var calendar = EventKitAccessStatus.notDetermined
        var loginItems = BackgroundServiceState.requiresApproval
        var keychain = KeychainCheckOutcome.needsPrompt
        var keychainCalls: [Bool] = []
        var opened: [URL] = []
        var openedLoginItems = 0

        @MainActor func model() -> PermissionsModel {
            let access = CalendarAccessModel(
                readStatus: { [self] in lock.withLock { calendar } },
                requestAccess: { [self] in lock.withLock { calendar = .fullAccess; return calendar } },
                open: { [self] in opened.append($0) })
            return PermissionsModel(
                access: access,
                readLoginItems: { [self] in lock.withLock { loginItems } },
                readKeychain: { [self] interactive in
                    lock.withLock { keychainCalls.append(interactive); return keychain }
                },
                open: { _ in },
                openLoginItems: { [self] in openedLoginItems += 1 })
        }
    }

    func testRefreshReadsAllThreeAndNeverAsksTheKeychain() async {
        let fakes = Fakes()
        let model = fakes.model()
        await model.refresh()
        XCTAssertEqual(model.calendar.level, .notAsked)
        XCTAssertEqual(model.backgroundService.reason, "needs-approval")
        XCTAssertEqual(model.savedSignIns.reason, "needs-prompt")
        XCTAssertEqual(fakes.keychainCalls, [false])
    }

    func testCheckingTheKeychainMayAskAndAgainClearsTheNotice() async {
        let fakes = Fakes()
        let model = fakes.model()
        await model.refresh()
        fakes.keychain = .allowed(accounts: 2)
        await model.checkKeychain()
        XCTAssertEqual(fakes.keychainCalls, [false, true])
        XCTAssertEqual(model.savedSignIns.level, .allowed)
    }

    func testComingToTheFrontPicksUpChangesMadeInSystemSettings() async {
        let fakes = Fakes()
        let model = fakes.model()
        await model.refresh()
        fakes.calendar = .fullAccess
        fakes.loginItems = .enabled
        fakes.keychain = .noAccounts
        await model.refresh()
        XCTAssertEqual([model.calendar.level, model.backgroundService.level], [.allowed, .allowed])
        XCTAssertEqual(model.savedSignIns.reason, "no-accounts")
    }

    func testAllowAsksThroughTheSameCalendarModelOverviewUses() async {
        let fakes = Fakes()
        let model = fakes.model()
        await model.refresh()
        await model.access.allow()
        XCTAssertEqual(model.calendar.level, .allowed)
        XCTAssertEqual(model.access.state(lastSyncFailure: nil), .granted)
    }

    func testButtonsOpenTheRightSettingsPages() async {
        let fakes = Fakes()
        let model = fakes.model()
        model.openCalendarPrivacy()
        model.openLoginItemsSettings()
        XCTAssertEqual(fakes.opened.map(\.absoluteString), [Permissions.calendarPrivacyURL])
        XCTAssertEqual(fakes.openedLoginItems, 1)
    }

    func testAnUnreachableHelperExplainsWhy() async {
        struct Down: Error {}
        let access = CalendarAccessModel(readStatus: { throw Down() }, requestAccess: { throw Down() }, open: { _ in })
        let model = PermissionsModel(access: access, readLoginItems: { .enabled }, readKeychain: { _ in .noAccounts })
        await model.refresh()
        XCTAssertEqual(model.calendar.reason, "unreachable")
        XCTAssertTrue(model.calendar.detail.contains("helper"))
    }
}
