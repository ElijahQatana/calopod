import CalopodCommands
import SwiftUI

struct CalendarsScreen: View {
    let model: SetupModel
    private let colors = CalendarColors.shared

    var body: some View {
        Form {
            if let busy = model.busy {
                Section { BusyLine(text: busy) }
            }
            if let notice = model.notice {
                Section { Banner(kind: .error, text: notice) }
            }

            Section {
                HStack(spacing: 10) {
                    addButton("This Mac", "laptopcomputer", .mac)
                    addButton("Google", "g.circle", .google)
                    addButton("Microsoft", "m.circle", .microsoft)
                }
                Hint {
                    Text(
                        "Calopod reads the calendars you choose and never changes them. Choose each calendar once, even if it can be reached two ways."
                    )
                }
            } header: {
                Text("Add an account")
            }

            ForEach(model.snapshot?.connections ?? []) { connection in
                Section {
                    ForEach(connection.warnings, id: \.self) { Banner(kind: .caution, text: $0) }
                    CalendarList(connection: connection, model: model, colors: colors)
                } header: {
                    HStack {
                        Label(connection.label, systemImage: Self.symbol(connection.provider))
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
            }
        }
        .formStyle(.grouped)
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
