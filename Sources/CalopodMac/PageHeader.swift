import SwiftUI

/// The title row every screen starts with: a serif title, an optional line under it and a
/// slot for controls on the right. When the sidebar is collapsed the title shares the
/// collapse button's row, so it keeps clear of it.
struct PageHeader<Controls: View>: View {
    let title: String
    var subtitle: String?
    var horizontal: CGFloat = Theme.pagePadding
    /// Start at the top left of the panel, beside the collapse button, whatever the sidebar is doing.
    var pinnedLeft = false
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.heading).lineLimit(1).minimumScaleFactor(0.8)
                    .frame(minHeight: Theme.Control.height, alignment: .leading)
                if let subtitle {
                    Text(subtitle).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 10) { controls }.frame(minHeight: Theme.Control.height)
        }
        .modifier(HeaderLeading(pinnedLeft: pinnedLeft, horizontal: horizontal))
        .accessibilityElement(children: .contain)
    }
}

private struct HeaderLeading: ViewModifier {
    let pinnedLeft: Bool
    let horizontal: CGFloat

    func body(content: Content) -> some View {
        if pinnedLeft {
            content.padding(.leading, Theme.Page.titleLeading)
        } else {
            content.titleClearOfToggle(horizontal: horizontal)
        }
    }
}

extension PageHeader where Controls == EmptyView {
    init(_ title: String, subtitle: String? = nil, horizontal: CGFloat = Theme.pagePadding, pinnedLeft: Bool = false) {
        self.init(title: title, subtitle: subtitle, horizontal: horizontal, pinnedLeft: pinnedLeft) { EmptyView() }
    }
}
