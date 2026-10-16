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

    private var treatment: ScheduleLayout.Treatment { ScheduleLayout.treatment(for: event) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 8, style: .continuous) }

    var body: some View {
        // One line when narrow, so a word is never broken across lines.
        let lines = width < 72 ? 1 : max(1, Int((height - 8) / 13))
        ZStack(alignment: .topLeading) {
            background
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(event.isAllDay ? 1 : lines)
                if !event.isAllDay, height >= 44, width >= 72 {
                    Text(event.startsAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(treatment == .copy ? .secondary : .primary)
            .padding(.leading, width < 72 ? 7 : 9).padding(.trailing, width < 72 ? 3 : 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(width >= Self.minimumTextWidth ? 1 : 0)

            if ScheduleLayout.showsChange(event) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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
        .opacity(treatment == .declined ? 0.5 : 1)
        .contentShape(shape)
        .help(event.title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var background: some View {
        switch treatment {
        case .copy:
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .overlay { Hatch().clipShape(shape) }
                .overlay(alignment: .leading) { Rectangle().fill(.tertiary).frame(width: 3) }
        case .needsRSVP:
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .overlay { shape.inset(by: 0.75).strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
        case .tinted, .declined:
            shape.fill(Color(nsColor: .windowBackgroundColor))
                .overlay { shape.fill(color.opacity(0.22)) }
                .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3) }
        }
    }

    private var accessibilityText: String {
        var parts = [event.title]
        if !event.isAllDay { parts.append(event.startsAt.formatted(date: .omitted, time: .shortened)) }
        if treatment == .copy { parts.append("Busy copy") }
        if treatment == .needsRSVP { parts.append("Needs reply") }
        if ScheduleLayout.showsOverlap(event) { parts.append("Overlaps another event") }
        if ScheduleLayout.showsChange(event) { parts.append("Changed since you last looked") }
        return parts.joined(separator: ", ")
    }
}

/// Diagonal stripes for copies Calopod made.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
        }
    }
}
