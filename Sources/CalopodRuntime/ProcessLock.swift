import Darwin
import Foundation

/// An exclusive OS lock so a manual sync and the agent never write at once. The loser fails fast
/// with `.busy`.
public final class ProcessLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Opens and locks the file at `url` without blocking (`LOCK_NB`), so contention is an
    /// immediate `.busy`. Shared locks let local readers coexist while excluding restore.
    /// `FD_CLOEXEC` keeps the descriptor out of child processes, and the file is owner-only.
    public static func acquire(at url: URL, shared: Bool = false) throws -> ProcessLock {
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CalopodRuntimeError.invalidStatePath
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        guard flock(descriptor, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 else {
            close(descriptor)
            throw CalopodRuntimeError.busy
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw CalopodRuntimeError.invalidStatePath
        }
        return ProcessLock(descriptor: descriptor)
    }

    // `flock` ends with the file descriptor, so even a crashed holder can't leave sync stuck on
    // busy.
    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
