import SwiftUI

/// The left side of the header on a screen opened from another one.
struct BackAction {
    var label: String
    var action: () -> Void
}

/// The header every screen shares: logo, the read-only mark, then a title and one line under it.
struct SharedHeader: View {
    var title: String
    var subtitle: String
    var back: BackAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let back {
                    Button(action: back.action) {
                        Label(back.label, systemImage: "chevron.left").font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                } else {
                    HStack(spacing: 8) {
                        SquidMarkView(color: Theme.accent)
                            .frame(width: 28, height: 28)
                            .padding(5)
                            .background(Theme.onAccent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text("Calopod").font(.callout.weight(.semibold))
                    }
                }
                Spacer()
                Label("Read only", systemImage: "lock")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background(Theme.onAccent.opacity(0.2), in: Capsule())
            }
            .frame(height: 44)
            Text(title)
                .font(Theme.Fonts.title)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 4)
            Text(subtitle)
                .font(.footnote)
                .opacity(0.82)
                .lineLimit(1)
                .padding(.top, 4)
        }
        .foregroundStyle(Theme.onAccent)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .padding(.bottom, 16)
        .background {
            ZStack(alignment: .topTrailing) {
                Theme.accent
                SquidMarkView(color: Theme.onAccent.opacity(0.13))
                    .frame(width: 130, height: 130)
                    .rotationEffect(.degrees(9))
                    .offset(x: 26, y: 6)
            }
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: Theme.headerRadius, bottomTrailingRadius: Theme.headerRadius))
            .shadow(color: Theme.text.opacity(0.18), radius: 10, y: 6)
            .ignoresSafeArea(edges: .top)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A screen: the shared header over a scrolling body on the page color.
struct Screen<Content: View>: View {
    var title: String
    var subtitle: String
    var back: BackAction?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            SharedHeader(title: title, subtitle: subtitle, back: back)
                .zIndex(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, Theme.sidePadding)
                    .padding(.vertical, 18)
            }
        }
        .background(Theme.screen.ignoresSafeArea())
    }
}

/// A white rounded block that rows sit in.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(Theme.Fonts.sectionLabel)
            .tracking(0.7)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 4)
    }
}
