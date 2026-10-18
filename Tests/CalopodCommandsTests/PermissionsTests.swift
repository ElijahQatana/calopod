@testable import CalopodCommands
import CalopodEventKit
import CalopodProviders
import CalopodStore
import Foundation
import Testing

private let token = OAuthTokens(accessToken: "a", refreshToken: "r", tokenType: "Bearer", scope: nil, expiresAt: Date())

@Test
func calendarStatusesGetTheirOwnWords() {
    let cases: [(EventKitAccessStatus?, PermissionReading.Level, String)] = [
        (.fullAccess, .allowed, "allowed"),
        (.notDetermined, .notAsked, "not-asked"),
        (.denied, .blocked, "denied"),
        (.restricted, .blocked, "restricted"),
        (.writeOnly, .blocked, "write-only"),
        (nil, .unknown, "unreachable"),
    ]
    for (status, level, reason) in cases {
        let reading = Permissions.calendar(status: status)
        #expect(reading.level == level && reading.reason == reason)
    }
    #expect(Permissions.calendar(status: .denied).detail.contains("Privacy & Security, Calendars"))
}

@Test
func loginItemStatesMatchTheBackgroundSyncScreen() {
    let cases: [(BackgroundServiceState, PermissionReading.Level)] = [
        (.enabled, .allowed), (.requiresApproval, .blocked), (.notRegistered, .notAsked),
        (.notFound, .blocked), (.unavailable, .unknown),
    ]
    for (state, level) in cases { #expect(Permissions.backgroundService(state).level == level) }
    #expect(Permissions.backgroundService(.notFound).detail == Permissions.noRecordOfThisCopy)
    #expect(Permissions.backgroundService(.requiresApproval).detail.contains("Login Items"))
}

private func check(
    _ accounts: [KeychainAccessCheck.Account], quietFails: Bool = false,
    read: @escaping @Sendable (KeychainAccessCheck.Account) throws -> OAuthTokens? = { _ in token }
) -> KeychainAccessCheck {
    KeychainAccessCheck(accounts: { accounts }, read: { account, interactive in
        if quietFails, !interactive { throw SecretStoreError.keychainStatus(-25308) }
        return try read(account)
    })
}

@Test
func keychainCheckReportsEachOutcome() {
    let accounts: [KeychainAccessCheck.Account] = [("google", "g1"), ("microsoft", "m1")]
    #expect(check([]).run(interactive: true) == .noAccounts)
    #expect(check(accounts).run(interactive: false) == .allowed(accounts: 2))
    #expect(check(accounts, read: { $0.provider == "google" ? token : nil }).run(interactive: true)
        == .cannotRead(reason: "no saved sign-in was found for one of your accounts."))
    #expect(check(accounts, read: { _ in throw SecretStoreError.keychainStatus(-25300) }).run(interactive: true)
        != .allowed(accounts: 2))
    #expect(check(accounts, read: { _ in throw SecretStoreError.unexpectedValue }).run(interactive: true)
        == .cannotRead(reason: "a saved sign-in is damaged."))
}

@Test
func aQuietCheckNeverAsksButTheCheckButtonCan() {
    let accounts: [KeychainAccessCheck.Account] = [("google", "g1")]
    let blocked = check(accounts, quietFails: true)
    #expect(blocked.run(interactive: false) == .needsPrompt)
    #expect(blocked.run(interactive: true) == .allowed(accounts: 1))
    let reading = Permissions.keychain(.needsPrompt)
    #expect(reading.detail.contains("Always Allow") && reading.state == "macOS will ask")
}

@Test
func doctorAddsThePermissionsWithTheSameWords() {
    let base = DoctorReport(status: "ok", message: "Automatic sync checks passed.", items: [], warnings: [])
    let readings = [
        Permissions.calendar(status: .denied),
        Permissions.backgroundService(.unavailable),
        Permissions.keychain(.allowed(accounts: 1)),
    ]
    let report = withPermissions(base, readings)
    #expect(report.items.map(\.id) == ["permission-calendar", "permission-login-items", "permission-keychain"])
    #expect(report.items.map(\.kind) == ["attention", "skipped", "ok"])
    #expect(report.status == "attention")
    #expect(report.warnings == ["Calendar access: \(readings[0].detail)"])
    #expect(withPermissions(base, [readings[2]]).status == "ok")
}
