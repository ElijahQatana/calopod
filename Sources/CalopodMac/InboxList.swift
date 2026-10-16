import CalopodCommands
import SwiftUI

/// Events grouped by day. The selected row is drawn here, so it takes the
/// app accent rather than the system selection color.
struct InboxList: View {
    let entries: [InboxEntry]
    let colors: CalendarColors
    @Binding var selection: String?

    var body: some View {
        let days = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.startsAt) }
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(days.keys.sorted(), id: \.self) { day in
                    Text(day.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                    ForEach(days[day] ?? []) { entry in selectable(entry) }
                }
            }
            .padding(.vertical, 6)
        }
        .panelFill(.inner, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.downArrow) { move(1) }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard let index = entries.firstIndex(where: { $0.id == selection }) else { return .ignored }
        let next = index + step
        if entries.indices.contains(next) { selection = entries[next].id }
        return .handled
    }

    private func selectable(_ entry: InboxEntry) -> some View {
        let selected = entry.id == selection
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { selection = entry.id } label: {
            row(entry)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if selected {
                        shape.fill(Theme.pane)
                            .overlay(shape.strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func row(_ entry: InboxEntry) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle().fill(colors.color(for: entry.calendarID).color).frame(width: 9, height: 9).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).fontWeight(.semibold).lineLimit(1)
                Text(InboxText.time(entry)).font(.caption).foregroundStyle(.secondary)
                InboxText.statusLine(entry).font(.caption2.weight(.medium))
            }
        }
        .padding(.vertical, 2)
    }
}
