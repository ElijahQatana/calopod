import AppKit
import CalopodCommands
import CalopodDomain
import SwiftUI

/// Opens meeting URLs with the default apps. The app is only tried when something is registered for its scheme.
struct WorkspaceMeetingOpener: MeetingURLOpening {
    func hasHandler(for url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
                continuation.resume(returning: error == nil && app != nil)
            }
        }
    }
}

extension MeetingJoiner {
    static var system: MeetingJoiner { MeetingJoiner(opener: WorkspaceMeetingOpener()) }
}

/// "Join Teams", "Join Zoom" and so on. It stands out when the event is on now or soon.
struct JoinButton: View {
    let link: MeetingLink
    var prominent = false
    let action: () -> Void

    var body: some View {
        if prominent {
            Button(action: action) { label }.buttonStyle(.accentFilled)
        } else {
            Button(action: action) { label }
        }
    }

    private var label: some View {
        Label(link.buttonTitle, systemImage: "video").labelStyle(.titleAndIcon)
    }
}

extension JoinButton {
    static func help(for link: MeetingLink) -> String {
        link.appURL == nil
            ? "Opens the \(link.provider.displayName) link in your browser."
            : "Opens \(link.provider.displayName) if it is installed, otherwise the link in your browser."
    }
}
