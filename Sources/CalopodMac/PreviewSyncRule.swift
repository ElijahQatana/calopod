import CalopodCommands
import SwiftUI

/// Whether the Preview sync button can be pressed, and why not. Overview and the menu bar window both read it through
/// `ServiceModel.previewRule`.
struct PreviewSyncRule: Equatable {
    /// Shown under or beside a disabled button, and read out as its accessibility hint.
    let disabledReason: String?
    var isEnabled: Bool { disabledReason == nil }

    /// Automatic sync being off or failing does not block a manual preview: it is how people recover.
    static func make(status: AgentControlStatus?, access: CalendarAccessState, busy: Bool, hasPendingPreview: Bool) -> PreviewSyncRule {
        if busy { return PreviewSyncRule(disabledReason: "A sync is running") }
        guard let status, status.installed else { return PreviewSyncRule(disabledReason: "Set up background sync first") }
        if access.isMissing { return PreviewSyncRule(disabledReason: "Needs Calendar access") }
        if hasPendingPreview { return PreviewSyncRule(disabledReason: "Review the open preview first") }
        return PreviewSyncRule(disabledReason: nil)
    }
}

extension View {
    /// Disables the button when the rule says so, with the reason as its tooltip and accessibility hint.
    func previewSync(_ rule: PreviewSyncRule) -> some View {
        disabled(!rule.isEnabled)
            .help(rule.disabledReason ?? "")
            .accessibilityHint(rule.disabledReason ?? "")
    }
}
