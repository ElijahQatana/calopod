import SwiftUI

@main
struct CalopodApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store = SnapshotStore(reader: Self.reader(), cache: Self.cache())
    @State private var reminders = Reminders(center: Self.isFixture ? FixtureNotificationCenter() : UserNotificationCenter())

    var body: some Scene {
        WindowGroup { RootView(store: store, reminders: reminders) }
    }

    /// `-fixture <scenario>` swaps in synthetic data, for the simulator and screenshots.
    private static func reader() -> SnapshotReader {
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "-fixture") {
            let name = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
            return FixtureReader(scenario: FixtureReader.Scenario(rawValue: name) ?? .fresh)
        }
        return CloudKitReader()
    }

    private static var isFixture: Bool { ProcessInfo.processInfo.arguments.contains("-fixture") }

    private static func cache() -> SnapshotCache {
        isFixture
            ? SnapshotCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("fixture-snapshot.json"))
            : .standard
    }
}
