import Foundation

/// The `calopod` link in `~/.local/bin` and the command inside the app it should point to.
/// The home folder and app path are passed in so tests can use temporary folders.
struct CommandLink {
    enum State: Equatable {
        /// Nothing at the link path.
        case notInstalled
        /// A link to the command in this app.
        case installed
        /// A working link to something else, such as the source install.
        case elsewhere(target: String)
        /// A link whose target is missing.
        case broken(target: String)
        /// A file or folder that is not a link. Left alone.
        case occupied
    }

    enum Failure: Error, Equatable {
        case notInThisApp
        case occupied
        case needsReplaceConfirmation
    }

    static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""

    let home: URL
    let bundle: URL
    private let fileManager = FileManager.default

    var binDirectory: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }
    var linkURL: URL { binDirectory.appendingPathComponent("calopod") }
    var commandURL: URL { bundle.appendingPathComponent("Contents/MacOS/calopod") }

    /// False when the app does not carry the command, as with a build run from a folder.
    var commandIsBundled: Bool { fileManager.isExecutableFile(atPath: commandURL.path) }

    func state() -> State {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path) else {
            return fileManager.fileExists(atPath: linkURL.path) ? .occupied : .notInstalled
        }
        let resolved = resolve(target)
        if pointsIntoApp(resolved) { return .installed }
        return fileManager.fileExists(atPath: resolved) ? .elsewhere(target: resolved) : .broken(target: resolved)
    }

    /// Links the command. A working link to something else is replaced only with `replacingOther`.
    /// Move to the app will take over a source-installed link in a later step.
    func install(replacingOther: Bool = false) throws {
        switch state() {
        case .occupied: throw Failure.occupied
        case .elsewhere where !replacingOther: throw Failure.needsReplaceConfirmation
        case .notInstalled: break
        default: try fileManager.removeItem(at: linkURL)
        }
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: commandURL.path)
    }

    /// Deletes the link only when it points into this app, whether or not the target is still there.
    func remove() throws {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path),
            pointsIntoApp(resolve(target))
        else { throw Failure.notInThisApp }
        try fileManager.removeItem(at: linkURL)
    }

    /// Whether Terminal is likely to find `~/.local/bin`: it is in `PATH`, or a shell profile mentions it.
    func binIsOnPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if entries.contains(where: { URL(fileURLWithPath: $0).standardizedFileURL.path == binDirectory.standardizedFileURL.path }) {
            return true
        }
        let profiles = [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"]
        return profiles.contains { name in
            let text = try? String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
            return text?.contains(".local/bin") == true
        }
    }

    private func resolve(_ target: String) -> String {
        let url = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : URL(fileURLWithPath: target, relativeTo: binDirectory)
        return url.standardizedFileURL.path
    }

    private func pointsIntoApp(_ path: String) -> Bool {
        path.hasPrefix(bundle.standardizedFileURL.path + "/")
    }
}
