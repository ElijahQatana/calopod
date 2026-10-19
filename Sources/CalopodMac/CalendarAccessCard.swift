import CalopodCommands
import SwiftUI

/// The prompt shown on Overview and in first run while Calendar access is missing.
struct CalendarAccessCard: View {
    let access: CalendarAccessModel
    let state: CalendarAccessState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Banner(kind: state == .blocked ? .error : .caution, text: "\(state.title). \(state.message)")
            if state == .canAsk {
                Button("Allow") { Task { await access.allow() } }
                    .buttonStyle(.accentFilled)
                    .disabled(access.asking)
            } else {
                Button("Open Calendar privacy settings") { access.openPrivacySettings() }
                    .buttonStyle(.accentFilled)
            }
            CalendarAccessFeedback(access: access, offerReset: state == .blocked, showOpenSettings: state != .blocked)
        }
    }
}

/// What happened when Allow was pressed, with the ways forward when macOS gave no answer. Shared by
/// the Overview card and the Permissions row in Settings.
struct CalendarAccessFeedback: View {
    let access: CalendarAccessModel
    /// Show the reset button even before Allow has been pressed, as when access is already denied.
    var offerReset = false
    /// Left out where the surrounding row already has the button.
    var showOpenSettings = true

    /// Whether anything is worth showing, so a row can leave out the space.
    static func isVisible(_ access: CalendarAccessModel, offerReset: Bool = false) -> Bool {
        access.asking || access.confirmingReset || access.result != nil || offerReset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if access.asking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(CalendarAccessModel.askingText).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                }
            } else if let result = access.result {
                Text(result.message).font(Theme.Fonts.secondary)
                    .foregroundStyle(result.offersWaysForward ? Theme.badText : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if access.confirmingReset {
                Text(Permissions.calendarResetConfirmation).font(Theme.Fonts.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Reset and ask again") { Task { await access.confirmReset() } }
                    Button("Cancel") { access.cancelReset() }
                }
            } else if !access.asking, offerReset || access.result?.offersWaysForward == true {
                HStack {
                    if showOpenSettings {
                        Button("Open Calendar privacy settings") { access.openPrivacySettings() }
                    }
                    Button("Reset Calopod's Calendar decision") { access.askToReset() }
                }
            }
        }
    }
}
