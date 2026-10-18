import SwiftUI

/// The title row every screen starts with: a serif title, an optional line under it and a
/// slot for controls on the right. Every screen places its title with the same rule
/// (`Theme.Page.titleStart`): at the page margin while the sidebar is open, and right after the
/// collapse button, on its row, once the sidebar is collapsed.
struct PageHeader<Controls: View>: View {
    let title: String
    var subtitle: String?
    var horizontal: CGFloat = Theme.pagePadding
    @Environment(\.sidebarCollapsed) private var collapsed
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
        .padding(.leading, Theme.Page.titleInset(collapsed: collapsed, horizontal: horizontal))
        .accessibilityElement(children: .contain)
    }
}

extension PageHeader where Controls == EmptyView {
    init(_ title: String, subtitle: String? = nil, horizontal: CGFloat = Theme.pagePadding) {
        self.init(title: title, subtitle: subtitle, horizontal: horizontal) { EmptyView() }
    }
}
