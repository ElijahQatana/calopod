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
    let task = BackgroundWork {
        try writer.write { db in
            try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["pending", Date(), Date()])
            entered.signal()
            release.wait()
        }
    }
    defer { release.signal() }
    try #require(waitForWriter(entered), "The writer did not start: \(String(describing: task.earlyError))")
    let reader = try CalopodDatabase(path: path, readonly: true)
    #expect(try reader.read { try String.fetchAll($0, sql: "SELECT id FROM configurations") }.isEmpty)
    #expect(throws: (any Error).self) {
        try reader.write { try $0.execute(sql: "DELETE FROM configurations") }
    }
    release.signal()
    try await task.value()
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
    let writer = BackgroundWork {
        try first.write { db in
            try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["first", Date(), Date()])
            entered.signal()
            release.wait()
        }
    }
    defer { release.signal() }
    try #require(waitForWriter(entered), "The writer did not start: \(String(describing: writer.earlyError))")
    let start = Date()
    #expect(throws: (any Error).self) {
        try second.write { db in
            try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["second", Date(), Date()])
        }
    }
    #expect(Date().timeIntervalSince(start) >= 1.8)
    #expect(Date().timeIntervalSince(start) < 10)
    release.signal()
    try await writer.value()
    try second.write { db in
        try db.execute(sql: "INSERT INTO configurations VALUES (?, ?, ?)", arguments: ["second", Date(), Date()])
    }
    #expect(try first.read { try String.fetchAll($0, sql: "SELECT id FROM configurations ORDER BY id") } == ["first", "second"])
}

private func waitForWriter(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 30) == .success
}

/// Blocking work on a thread of its own. Detached tasks and dispatch blocks both wait for a free slot, and
/// when hundreds of tests start at once on a runner with few cores the writer can sit unstarted past the wait.
private final class BackgroundWork: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private var result: Result<Void, any Error>?

    init(_ work: @escaping @Sendable () throws -> Void) {
        Thread.detachNewThread { [self] in
            result = Result { try work() }
            finished.signal()
        }
    }

    /// The error the work already ended with, for a failure message.
    var earlyError: (any Error)? {
        if case .failure(let error) = result { error } else { nil }
    }

    func value() async throws {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                self.finished.wait()
                continuation.resume()
            }
        }
        try result?.get()
    }
}
