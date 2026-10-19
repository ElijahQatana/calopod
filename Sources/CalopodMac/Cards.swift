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
    /// False for a page that fits the window and manages its own overflow.
    var scrolls = true
    @ViewBuilder var content: Content
    @Environment(\.sidebarCollapsed) private var collapsed

    @ViewBuilder
    var body: some View {
        if scrolls { ScrollView { page } } else { page }
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
                .frame(maxWidth: maxWidth, maxHeight: scrolls ? nil : .infinity, alignment: .topLeading)
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
    /// A tighter row for short lists.
    var dense = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, dense ? 6 : 11)
            .frame(minHeight: dense ? 32 : 44)
            .overlay(alignment: .top) { Divider().padding(.leading, 16) }
    }
}

/// A card row that is one button. The whole row lights up under the pointer and dims while pressed.
struct CardButtonRow<Content: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(CardRowButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .overlay(alignment: .top) { Divider().padding(.leading, 16) }
        .accessibilityLabel(label)
    }
}

struct CardRowButtonStyle: ButtonStyle {
    var hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Theme.accent.opacity(configuration.isPressed ? 0.22 : hovering ? 0.12 : 0))
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
