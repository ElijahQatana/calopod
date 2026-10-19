import SwiftUI

@main
struct CalopodApp: App {
    @State private var store = SnapshotStore(reader: Self.reader(), cache: Self.cache())

    var body: some Scene {
        WindowGroup { RootView(store: store) }
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

    private static func cache() -> SnapshotCache {
        ProcessInfo.processInfo.arguments.contains("-fixture")
            ? SnapshotCache(url: FileManager.default.temporaryDirectory.appendingPathComponent("fixture-snapshot.json"))
            : .standard
    }
}
