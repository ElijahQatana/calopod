import SwiftUI

/// The shared card look: the inner fill with a hairline edge.
extension View {
    func cardSurface() -> some View {
        panelFill(.inner, in: armCardShape)
            .overlay(armCardShape.strokeBorder(Theme.paneLine, lineWidth: 1))
    }
}

/// A scrolling page of card sections, with an optional page header.
struct CardPage<Content: View>: View {
    var title: String?
    /// Text at the right of the title row, such as a date.
    var trailing: String?
    var maxWidth: CGFloat = 760
    @ViewBuilder var content: Content
    @Environment(\.sidebarCollapsed) private var collapsed

    var body: some View {
        ScrollView { page }
    }

    var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                PageHeader(title: title) {
                    if let trailing { Text(trailing).font(Theme.Fonts.body).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, Theme.Page.topPadding(collapsed: collapsed, inlineHeader: true))
                .padding(.bottom, 16)
            }
            VStack(alignment: .leading, spacing: 16) { content }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, title == nil ? Theme.Page.topPadding(collapsed: collapsed, inlineHeader: false) : 0)
                .padding(.bottom, Theme.Page.bottom)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A card with an optional header above it and a footnote below.
struct CardSection<Header: View, Content: View>: View {
    let header: Header
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header.padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(armCardShape)
                .cardSurface()
            if let footnote {
                Text(footnote).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

extension CardSection where Header == EmptyView {
    init(footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(header: EmptyView(), footnote: footnote, content: content)
    }
}

extension CardSection where Header == Text {
    init(_ title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(header: Text(title).font(Theme.Fonts.sectionTitle), footnote: footnote, content: content)
    }
}

/// One row in a card. A hairline above it separates it from the row before; on the first
/// row it sits under the card's edge.
struct CardRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 44)
            .overlay(alignment: .top) { Divider().padding(.leading, 16) }
    }
}

/// A title on the left and a value or control on the right.
struct CardLabeled<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension CardRow {
    init<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing)
    where Content == CardLabeled<Trailing> {
        self.init { CardLabeled(title: title, trailing: trailing) }
    }

    init(_ title: String, value: String) where Content == CardLabeled<Text> {
        self.init { CardLabeled(title: title) { Text(value).foregroundStyle(.secondary) } }
    }
}

/// A checkbox with a label beside it. The box is centered on the whole label, so it stays level
/// with the middle of a two-line label instead of sitting on its first line.
struct CheckboxRow<Label: View>: View {
    let title: String
    @Binding var isOn: Bool
    @ViewBuilder var label: Label

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Toggle(title, isOn: $isOn).labelsHidden()
            label
                .contentShape(Rectangle())
                .onTapGesture { isOn.toggle() }
                .accessibilityHidden(true)
        }
    }
}
