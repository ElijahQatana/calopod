import CalopodCommands
import SwiftUI

/// One account's calendars: the ones in play, then a collapsed list of the ignored ones.
struct CalendarList: View {
    let connection: SetupConnection
    let model: SetupModel
    let colors: CalendarColors

    var body: some View {
        let split = Dictionary(grouping: connection.calendars) { model.aliases.isIgnored($0.id) }
        ForEach(split[false] ?? []) { calendar in
            CardRow { CalendarRow(calendar: calendar, model: model, colors: colors) }
        }
        if let ignored = split[true] { ignoredList(ignored) }
    }

    /// Collapsed by default. Ignored calendars that still sync are marked on their row.
    @ViewBuilder
    private func ignoredList(_ calendars: [SetupCalendar]) -> some View {
        let open = model.aliases.isExpanded(connection.id)
        CardRow { Button {
            model.aliases.setExpanded(!open, for: connection.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("Ignored (\(calendars.count))")
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed") }
        if open {
            ForEach(calendars) { calendar in
                CardRow { CalendarRow(calendar: calendar, model: model, colors: colors) }
            }
        }
    }
}

/// One calendar on the Calendars screen: color, name, the on/off switch, and local rename and ignore.
struct CalendarRow: View {
    let calendar: SetupCalendar
    let model: SetupModel
    let colors: CalendarColors
    @State private var hovering = false
    @State private var renaming = false

    private var aliases: CalendarAliases { model.aliases }
    private var ignored: Bool { aliases.isIgnored(calendar.id) }
    private var alias: String? { aliases.alias(for: calendar.id) }

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { calendar.isSelected },
                set: { value in Task { await model.setSelected(calendar.id, value) } }
            )
        ) {
            HStack(spacing: 8) {
                CalendarColorDot(calendarID: calendar.id, colors: colors)
                VStack(alignment: .leading, spacing: 1) {
                    Text(aliases.name(for: calendar)).lineLimit(1)
                    if alias != nil {
                        Text(calendar.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if calendar.isReadOnly {
                    Text("read-only").font(.caption).foregroundStyle(.secondary)
                }
                if ignored && model.isInUse(calendar) {
                    Chip(text: "in use")
                        .help("Still syncing. Ignoring only hides it here and in the pickers.")
                }
                actions
            }
        }
        .disabled(model.isBusy)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Rename…") { renaming = true }
            if alias != nil {
                Button("Use the real name") { aliases.setAlias("", for: calendar.id, real: calendar.name) }
            }
            Divider()
            Button(ignored ? "Stop ignoring" : "Ignore") { aliases.setIgnored(!ignored, for: calendar.id) }
        }
    }

    /// Shown on hover so a long list stays calm. The same actions are in the context menu.
    private var actions: some View {
        HStack(spacing: 2) {
            Button { renaming = true } label: { Image(systemName: "pencil").padding(4).contentShape(Rectangle()) }
                .help("Rename on this Mac")
                .accessibilityLabel("Rename")
                .popover(isPresented: $renaming, arrowEdge: .bottom) {
                    RenameCalendar(calendar: calendar, aliases: aliases) { renaming = false }
                }
            Button {
                aliases.setIgnored(!ignored, for: calendar.id)
            } label: {
                Image(systemName: ignored ? "eye" : "eye.slash").padding(4).contentShape(Rectangle())
            }
            .help(ignored ? "Stop ignoring" : "Ignore")
            .accessibilityLabel(ignored ? "Stop ignoring" : "Ignore")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(hovering || renaming ? 1 : 0)
    }
}

/// Edits the name Calopod shows for a calendar. The calendar itself is never renamed.
private struct RenameCalendar: View {
    let calendar: SetupCalendar
    let aliases: CalendarAliases
    let done: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $draft)
                .focused($focused)
                .onSubmit(save)
                .frame(width: 240)
            Text("Name from the calendar: \(calendar.name)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Shown only in Calopod on this Mac. The calendar itself is not changed.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if aliases.alias(for: calendar.id) != nil {
                    Button("Use the real name") {
                        aliases.setAlias("", for: calendar.id, real: calendar.name)
                        done()
                    }
                }
                Spacer()
                Button("Done", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .onAppear {
            draft = aliases.name(for: calendar)
            focused = true
        }
    }

    private func save() {
        aliases.setAlias(draft, for: calendar.id, real: calendar.name)
        done()
    }
}
