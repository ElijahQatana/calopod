import Foundation
import Observation

/// What the Settings "Command line" row shows and does.
@MainActor
@Observable
final class CommandLineModel {
    private(set) var state: CommandLink.State = .notInstalled
    private(set) var notice: String?
    private(set) var confirmingReplace = false
    private(set) var showsPathLine = false
    /// Set when the person said no to taking over a source-installed link, until the app restarts.
    private(set) var takeoverDeclined = false

    @ObservationIgnored private let link: CommandLink?

    /// Nil `link` means the app does not carry the command, as with a build run from a folder.
    init(link: CommandLink? = CommandLineModel.bundledLink()) {
        self.link = link
        refresh()
    }

    static func bundledLink() -> CommandLink? {
        guard ServiceRegistration.isRunningFromBundle else { return nil }
        let link = CommandLink(home: FileManager.default.homeDirectoryForCurrentUser, bundle: Bundle.main.bundleURL)
        return link.commandIsBundled ? link : nil
    }

    var isAvailable: Bool { link != nil }
    var pathLine: String { CommandLink.pathLine }

    func refresh() {
        guard let link else { return }
        state = link.state()
        showsPathLine = state == .installed && !link.binIsOnPath()
    }

    /// Install, repair, or ask first when a working link to something else is in the way.
    func install() {
        guard let link else { return }
        if case .elsewhere = state, !confirmingReplace {
            confirmingReplace = true
            return
        }
        let replacing = confirmingReplace
        run { try link.install(replacingOther: replacing) }
    }

    /// The link still points at the source install, so Move to the app can offer to take it over.
    var offersTakeover: Bool { link?.linksToSourceInstall == true && !takeoverDeclined }

    /// After the person confirmed. A failed link leaves the old one and says so.
    func takeOver() {
        guard offersTakeover, let link else { return }
        run { try link.install(replacingOther: true) }
    }

    func declineTakeover() { takeoverDeclined = true }

    func cancelReplace() { confirmingReplace = false }

    func remove() {
        guard let link else { return }
        run { try link.remove() }
    }

    private func run(_ action: () throws -> Void) {
        notice = nil
        confirmingReplace = false
        do { try action() } catch { notice = Self.message(error) }
        refresh()
    }

    private static func message(_ error: Error) -> String {
        switch error as? CommandLink.Failure {
        case .occupied: return "Something that is not a link is already at ~/.local/bin/calopod, so it was left alone."
        case .notInThisApp: return "That link does not point into this app, so it was left alone."
        case .needsReplaceConfirmation: return "The command points somewhere else. Confirm to replace it."
        case nil:
            // Only file system errors have wording worth showing; other errors would expose type names.
            let reason = (error as NSError).domain == NSCocoaErrorDomain ? " \(error.localizedDescription)" : ""
            return "Could not change ~/.local/bin/calopod.\(reason) The existing link was left as it was."
        }
    }
}
