import SwiftUI

/// A calendar's color as a dot. Clicking it opens the palette.
struct CalendarColorDot: View {
    let calendarID: String
    let colors: CalendarColors
    @State private var showing = false

    var body: some View {
        let current = colors.color(for: calendarID)
        Button { showing = true } label: {
            Circle().fill(current.color).frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                .padding(4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calendar color")
        .accessibilityValue(current.name)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6), spacing: 8) {
                    ForEach(CalendarColor.palette) { option in
                        Button { colors.set(option, for: calendarID) } label: {
                            Circle().fill(option.color).frame(width: 24, height: 24)
                                .overlay {
                                    if option == current {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 28, height: 28)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help(option.name)
                        .accessibilityLabel(option.name)
                    }
                }
                if let match = colors.providerMatch(for: calendarID) {
                    Button { colors.matchProvider(for: calendarID) } label: {
                        Label("Match \(match.name)", systemImage: "eyedropper")
                    }
                    .help("Use \(match.color.name), the closest to the color \(match.name) uses")
                }
                Text("Shown only in Calopod on this Mac. The calendar itself is not changed.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 6 * 28 + 5 * 8, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }
}
