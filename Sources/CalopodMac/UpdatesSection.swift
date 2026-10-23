import AppKit
import SwiftUI

/// The version, a button to look for a newer one, and the switch for a daily check.
struct UpdatesSection: View {
    let model: UpdateModel

    var body: some View {
        CardSection(
            "Updates",
            footnote: "Checking asks GitHub for the newest release and sends no calendar data. Nothing is downloaded or installed for you."
        ) {
            CardRow("Version") { Text(model.current).foregroundStyle(.secondary) }
            CardRow {
                HStack(spacing: 12) {
                    Button("Check for updates") { Task { await model.check() } }.disabled(model.isChecking)
                    if let page = offeredPage {
                        Button("Open release page") { NSWorkspace.shared.open(page) }.buttonStyle(.accentFilled)
                    }
                    Text(status).font(Theme.Fonts.body).foregroundStyle(.secondary)
                }
            }
            CardRow("Check once a day") {
                Toggle("", isOn: Binding(get: { model.checksDaily }, set: model.setChecksDaily)).labelsHidden()
            }
        }
    }

    private var offeredPage: URL? {
        if case let .available(_, page) = model.result { page } else { nil }
    }

    private var status: String {
        if model.isChecking { return "Checking…" }
        switch model.result {
        case nil: return ""
        case .upToDate: return "You have the newest release."
        case let .available(version, _): return "Calopod \(version) is out."
        case let .failed(reason): return reason
        }
    }
}
