import CalopodCommands
import SwiftUI

/// One event in the grid. The base look says who it belongs to and whether it needs an answer;
/// the red ring and accent dot are added on top.
struct ScheduleEventBlock: View {
    let event: ScheduleEvent
    let color: Color
    let isSelected: Bool
    let width: CGFloat
    let height: CGFloat

    /// Narrower than this, a title cannot be read, so the block shows color only.
    static let minimumTextWidth: CGFloat = 32

    private var style: EventBlockStyle { EventBlockStyle.of(event) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        let lines = ScheduleLayout.titleLines(width: width, height: height, allDay: event.isAllDay)
        let narrow = width < 72
        // Tall or narrow blocks keep the dot in the bottom corner; a short wide one puts it beside the title.
        let dotBelow = height >= 36 || narrow
        let dotBeside = ScheduleLayout.showsChange(event) && !dotBelow
        let glyph = style.base == .copyFull && width >= 56 && height >= 24
        ZStack(alignment: .topLeading) {
            Color.clear.eventFill(style, color: color, shape: shape)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(narrow ? Theme.Fonts.tinySemibold : Theme.Fonts.eventTitle)
                    .lineLimit(lines)
                if !event.isAllDay, height >= 44, width >= 72 {
                    Text(event.startsAt.formatted(date: .omitted, time: .shortened))
                        .font(Theme.Fonts.tiny)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, width < 72 ? 7 : 9).padding(.trailing, glyph ? 20 : dotBeside ? 14 : (narrow ? 3 : 6)).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(width >= Self.minimumTextWidth ? 1 : 0)

            if glyph {
                Image(systemName: "doc.on.doc").font(Theme.Fonts.tiny).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 3).padding(.trailing, 5)
                    .accessibilityHidden(true)
            }
            if ScheduleLayout.showsChange(event) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dotBelow ? .bottomTrailing : .trailing)
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
        .clipShape(shape)
        .overlay {
            if ScheduleLayout.showsOverlap(event) { shape.strokeBorder(Theme.bad, lineWidth: 1.5) }
        }
        .overlay {
            if isSelected { shape.inset(by: -2).strokeBorder(Theme.accent, lineWidth: 2.5) }
        }
        .opacity(style.faded ? 0.5 : 1)
        .contentShape(shape)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var helpText: String {
        guard let origin = event.copyOrigin else { return event.title }
        let name = CalendarAliases.shared.name(for: origin.sourceCalendarID, real: origin.sourceCalendarName)
        return "Copy from \(name)"
    }

    private var accessibilityText: String {
        var parts = [event.title]
        if !event.isAllDay { parts.append(event.startsAt.formatted(date: .omitted, time: .shortened)) }
        if event.isCopy {
            parts.append(CopyWords.kind(event).lowercased())
            if let answer = CopyWords.response(event.carriedResponse) { parts.append(answer.lowercased()) }
        } else if style.base == .needsRSVP {
            parts.append("Needs reply")
        } else if style.hatched {
            parts.append("declined")
        }
        if ScheduleLayout.showsOverlap(event) { parts.append("Overlaps another event") }
        if let text = ScheduleLayout.changeText(event) { parts.append(text) }
        return parts.joined(separator: ", ")
    }
}
