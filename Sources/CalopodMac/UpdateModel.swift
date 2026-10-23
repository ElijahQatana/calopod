import CalopodCommands
import CalopodProviders
import Foundation
import Observation
import SwiftUI

/// Checking for a newer release. It only runs when asked, or once a day if the user turned that on.
@MainActor
@Observable
final class UpdateModel {
    static let dailyKey = "calopod.checkUpdatesDaily"
    static let lastCheckKey = "calopod.lastUpdateCheck"
    static let dismissedKey = "calopod.dismissedUpdate"

    /// The app's own version, from the bundle.
    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? CalopodRoot.version
    }

    let current: String
    private(set) var result: UpdateResult?
    private(set) var isChecking = false
    private(set) var checksDaily: Bool
    private(set) var dismissed: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let lookup: @Sendable (String) async -> UpdateResult
    @ObservationIgnored private let now: () -> Date

    init(
        defaults: UserDefaults = AppDefaults.standard, current: String = UpdateModel.bundleVersion,
        lookup: @escaping @Sendable (String) async -> UpdateResult = { await UpdateCheck().check(current: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.current = current
        self.lookup = lookup
        self.now = now
        checksDaily = defaults.bool(forKey: Self.dailyKey)
        dismissed = defaults.string(forKey: Self.dismissedKey)
    }

    /// The release to tell the user about, unless they closed the note for that version.
    var offered: (version: String, page: URL)? {
        guard case let .available(version, page) = result, version != dismissed else { return nil }
        return (version, page)
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defaults.set(now(), forKey: Self.lastCheckKey)
        result = await lookup(current)
        isChecking = false
    }

    /// For launch and for coming back to the app. Does nothing unless the daily check is on and a day has passed.
    func checkIfDue() async {
        guard checksDaily else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date, now().timeIntervalSince(last) < 86_400 { return }
        await check()
    }

    func setChecksDaily(_ on: Bool) {
        checksDaily = on
        defaults.set(on, forKey: Self.dailyKey)
    }

    func dismiss() {
        guard case let .available(version, _) = result else { return }
        dismissed = version
        defaults.set(version, forKey: Self.dismissedKey)
    }
}

private struct UpdateModelKey: EnvironmentKey {
    static let defaultValue: UpdateModel? = nil
}

extension EnvironmentValues {
    var updates: UpdateModel? {
        get { self[UpdateModelKey.self] }
        set { self[UpdateModelKey.self] = newValue }
    }
}
