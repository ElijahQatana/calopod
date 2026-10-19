import SwiftUI

/// Shown when the data is old: says how old and that it may be out of date.
struct StaleBanner: View {
    var lastUpdate: Date
    var now: Date
    var offline = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "moon.zzz").font(.title2).foregroundStyle(Theme.caution)
            VStack(alignment: .leading, spacing: 3) {
                Text(Age.lastUpdated(lastUpdate, now: now)).font(Theme.Fonts.heading)
                Text(offline
                    ? "This phone could not reach iCloud. What you see could be out of date."
                    : "Your Mac may be asleep or offline. What you see could be out of date.")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Theme.cautionSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Full-screen states with nothing to show yet. No tab bar, since there is nowhere to go.
struct EmptyState: View {
    var title: String
    var subtitle: String
    var heading: String
    var message: String
    var steps: [String] = []
    var systemImage: String

    var body: some View {
        Screen(title: title, subtitle: subtitle) {
            VStack(spacing: 14) {
                Image(systemName: systemImage).font(.system(size: 44)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                Text(heading).font(Theme.Fonts.heading)
                Text(message).font(Theme.Fonts.body).foregroundStyle(Theme.secondary)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 12) {
                        Text("\(index + 1)").font(Theme.Fonts.caption)
                            .frame(width: 24, height: 24)
                            .background(Theme.accent, in: Circle()).foregroundStyle(Theme.onAccent)
                        Text(step).font(Theme.Fonts.body)
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Text("Data travels only through your own iCloud. This app can't change any calendar.")
                    .font(Theme.Fonts.secondary).foregroundStyle(Theme.faint)
            }
        }
    }
}

struct ReadOnlyFoot: View {
    var text = "Read only. Answer invitations on your Mac."
    var body: some View {
        Label(text, systemImage: "lock")
            .font(Theme.Fonts.secondary).foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity).padding(.top, 8)
    }
}
