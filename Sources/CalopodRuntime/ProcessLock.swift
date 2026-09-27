import Darwin
import Foundation

public final class ProcessLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

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

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
