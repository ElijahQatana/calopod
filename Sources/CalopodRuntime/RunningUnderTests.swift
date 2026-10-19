import Foundation

/// True inside a test run. The real state database and the app's real preferences are off limits
/// there, so code that would open them stops instead.
public enum RunningUnderTests {
    public static let isActive: Bool = {
        let info = ProcessInfo.processInfo
        if info.environment["XCTestConfigurationFilePath"] != nil
            || info.environment["XCTestBundlePath"] != nil
            || info.environment["SWIFT_TESTING_ENABLED"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
            || info.arguments.first.map { $0.hasSuffix("/xctest") || $0.contains("swiftpm-testing-helper") } == true
    }()

    /// Stops a test that reaches for the real state path. Tests set `CALOPOD_STATE_PATH` to a
    /// temporary file, or pass a location of their own.
    public static func refuseRealState() {
        precondition(!isActive,
                     "A test tried to open the real Calopod state database. Set CALOPOD_STATE_PATH to a temporary file or inject a repository.")
    }

    public static func refuseRealDefaults() {
        precondition(!isActive,
                     "A test tried to use the real app preferences. Inject a UserDefaults suite created for the test.")
    }
}
