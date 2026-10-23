import CalopodCommands
import SwiftUI

struct CalendarsScreen: View {
    let model: SetupModel
    private let colors = CalendarColors.shared

    var body: some View {
        CardPage(title: "Calendars") {
            if let busy = model.busy { BusyLine(text: busy, cancel: model.cancelSignIn) }
            if let notice = model.notice { Banner(kind: .error, text: notice, onDismiss: model.dismissNotice) }

            CardSection(
                "Add an account",
                footnote:
                    "Calopod reads the calendars you choose and never changes them. Choose each calendar once, even if it can be reached two ways."
            ) {
                CardRow {
                    HStack(spacing: 10) {
                        addButton("This Mac", "laptopcomputer", .mac)
                        addButton("Google", "g.circle", .google)
                        addButton("Microsoft", "m.circle", .microsoft)
                    }
                }
                CardRow { Hint { Text(SetupProvider.setupNote) } }
            }

            ForEach(model.snapshot?.connections ?? []) { connection in
                CardSection(header: accountHeader(connection)) {
                    ForEach(connection.warnings, id: \.self) { warning in
                        CardRow { Banner(kind: .caution, text: warning) }
                    }
                    CalendarList(connection: connection, model: model, colors: colors)
                }
            }
        }
        .task { await model.reload() }
        .onDisappear { model.dismissNotice() }
    }

    private func accountHeader(_ connection: SetupConnection) -> some View {
        HStack {
            Label(connection.label, systemImage: Self.symbol(connection.provider))
                .font(Theme.Fonts.sectionTitle)
            Spacer()
            Menu {
                Button("Refresh calendars") { Task { await model.refresh(connection.id) } }
                Divider()
                Button("Remove account", role: .destructive) {
                    Task { await model.disconnect(connection.id) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(Theme.Fonts.bodySemibold)
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.Control.height, height: Theme.Control.height)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More actions for \(connection.label)")
            .disabled(model.isBusy)
        }
    }

    private func addButton(_ title: String, _ symbol: String, _ provider: SetupProvider) -> some View {
        Button {
            Task { await model.connect(provider) }
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(model.isBusy || !provider.isAvailable)
    }

    private static func symbol(_ provider: String) -> String {
        switch provider {
        case "google": "g.circle.fill"
        case "microsoft": "m.circle.fill"
        default: "laptopcomputer"
        }
    }
}
