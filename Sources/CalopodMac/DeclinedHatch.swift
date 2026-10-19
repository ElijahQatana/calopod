import SwiftUI

extension Theme {
    /// Strength of the lines on a declined event, before the block itself is dimmed.
    static let declinedHatchOpacity = 0.6
}

extension View {
    /// Diagonal lines in the calendar's color for an event the user declined. Draws nothing, and
    /// adds no Canvas, for any other event. Put it on the fill so the text stays on top.
    @ViewBuilder
    func declinedHatch(_ declined: Bool, color: Color) -> some View {
        if declined {
            overlay { DeclinedHatchLines(color: color).equatable().allowsHitTesting(false) }
        } else {
            self
        }
    }
}

/// Its own view, so a selection change elsewhere does not redraw the lines.
private struct DeclinedHatchLines: View, Equatable {
    let color: Color

    var body: some View {
        Canvas { context, size in
            // Short blocks get thinner, closer lines so a few still fit.
            let short = size.height < 24
            let step: CGFloat = short ? 5 : 7
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(path, with: .color(color.opacity(Theme.declinedHatchOpacity)), lineWidth: short ? 0.75 : 1)
        }
    }
}
