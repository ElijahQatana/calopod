import CalopodCommands
import SwiftUI

/// A section title with an optional link on the right.
struct OverviewSectionHeader: View {
    let title: String
    var link: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Theme.Fonts.sectionTitle)
            Spacer(minLength: 8)
            if let link {
                Button(link, action: action)
                    .buttonStyle(.plain)
                    .font(Theme.Fonts.secondarySemibold)
                    .foregroundStyle(Theme.accent)
            }
        }
    }
}

/// One bar per recent sync run, oldest on the left. A failed run is drawn shorter, so the
/// difference does not rest on color alone.
struct RunBars: View {
    let marks: [RunMark]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(mark == .good ? Theme.good : Theme.bad)
                    .frame(width: 5, height: mark == .good ? 28 : 20)
            }
        }
        .frame(height: 28, alignment: .bottom)
        .accessibilityElement()
        .accessibilityLabel("Last \(marks.count) sync runs, \(marks.filter { $0 == .failed }.count) failed")
    }
}

/// The wide row at the top: what the sync is doing, how the last runs went, and the controls.
struct SyncStatusCard: View {
    let health: SyncHealth
    let marks: [RunMark]
    let busy: String?
    /// Nil when automatic sync is off, so there is nothing to pause.
    let paused: Bool?
    let previewDisabled: Bool
    let pauseDisabled: Bool
    let preview: () -> Void
    let togglePause: () -> Void
    let enable: () -> Void

    var body: some View {
        CardSection {
            CardRow {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        icon
                        message
                        Spacer(minLength: 12)
                        if !marks.isEmpty {
                            RunBars(marks: marks)
                            Divider().frame(height: 36)
                        }
                        buttons
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) { icon; message }
                        HStack(spacing: 16) {
                            RunBars(marks: marks)
                            Spacer(minLength: 12)
                            buttons
                        }
                    }
                }
            }
            if let busy { CardRow { BusyLine(text: busy) } }
        }
        .overlay(alignment: .leading) { health.color.frame(width: 4) }
        .clipShape(armCardShape)
    }

    private var icon: some View {
        Image(systemName: health.symbol)
            .font(Theme.Fonts.icon)
            .foregroundStyle(health.color)
            .frame(width: 44, height: 44)
            .background(Circle().fill(health.color.opacity(0.14)))
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(health.headline).font(Theme.Fonts.sectionTitle)
            Text(health.detail).font(Theme.Fonts.body).foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if health.offersEnable {
                Button("Enable automatic sync", action: enable)
                    .buttonStyle(.accentFilled)
                    .disabled(pauseDisabled)
            }
            Button("Preview sync", action: preview)
                .buttonStyle(.accentFilled)
                .disabled(previewDisabled)
            if let paused {
                Button(paused ? "Resume" : "Pause", action: togglePause)
                    .buttonStyle(.neutral)
                    .disabled(pauseDisabled)
            }
        }
        .fixedSize()
    }
}

/// Puts the two columns side by side when the window is wide, and the second under the first
/// when it is not.
struct OverviewColumns: Layout {
    var sidebarCollapsed: Bool
    var gap: CGFloat = 24
    var rowGap: CGFloat = 16

    private func plan(_ width: CGFloat) -> (wide: Bool, main: CGFloat, side: CGFloat) {
        let wide = OverviewLayout.isWide(contentWidth: width, sidebarCollapsed: sidebarCollapsed)
        guard wide else { return (false, width, width) }
        let side = OverviewLayout.sideWidth(contentWidth: width)
        return (true, width - side - gap, side)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 900
        let layout = plan(width)
        let first = subviews[0].sizeThatFits(.init(width: layout.main, height: nil))
        let second = subviews[1].sizeThatFits(.init(width: layout.side, height: nil))
        let height = layout.wide ? max(first.height, second.height) : first.height + rowGap + second.height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let layout = plan(bounds.width)
        let first = subviews[0].sizeThatFits(.init(width: layout.main, height: nil))
        if layout.wide {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: layout.main, height: nil))
            subviews[1].place(
                at: CGPoint(x: bounds.minX + layout.main + gap, y: bounds.minY), anchor: .topLeading,
                proposal: .init(width: layout.side, height: nil))
        } else {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: .init(width: layout.main, height: nil))
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + first.height + rowGap), anchor: .topLeading,
                proposal: .init(width: layout.side, height: nil))
        }
    }
}

/// A compact pill for buttons inside rows.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Fonts.secondarySemibold)
            .padding(.horizontal, 12)
            .frame(minHeight: Theme.Control.smallChipHeight)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08)))
            .contentShape(Capsule())
    }
}

/// A count with its label, as one of the three tiles in Needs you.
struct NeedsYouTile: View {
    let title: String
    let count: Int
    let highlight: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(count)").font(Theme.Fonts.pageTitle).monospacedDigit()
                    .foregroundStyle(count == 0 ? Color.secondary.opacity(0.7) : highlight ? Theme.accent : Color.primary)
                Text(title).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                .strokeBorder(Theme.paneLine, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) \(title)")
    }
}

/// A small rounded tag.
struct OverviewTag: View {
    let text: String
    let tint: Color
    let textColor: Color

    var body: some View {
        Text(text).font(Theme.Fonts.tinySemibold).foregroundStyle(textColor)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(0.16)))
            .fixedSize()
    }
}

/// One event in Next up today.
struct NextUpRow: View {
    let event: ScheduleEvent
    let calendarName: String
    let color: Color
    let tags: [UpNextTag]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(event.startsAt.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Fonts.body).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 4, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title).font(Theme.Fonts.bodySemibold).lineLimit(1)
                    Text("\(calendarName) · \(EventDuration.text(event.endsAt.timeIntervalSince(event.startsAt)))")
                        .font(Theme.Fonts.secondary).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                ForEach(tags, id: \.text) { tag in
                    switch tag {
                    case .soon: OverviewTag(text: tag.text, tint: Theme.accent, textColor: Theme.accent)
                    case .overlaps: OverviewTag(text: tag.text, tint: Theme.caution, textColor: Theme.cautionText)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One row in Needs attention: an icon, what is wrong, and an optional Details button.
struct AttentionRow: View {
    let title: String
    let detail: String
    let failed: Bool
    /// The plain reason, shown under the row once Details is open. Nil hides the button.
    let reason: String?
    @Binding var showingReason: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                let tint = failed ? Theme.bad : Theme.caution
                Image(systemName: failed ? "xmark" : "clock.fill")
                    .font(Theme.Fonts.smallIcon)
                    .foregroundStyle(failed ? Theme.badText : Theme.cautionText)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.Fonts.bodySemibold).lineLimit(1).minimumScaleFactor(0.85)
                    Text(detail).font(Theme.Fonts.secondary).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 8)
                if reason != nil {
                    Button(showingReason ? "Hide" : "Details") { showingReason.toggle() }
                        .buttonStyle(RowButtonStyle())
                }
            }
            if showingReason, let reason {
                Text(reason).font(Theme.Fonts.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
            }
        }
    }
}
