import Foundation

/// Creates owner-only files and directories with the mode set by the
/// creating call, so there is no window where they exist with looser
/// permissions. The requested mode is only ever narrowed by the umask.
public enum PrivateFiles {
    /// Creates `url` as a directory with mode 0700. Missing parents are
    /// created normally. Returns false if the directory already existed.
    @discardableResult
    public static func createDirectory(at url: URL) throws -> Bool {
        if mkdir(url.path, 0o700) == 0 { return true }
        if errno == EEXIST { return false }
        guard errno == ENOENT else { throw CalopodRuntimeError.invalidStatePath }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else {
            throw CalopodRuntimeError.invalidStatePath
        }
        return true
    }

    /// Creates `url` with mode 0600 if it does not exist, then writes
    /// `contents` (when given). An existing file is left as it is.
    public static func createFile(at url: URL, contents: Data? = nil) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if descriptor < 0 {
            guard errno == EEXIST, contents == nil else {
                throw CalopodRuntimeError.invalidStatePath
            }
            return
        }
        defer { close(descriptor) }
        guard let contents, !contents.isEmpty else { return }
        try contents.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                guard written > 0 else { throw CalopodRuntimeError.invalidStatePath }
                offset += written
            }
        }
    }
}
