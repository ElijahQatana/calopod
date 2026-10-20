import SwiftUI

/// A column of views whose gaps grow into spare height, up to `maxSpacing`, so a tall window
/// is used without stretching the cards themselves.
struct SpreadStack: Layout {
    var spacing: CGFloat = 12
    var maxSpacing: CGFloat = 24

    private func natural(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (height: CGFloat, gaps: CGFloat) {
        let width = ProposedViewSize(width: proposal.width, height: nil)
        let heights = subviews.map { $0.sizeThatFits(width).height }
        let gaps = CGFloat(max(subviews.count - 1, 0))
        return (heights.reduce(0, +) + gaps * spacing, gaps)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (height, gaps) = natural(proposal, subviews)
        let most = height + gaps * (maxSpacing - spacing)
        let given = proposal.height.map { $0.isFinite ? min(max($0, height), most) : most } ?? height
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return CGSize(width: width, height: given)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (height, gaps) = natural(proposal, subviews)
        let gap = gaps == 0 ? 0 : min(maxSpacing, spacing + max(0, bounds.height - height) / gaps)
        var y = bounds.minY
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + gap
        }
    }
}

/// Cards in equal columns, as many per row as fit at `minColumnWidth`. Cards in one row take the
/// height of the tallest, and when the width allows only one column each keeps its own height.
struct CardColumns: Layout {
    var minColumnWidth: CGFloat
    var spacing: CGFloat = 16

    private func count(_ width: CGFloat, _ subviews: Subviews) -> Int {
        max(1, min(subviews.count, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    /// The rows of subview indexes and each row's height.
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (rows: [[Int]], heights: [CGFloat], column: CGFloat) {
        let columns = count(width, subviews)
        let column = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let indexes = Array(subviews.indices)
        let rows = stride(from: 0, to: indexes.count, by: columns).map { Array(indexes[$0..<min($0 + columns, indexes.count)]) }
        let heights = rows.map { row in
            row.map { subviews[$0].sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        }
        return (rows, heights, column)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        let layout = rows(width, subviews)
        return CGSize(width: width, height: layout.heights.reduce(0, +) + spacing * CGFloat(max(layout.rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in zip(layout.rows, layout.heights) {
            for (position, index) in row.enumerated() {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(position) * (layout.column + spacing), y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: layout.column, height: height))
            }
            y += height + spacing
        }
    }
}
