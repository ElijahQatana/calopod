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
        }
    }
}
