import AppKit
import CalopodCommands
import SwiftUI
import UniformTypeIdentifiers

struct SettingsFileSection: View {
    let model: SettingsFileModel

    var body: some View {
        CardSection(
            "Settings file",
            footnote: "The file has your calendar and account names in it, so don't share it. Sign-ins are not in it; sign in again on the new Mac."
        ) {
            CardRow {
                HStack(spacing: 12) {
                    Button("Export settings…") { export() }
                    Button("Import settings…") { choose() }
                    Spacer(minLength: 0)
                }
            }
            if let plan = model.plan { preview(plan) }
            if let message = model.message {
                CardRow { Banner(kind: model.failed ? .error : .info, text: message) }
            }
        }
    }

    @ViewBuilder
    private func preview(_ plan: SettingsImportPlan) -> some View {
        CardRow {
            VStack(alignment: .leading, spacing: 6) {
                if plan.lines.isEmpty { Text("Nothing to change.").font(Theme.Fonts.body) }
                ForEach(plan.lines, id: \.self) { Text($0).font(Theme.Fonts.body) }
                if !plan.missingConnections.isEmpty {
                    Text("Sign in again, then import again: \(plan.missingConnections.joined(separator: ", "))")
                        .font(Theme.Fonts.body).foregroundStyle(.secondary)
                }
                if !plan.unmatched.isEmpty {
                    Text("Not found here, so left as they are: \(plan.unmatched.joined(separator: ", "))")
                        .font(Theme.Fonts.body).foregroundStyle(.secondary)
                }
                if plan.addsArms {
                    Text(SettingsImportPlan.copiesNotice).font(Theme.Fonts.body).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        CardRow {
            HStack(spacing: 12) {
                if !plan.lines.isEmpty { Button("Make changes") { model.applyImport() }.buttonStyle(.accentFilled) }
                Button("Cancel") { model.cancelImport() }
                Spacer(minLength: 0)
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "calopod-config.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { model.chooseImport(url) }
    }
}
