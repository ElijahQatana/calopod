import CalopodDomain
import CalopodSync
import Foundation

@main
struct CalopodAgent {
    static func main() async {
        do {
            let summary = try await SyncEngine().run(SyncRequest(mode: .apply))
            print("mode=\(summary.mode.rawValue)")
            print("planned=\(summary.plannedOperationCount)")
            print("applied=\(summary.appliedOperationCount)")
        } catch {
            fputs("Sync failed.\n", stderr)
            exit(1)
        }
    }
}
