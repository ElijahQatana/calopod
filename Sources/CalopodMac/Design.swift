import SwiftUI

/// The look of the Mac app: calm surfaces, one accent, generous spacing, semantic status colors.
enum Theme {
    /// Deep ocean teal, from the squid.
    static let accent = Color(red: 0.12, green: 0.50, blue: 0.62)
    static let good = Color(red: 0.20, green: 0.62, blue: 0.40)
    static let caution = Color(red: 0.88, green: 0.58, blue: 0.14)
    static let bad = Color(red: 0.80, green: 0.28, blue: 0.28)

    static let cardRadius: CGFloat = 14
    static let pagePadding: CGFloat = 28
}

/// A soft rounded surface that holds one idea.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

/// Title and one-line explanation at the top of every screen, with room for a trailing action.
struct ScreenHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(title: String, subtitle: String) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Scrolls a screen's content with consistent margins and a readable maximum width.
struct ScreenScaffold<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(Theme.pagePadding)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A small colored dot and word, such as "Running" or "Paused".
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// A number with a caption, for the overview.
struct StatTile: View {
    let value: String
    let caption: String
    var color: Color = .primary

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                Text(caption).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// A short banner for something that needs attention. Never red unless it is an error.
struct Banner: View {
    enum Kind { case info, caution, error }
    let kind: Kind
    let text: String

    private var color: Color {
        switch kind {
        case .info: Theme.accent
        case .caution: Theme.caution
        case .error: Theme.bad
        }
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.10)))
    }
}

struct BusyLine: View {
    let text: String?

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

extension ButtonStyle where Self == AccentButtonStyle {
    static var accentFilled: AccentButtonStyle { AccentButtonStyle() }
}

/// The one prominent button on a screen.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35))
            )
    }
}

enum Format {
    static func ago(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(seconds / 60) min ago"
        case ..<86400: "\(seconds / 3600) hr ago"
        default: "\(seconds / 86400) d ago"
        }
    }

    static func interval(_ seconds: Int) -> String {
        switch seconds {
        case ..<120: "\(seconds) seconds"
        case ..<7200: "\(seconds / 60) minutes"
        default: "\(seconds / 3600) hours"
        }
    }
}
