import CalopodStore
import Foundation
import Testing

@testable import CalopodCommands

private func repository(_ outcomes: [(status: String, mode: String)]) throws -> LocalStateRepository {
    let repository = LocalStateRepository(database: try CalopodDatabase.inMemory())
    for (index, outcome) in outcomes.enumerated() {
        let start = Date(timeIntervalSince1970: Double(index) * 100)
        let id = try repository.beginSyncRun(mode: outcome.mode, trigger: "automatic", id: "run\(index)", now: start)
        if outcome.status != "running" {
            try repository.finishSyncRun(id: id, status: outcome.status, now: start.addingTimeInterval(5))
        }
    }
    return repository
}

@Test
func runMarksAreOldestFirstAndFailuresCount() throws {
    let outcomes = [("succeeded", "apply"), ("failed", "apply"), ("interrupted", "apply"), ("succeeded", "apply")]
    let repository = try repository(outcomes.map { (status: $0.0, mode: $0.1) })
    #expect(try repository.recentRunMarks() == [.good, .failed, .failed, .good])
}

@Test
func runMarksKeepOnlyTheLastTwelveApplyRuns() throws {
    var outcomes = [(status: "failed", mode: "apply")]
    outcomes += Array(repeating: (status: "succeeded", mode: "apply"), count: 12)
    outcomes += [(status: "failed", mode: "dry-run"), (status: "running", mode: "apply")]
    let marks = try repository(outcomes).recentRunMarks()
    #expect(marks == Array(repeating: .good, count: 12))
}

@Test
func runMarksAreEmptyWithoutHistory() throws {
    #expect(try repository([]).recentRunMarks().isEmpty)
}

@Test
func failureReasonsUsePlainWording() {
    #expect(syncFailureReason(category: "eventkit-host-timeout") == "Calendar took too long to answer. Try again.")
    #expect(syncFailureReason(category: "authorization").contains("reconnected"))
    for category in ["unknown", nil, "local-state"] {
        #expect(syncFailureReason(category: category).hasPrefix("The sync failed."))
    }
    for category in ["eventkit-host", "authorization", "busy", "client-id", "interrupted"] {
        let text = syncFailureReason(category: category)
        #expect(!text.contains("calopod ") && !text.contains("CALOPOD_"))
    }
}
