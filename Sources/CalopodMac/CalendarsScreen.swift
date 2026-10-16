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
                    ForEach(connection.calendars) { calendar in
                        Toggle(
                            isOn: Binding(
                                get: { calendar.isSelected },
                                set: { value in Task { await model.setSelected(calendar.id, value) } }
                            )
                        ) {
                            HStack(spacing: 8) {
                                CalendarColorDot(calendarID: calendar.id, colors: colors)
                                Text(calendar.name)
                                if calendar.isReadOnly {
                                    Text("read-only").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(model.isBusy)
                    }
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
            colors.assignMissing(to: (snapshot?.connections ?? []).flatMap { connection in
                connection.calendars.map {
                    CalendarColorSource(id: $0.id, providerColor: $0.providerColor, provider: connection.provider)
                }
            })
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
