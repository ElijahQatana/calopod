import AppKit
import CalopodCommands
import Foundation
import Observation
import ServiceManagement

/// The permissions listed in Settings. Calendar access comes from the shared
/// `CalendarAccessModel`, so Overview and this list always agree.
@MainActor
@Observable
final class PermissionsModel {
    let access: CalendarAccessModel
    private(set) var loginItems: BackgroundServiceState = .unavailable
    private(set) var keychain: KeychainCheckOutcome?
    private(set) var checkingKeychain = false
    private(set) var notifications: NotificationPermissionState?
    private(set) var askingNotifications = false

    @ObservationIgnored private let readLoginItems: @Sendable () -> BackgroundServiceState
    @ObservationIgnored private let readKeychain: @Sendable (Bool) -> KeychainCheckOutcome
    @ObservationIgnored private let readNotifications: @Sendable () async -> NotificationPermissionState
    @ObservationIgnored private let requestNotifications: @Sendable () async -> Bool
    @ObservationIgnored private let open: (URL) -> Void
    @ObservationIgnored private let openLoginItems: () -> Void

    init(
        access: CalendarAccessModel,
        readLoginItems: @escaping @Sendable () -> BackgroundServiceState = { ServiceRegistration().state() },
        readKeychain: @escaping @Sendable (Bool) -> KeychainCheckOutcome = { KeychainAccessCheck.live.run(interactive: $0) },
        readNotifications: @escaping @Sendable () async -> NotificationPermissionState = { await AppNotifications.permission() },
        requestNotifications: @escaping @Sendable () async -> Bool = { await AppNotifications.requestPermission() },
        open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        openLoginItems: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.access = access
        self.readLoginItems = readLoginItems
        self.readKeychain = readKeychain
        self.readNotifications = readNotifications
        self.requestNotifications = requestNotifications
        self.open = open
        self.openLoginItems = openLoginItems
    }

    var calendar: PermissionReading {
        Permissions.calendar(status: access.status, hostFailure: access.hostFailure, helper: access.helperPath)
    }
    var backgroundService: PermissionReading { Permissions.backgroundService(loginItems) }
    var savedSignIns: PermissionReading { Permissions.keychain(keychain) }
    var notificationsReading: PermissionReading { Permissions.notifications(notifications) }

    /// Re-reads all of them without ever raising a macOS prompt, when Settings opens and when the
    /// app comes to the front.
    func refresh() async {
        await access.check()
        await refreshNotifications()
        let read = readLoginItems
        loginItems = await Task.detached { read() }.value
        guard !checkingKeychain else { return }
        let quiet = readKeychain
        keychain = await Task.detached { quiet(false) }.value
    }

    /// macOS answers this one without asking, so it is also read when the app comes forward.
    func refreshNotifications() async {
        notifications = await readNotifications()
    }

    /// The Allow button for Notifications. macOS asks once; after a no it only opens System Settings.
    func allowNotifications() async {
        guard !askingNotifications else { return }
        askingNotifications = true
        defer { askingNotifications = false }
        _ = await requestNotifications()
        await refreshNotifications()
    }

    func openNotificationsSettings() {
        if let url = URL(string: Permissions.notificationsURL) { open(url) }
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
