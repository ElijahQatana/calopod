import Darwin
import Foundation

/// An exclusive, OS-enforced lock backing the single rule that manual CLI
/// sync and the background agent both depend on: two writers must never run
/// at once. Whichever process (a `calopod sync` invocation or the agent's own
/// run loop) acquires the lock file first proceeds; every other one fails
/// fast with `.busy` rather than blocking or racing on the same state.
public final class ProcessLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Opens (creating if needed) and exclusively, non-blockingly locks the
    /// file at `url`. `LOCK_NB` is what turns a would-be wait into an
    /// immediate `.busy` failure — callers report a safe "sync already
    /// running" rather than queuing behind another writer. `FD_CLOEXEC`
    /// keeps the descriptor from leaking into any child process spawned
    /// while the lock is held, and the permissions are pinned to
    /// owner-only, matching every other private state file.
    public static func acquire(at url: URL) throws -> ProcessLock {
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw CalopodRuntimeError.invalidStatePath
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
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

    // `flock` is tied to the file descriptor's lifetime: closing it (whether
    // this object is deallocated normally or the process is killed) always
    // releases the lock, so a crashed holder can never leave sync
    // permanently stuck as "busy".
    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
