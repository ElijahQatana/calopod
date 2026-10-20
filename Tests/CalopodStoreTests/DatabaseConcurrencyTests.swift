@testable import CalopodStore
import Foundation
import GRDB
import Testing

@Test
func walReadersSeeCommittedStateDuringAWrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let writer = try CalopodDatabase(path: path)
    #expect(try writer.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "wal")
    #expect(try writer.read { try Int.fetchOne($0, sql: "PRAGMA busy_timeout") } == 2000)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let task = startOnThread {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["pending", Date(), Date()])
            entered.signal()
            release.wait()
        }
    }
    defer { release.signal() }
    try #require(waitForWriter(entered))
    let reader = try CalopodDatabase(path: path, readonly: true)
    #expect(try reader.read { try String.fetchAll($0, sql: "SELECT id FROM configurations") }.isEmpty)
    #expect(throws: (any Error).self) {
        try reader.write { try $0.execute(sql: "DELETE FROM configurations") }
    }
    release.signal()
    try await task()
    #expect(try reader.read { try String.fetchAll($0, sql: "SELECT id FROM configurations") } == ["pending"])
}

@Test
func readOnlyOpenNeverCreatesOrMigratesState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    #expect(throws: (any Error).self) { try CalopodDatabase(path: path, readonly: true) }
    #expect(!FileManager.default.fileExists(atPath: path))
    let queue = try DatabaseQueue(path: path)
    try queue.write { db in
        try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1_foundation')")
    }
    #expect(throws: CalopodDatabaseError.migrationRequired) { try CalopodDatabase(path: path, readonly: true) }
    #expect(try queue.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") } == ["v1_foundation"])
    #expect(try queue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") } == "delete")
}

@Test
func busyTimeoutWaitsForAWriterAndRemainsBounded() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("state.sqlite").path
    let first = try CalopodDatabase(path: path)
    let second = try CalopodDatabase(path: path)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let writer = startOnThread {
        try first.write { db in
            try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["first", Date(), Date()])
            entered.signal()
            release.wait()
        }
    }
    defer { release.signal() }
    try #require(waitForWriter(entered))
    let start = Date()
    #expect(throws: (any Error).self) {
        try second.write { db in
            try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["second", Date(), Date()])
        }
    }
    #expect(Date().timeIntervalSince(start) >= 1.8)
    #expect(Date().timeIntervalSince(start) < 10)
    release.signal()
    try await writer()
    try second.write { db in
        try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["second", Date(), Date()])
    }
    #expect(try first.read { try String.fetchAll($0, sql: "SELECT id FROM configurations ORDER BY id") } == ["first", "second"])
}

private func waitForWriter(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 5) == .success
}

/// Runs blocking work on its own thread. A detached task that waits on a semaphore holds a thread from the
/// small task pool, and on a runner with few cores the other tests can leave it no thread to start on.
private func startOnThread(_ work: @escaping @Sendable () throws -> Void) -> @Sendable () async throws -> Void {
    final class Outcome: @unchecked Sendable { var result: Result<Void, any Error>? }
    let outcome = Outcome()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        outcome.result = Result { try work() }
        finished.signal()
    }
    return {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                finished.wait()
                continuation.resume()
            }
        }
        try outcome.result?.get()
    }
}
