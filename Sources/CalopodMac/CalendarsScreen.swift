import CalopodCommands
import SwiftUI

struct CalendarsScreen: View {
    let model: SetupModel
    private let colors = CalendarColors.shared

    var body: some View {
        CardPage {
            if let busy = model.busy { BusyLine(text: busy) }
            if let notice = model.notice { Banner(kind: .error, text: notice) }

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
        .onChange(of: model.snapshot) { _, snapshot in
            colors.assignMissing(
                to: (snapshot?.connections ?? []).flatMap { connection in
                    connection.calendars.map {
                        CalendarColorSource(id: $0.id, providerColor: $0.providerColor, provider: connection.provider)
                    }
                },
                ignoring: model.aliases.ignored)
        }
    }

    private func accountHeader(_ connection: SetupConnection) -> some View {
        HStack {
            Label(connection.label, systemImage: Self.symbol(connection.provider))
                .font(Theme.title(.headline))
            Spacer()
            Menu {
                Button("Refresh calendars") { Task { await model.refresh(connection.id) } }
                Divider()
                Button("Remove account", role: .destructive) {
                    Task { await model.disconnect(connection.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
        .disabled(model.isBusy)
    }

    private static func symbol(_ provider: String) -> String {
        switch provider {
        case "google": "g.circle.fill"
        case "microsoft": "m.circle.fill"
        default: "laptopcomputer"
        }
    }
}
