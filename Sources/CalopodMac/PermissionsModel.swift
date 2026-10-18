import AppKit
import CalopodCommands
import Foundation
import Observation
import ServiceManagement

/// The three permissions listed in Settings. Calendar access comes from the shared
/// `CalendarAccessModel`, so Overview and this list always agree.
@MainActor
@Observable
final class PermissionsModel {
    let access: CalendarAccessModel
    private(set) var loginItems: BackgroundServiceState = .unavailable
    private(set) var keychain: KeychainCheckOutcome?
    private(set) var checkingKeychain = false

    @ObservationIgnored private let readLoginItems: @Sendable () -> BackgroundServiceState
    @ObservationIgnored private let readKeychain: @Sendable (Bool) -> KeychainCheckOutcome
    @ObservationIgnored private let open: (URL) -> Void
    @ObservationIgnored private let openLoginItems: () -> Void

    init(
        access: CalendarAccessModel,
        readLoginItems: @escaping @Sendable () -> BackgroundServiceState = { ServiceRegistration().state() },
        readKeychain: @escaping @Sendable (Bool) -> KeychainCheckOutcome = { KeychainAccessCheck.live.run(interactive: $0) },
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        openLoginItems: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.access = access
        self.readLoginItems = readLoginItems
        self.readKeychain = readKeychain
        self.open = open
        self.openLoginItems = openLoginItems
    }

    var calendar: PermissionReading {
        Permissions.calendar(status: access.status, hostFailure: access.hostFailure)
    }
    var backgroundService: PermissionReading { Permissions.backgroundService(loginItems) }
    var savedSignIns: PermissionReading { Permissions.keychain(keychain) }

    /// Re-reads all three without ever raising a macOS prompt, when Settings opens and when the
    /// app comes to the front.
    func refresh() async {
        await access.check()
        let read = readLoginItems
        loginItems = await Task.detached { read() }.value
        guard !checkingKeychain else { return }
        let quiet = readKeychain
        keychain = await Task.detached { quiet(false) }.value
    }

    /// The Check button. macOS may show its keychain prompt now, because the person asked.
    func checkKeychain() async {
        guard !checkingKeychain else { return }
        checkingKeychain = true
        defer { checkingKeychain = false }
        let read = readKeychain
        keychain = await Task.detached { read(true) }.value
    }

    func openCalendarPrivacy() { access.openPrivacySettings() }
    func openLoginItemsSettings() { openLoginItems() }
}
