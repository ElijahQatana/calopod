import CalopodRuntime
import Foundation

/// The app's real preferences. A test run must hand in its own suite, so asking for these there stops.
enum AppDefaults {
    static var standard: UserDefaults {
        RunningUnderTests.refuseRealDefaults()
        return .standard
    }

    /// For objects built once per process. Under tests they get a suite of their own.
    static var forSingleton: UserDefaults {
        guard RunningUnderTests.isActive else { return .standard }
        let suite = UserDefaults(suiteName: "calopod.tests.singleton")!
        suite.removePersistentDomain(forName: "calopod.tests.singleton")
        return suite
    }
}
