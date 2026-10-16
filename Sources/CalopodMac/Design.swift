import SwiftUI

enum Theme {
    /// System accent, so the app matches the rest of macOS.
    static let accent = Color.accentColor
    static let good = Color(red: 0.20, green: 0.62, blue: 0.40)
    static let caution = Color(red: 0.88, green: 0.58, blue: 0.14)
    static let bad = Color(red: 0.80, green: 0.28, blue: 0.28)

    static let cardRadius: CGFloat = 14
    static let pagePadding: CGFloat = 28
}

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

struct Hint<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
