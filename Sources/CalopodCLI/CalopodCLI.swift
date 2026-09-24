import CalopodDomain
import CalopodSync
import Foundation

@main
struct CalopodCLI {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments == ["--help"] || arguments == ["-h"] {
            printUsage()
            return
        }

        guard arguments.first == "sync" else {
            fputs("Expected the sync command.\n", stderr)
            printUsage()
            exit(64)
        }

        let options = Set(arguments.dropFirst())
        guard options.isSubset(of: ["--dry-run"]) else {
            fputs("Unknown sync option.\n", stderr)
            printUsage()
            exit(64)
        }

        let mode: SyncMode = options.contains("--dry-run") ? .dryRun : .apply

        do {
            let summary = try await SyncEngine().run(SyncRequest(mode: mode))
            print("mode=\(summary.mode.rawValue)")
            print("planned=\(summary.plannedOperationCount)")
            print("applied=\(summary.appliedOperationCount)")
        } catch {
            fputs("Sync failed.\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print("Usage: calopod sync [--dry-run]")
    }
}
