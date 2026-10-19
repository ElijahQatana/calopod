import SwiftUI

/// The left drawer the logo opens, over a dimmed screen. Status is a tab, so it is not listed here.
struct MenuDrawer: View {
    var navigation: Navigation
    var calendarsSummary: String?

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.text.opacity(0.4).ignoresSafeArea()
                .onTapGesture { navigation.menuOpen = false }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    SquidMarkView(color: Theme.onAccent).frame(width: 26, height: 26).padding(7)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Calopod").font(Theme.Fonts.heading)
                        Text("Calendar companion").font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.bottom, 18)
                item("Settings", "gearshape", .settings)
                if let calendarsSummary { item("Calendars", "calendar", .calendars, detail: calendarsSummary) }
                item("Help", "questionmark.circle", .help)
                item("About", "info.circle", .about)
                Spacer()
                HStack {
                    Label("Read only", systemImage: "lock").font(.caption.weight(.semibold))
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(Theme.accentSoft, in: Capsule()).foregroundStyle(Theme.accent)
                    Spacer()
                    Text("Version \(AppInfo.version())").font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary)
                }
            }
            .padding(20)
            .frame(width: 290)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background { Theme.card.ignoresSafeArea().shadow(color: Theme.text.opacity(0.2), radius: 16, x: 4) }
            .accessibilityAddTraits(.isModal)
        }
    }

    private func item(_ title: String, _ icon: String, _ page: Navigation.Page, detail: String? = nil) -> some View {
        Button { navigation.open(page) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 24).foregroundStyle(Theme.accent)
                Text(title).font(Theme.Fonts.bodyStrong)
                Spacer(minLength: 0)
                if let detail { Text(detail).font(Theme.Fonts.secondary).foregroundStyle(Theme.secondary) }
            }
            .frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
