#if os(macOS)
import Foundation

public enum EventKitHostLimits {
    /// Ordinary reads and writes.
    public static let standard: TimeInterval = 90
    /// The interactive Calendar permission request waits on a person.
    public static let permissionRequest: TimeInterval = 300
}

/// Runs a launcher process and waits for it at most `limit` seconds. On expiry
/// the process is stopped and `false` is returned. A launch error is thrown.
public func runWithinLimit(_ process: Process, limit: TimeInterval) throws -> Bool {
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    if exited.wait(timeout: .now() + limit) == .success { return true }
    process.terminate()
    if exited.wait(timeout: .now() + 2) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        exited.wait()
    }
    return false
}
#endif
