#if os(macOS)
import Foundation

/// What launchd says about one job label.
struct LaunchdService: Equatable {
    var loaded: Bool
    /// The program launchd runs for it, when `launchctl print` names one.
    var program: URL?
}

/// Whether the Calopod app's own background service is the live one for this command, and where it is.
struct AppServiceResolution: Equatable {
    /// The Calopod.app that holds this command, when it runs from inside one.
    var enclosingApp: URL?
    /// The SMAppService registration. Nil when this process is not that app, so macOS cannot say.
    var registration: BackgroundServiceState?
    var launchd: LaunchdService

    var isLive: Bool { registration == .enabled || launchd.loaded }

    /// The app's `calopod-agent`. What launchd runs wins, then the app that holds this command.
    var agentExecutable: URL? {
        guard isLive else { return nil }
        if launchd.loaded, let program = launchd.program { return program }
        return (enclosingApp ?? AppServiceLocator.defaultApp)
            .appendingPathComponent(AppServiceLocator.agentRelativePath)
    }
}

enum AppServiceLocator {
    static let agentRelativePath = "Contents/MacOS/calopod-agent"
    static let defaultApp = URL(fileURLWithPath: "/Applications/Calopod.app", isDirectory: true)

    /// The first `.app` above the real executable. A link such as `~/.local/bin/calopod` is followed.
    static func enclosingApp(of executableURL: URL) -> URL? {
        var ancestor = executableURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent()
        while ancestor.path != "/" {
            if ancestor.pathExtension == "app" { return ancestor }
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    /// `SMAppService` only answers for the app it runs in, so it is asked only when `mainBundleURL`
    /// is the app holding the command. launchd is asked either way.
    static func resolve(
        executableURL: URL,
        mainBundleURL: URL,
        registration: () -> BackgroundServiceState,
        launchd: () -> LaunchdService
    ) -> AppServiceResolution {
        let app = enclosingApp(of: executableURL)
        let isThatApp = app.map {
            $0.resolvingSymlinksInPath().standardizedFileURL == mainBundleURL.resolvingSymlinksInPath().standardizedFileURL
        } ?? false
        return AppServiceResolution(
            enclosingApp: app,
            registration: isThatApp ? registration() : nil,
            launchd: launchd()
        )
    }

    /// The Calopod.app that holds this command, or else the one in Applications, if either is there.
    static func installedApp(
        executableURL: URL = realExecutableURL(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        enclosingApp(of: executableURL) ?? (exists(defaultApp.path) ? defaultApp : nil)
    }

    /// The running command's real path, not `argv[0]` and not the bundle.
    static func realExecutableURL() -> URL {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }

    static func parseProgram(fromLaunchctlPrint output: String) -> URL? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("program = ") else { continue }
            let path = trimmed.dropFirst("program = ".count).trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}

extension LaunchAgentController {
    /// Asks launchd directly, with no help from `SMAppService` or the bundle.
    func service(label: String) -> LaunchdService {
        guard let result = try? printService(label: label), result.exitCode == 0 else {
            return LaunchdService(loaded: false, program: nil)
        }
        return LaunchdService(loaded: true, program: AppServiceLocator.parseProgram(fromLaunchctlPrint: result.output))
    }
}
#endif
