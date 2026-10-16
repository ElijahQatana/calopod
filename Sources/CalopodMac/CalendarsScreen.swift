import CalopodCommands
import SwiftUI

/// Connect accounts and choose which calendars Calopod reads.
struct CalendarsScreen: View {
    let model: SetupModel

    var body: some View {
        ScreenScaffold {
            ScreenHeader(
                title: "Calendars",
                subtitle: "Calopod reads the calendars you choose and never changes them."
            )
            BusyLine(text: model.busy)
            if let notice = model.notice { Banner(kind: .error, text: notice) }

            addCard

            ForEach(model.snapshot?.connections ?? []) { connection in
                connectionCard(connection)
            }
            if model.snapshot?.connections.isEmpty ?? true, !model.isBusy {
                Text("No accounts yet. Add one above to get started.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { await model.reload() }
    }

    private var addCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Add an account")
                HStack(spacing: 10) {
                    addButton("This Mac", "laptopcomputer", .mac)
                    addButton("Google", "g.circle", .google)
                    addButton("Microsoft", "m.circle", .microsoft)
                }
                Text("Choose each calendar only once, even if it can be reached two ways.")
                    .font(.callout).foregroundStyle(.secondary)
            }
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

    private func connectionCard(_ connection: SetupConnection) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: Self.symbol(connection.provider))
                        .foregroundStyle(Theme.accent)
                    Text(connection.label).font(.headline)
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
                ForEach(connection.warnings, id: \.self) { Banner(kind: .caution, text: $0) }
                Divider()
                ForEach(connection.calendars) { calendar in
                    HStack {
                        Text(calendar.name)
                        if calendar.isReadOnly {
                            Text("read-only").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(calendar.name, isOn: Binding(
                            get: { calendar.isSelected },
                            set: { value in Task { await model.setSelected(calendar.id, value) } }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(model.isBusy)
                    }
                }
            }
        }
    }

    private static func symbol(_ provider: String) -> String {
        switch provider {
        case "google": "g.circle.fill"
        case "microsoft": "m.circle.fill"
        default: "laptopcomputer"
        }
    }
}
