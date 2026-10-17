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
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(Theme.Control.height), spacing: 6), count: 6), spacing: 8) {
                    ForEach(CalendarColor.palette) { option in
                        Button { colors.set(option, for: calendarID) } label: {
                            Circle().fill(option.color).frame(width: 28, height: 28)
                                .overlay {
                                    if option == current {
                                        Image(systemName: "checkmark")
                                            .font(Theme.Fonts.secondarySemibold)
                                            .foregroundStyle(.white)
                                    }
                                }
                                .frame(width: Theme.Control.height, height: Theme.Control.height)
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
                    .font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    .frame(width: 6 * Theme.Control.height + 5 * 6, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .appTypography()
        }
    }
}
